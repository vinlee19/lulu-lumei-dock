import EurekaKit
import EurekaStore
import Foundation

/// 审计记录按 UTC 日物化为 Parquet（脱敏后），交给备份引擎上传到
/// `<prefix>/<host>/eureka/audit/dt=YYYY-MM-DD/part-0000.parquet`（Hive 分区，Athena / DuckDB 直接查）。
///
/// 与 EurekaDBSnapshot 同一模式：本地先写临时文件再原子移动，备份引擎按 size+mtime 增量上传。
/// 关键约束：
/// - 每天一个指纹（行数 : 最大 id : 回填 exit_code 数 : 失败数），变了才重写该天；
/// - **已上传、且早于保留期的日期不再重写**——本地清理会删掉那些行，重写只会用更少的行覆盖远端；
/// - 本地清理只删"已上传且指纹未变"的日期（`prunableDays`），上传失败宁可超期保留。
public enum AuditArchive {
    /// 单文件行数上限（超出拆 part-0001…）
    public static let rowsPerFile = 200_000

    public struct Outcome: Equatable {
        public var writtenDays: [String] = []
        public var errors: [String] = []
    }

    /// 物化所有需要（重）写的日期。cutoff = 保留期截止时间（nil = 永久保留）。
    @discardableResult
    public static func materialize(
        store: EurekaStore, outDir: URL, host: String, appVersion: String,
        cutoff: Date?, now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()
        guard let fingerprints = try? store.audit.dayFingerprints(),
              let ledgerRows = try? store.auditArchive.all()
        else {
            outcome.errors.append("读取审计库失败")
            return outcome
        }
        let ledger = Dictionary(uniqueKeysWithValues: ledgerRows.map { ($0.day, $0) })
        let cutoffDay = cutoff.map(utcDay)
        let fm = FileManager.default

        for day in fingerprints where !day.day.isEmpty {
            let entry = ledger[day.day]
            let dir = outDir.appendingPathComponent("dt=\(day.day)", isDirectory: true)
            // 早于保留期且已上传：定稿，不再动
            if let cutoffDay, day.day < cutoffDay, entry?.uploadedAt != nil { continue }
            let fileMissing = !fm.fileExists(atPath: dir.appendingPathComponent("part-0000.parquet").path)
            let needsWrite = entry?.fingerprint != day.fingerprint
                || (fileMissing && entry?.uploadedFingerprint != day.fingerprint)
            guard needsWrite else { continue }
            do {
                let events = try store.audit.events(onDay: day.day)
                try writeDay(events, to: dir, host: host, appVersion: appVersion)
                try store.auditArchive.recordWritten(
                    day: day.day, fingerprint: day.fingerprint, rows: events.count,
                    filePath: dir.path, at: now)
                outcome.writtenDays.append(day.day)
            } catch {
                outcome.errors.append("\(day.day)：\(error)")
            }
        }
        return outcome
    }

    /// 备份一轮之后：本地文件与 sync_state 完全一致（size + mtime）的日期记为已上传
    public static func reconcileUploads(store: EurekaStore, now: Date = Date()) {
        guard let entries = try? store.auditArchive.all() else { return }
        for entry in entries where entry.uploadedFingerprint != entry.fingerprint {
            let parts = partFiles(in: URL(fileURLWithPath: entry.filePath))
            guard !parts.isEmpty else { continue }
            let allUploaded = parts.allSatisfy { url in
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                      let size = (attrs[.size] as? NSNumber)?.int64Value,
                      let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
                      let state = try? store.syncState.entry(path: url.path)
                else { return false }
                return state.size == size && abs(state.mtime - mtime) <= 0.001
            }
            if allUploaded {
                try? store.auditArchive.markUploaded(day: entry.day, fingerprint: entry.fingerprint, at: now)
            }
        }
    }

    /// 允许本地清理的日期：已上传，且上传时的指纹等于当前库里的指纹（没有新变化没传上去）
    public static func prunableDays(store: EurekaStore) -> Set<String> {
        guard let current = try? store.audit.dayFingerprints(),
              let ledger = try? store.auditArchive.all()
        else { return [] }
        let uploaded = Dictionary(uniqueKeysWithValues: ledger.compactMap { entry in
            entry.uploadedFingerprint.map { (entry.day, $0) }
        })
        return Set(current.filter { uploaded[$0.day] == $0.fingerprint }.map(\.day))
    }

    /// 开启归档时的本地清理：只删"已上传且指纹未变"的**整天**。
    /// - 保留期：截止日之前的可清理日期整天删除（截止当天留到它整天过期）；
    /// - 行数上限：仍超出时，从最旧的可清理日期起整天删除。
    /// 返回删掉的日期。上传一直失败 → 没有可清理日期 → 宁可超期保留，也不丢数据。
    @discardableResult
    public static func prune(store: EurekaStore, cutoff: Date?, maxRows: Int) -> [String] {
        let prunable = prunableDays(store: store)
        guard !prunable.isEmpty, let days = try? store.audit.dayFingerprints() else { return [] }
        var deleted: [String] = []
        var total = days.reduce(0) { $0 + $1.rows }
        let cutoffDay = cutoff.map(utcDay)
        for day in days where prunable.contains(day.day) {  // days 已按日期升序
            let expired = cutoffDay.map { day.day < $0 } ?? false
            guard expired || total > maxRows else { continue }
            guard (try? store.audit.deleteDay(day.day)) != nil else { continue }
            total -= day.rows
            deleted.append(day.day)
        }
        return deleted
    }

    /// 早于保留期、且已上传的本地 Parquet 目录可以删（远端保留；引擎只会清掉 sync_state 行）
    public static func removeUploadedLocalFiles(store: EurekaStore, cutoff: Date) {
        guard let entries = try? store.auditArchive.all() else { return }
        let cutoffDay = utcDay(cutoff)
        for entry in entries where entry.day < cutoffDay && entry.uploadedAt != nil {
            try? FileManager.default.removeItem(atPath: entry.filePath)
        }
    }

    // MARK: - 写文件

    static func writeDay(_ events: [AuditEvent], to dir: URL, host: String, appVersion: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunks = stride(from: 0, to: max(events.count, 1), by: rowsPerFile).map {
            Array(events[$0..<min($0 + rowsPerFile, events.count)])
        }
        var keep: Set<String> = []
        for (index, chunk) in chunks.enumerated() {
            let name = String(format: "part-%04d.parquet", index)
            keep.insert(name)
            let data = try encode(chunk, host: host, appVersion: appVersion)
            let target = dir.appendingPathComponent(name)
            let temp = dir.appendingPathComponent(".\(name).tmp")
            try data.write(to: temp)
            _ = try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
        }
        // 行数变少导致的多余分片
        for stale in partFiles(in: dir) where !keep.contains(stale.lastPathComponent) {
            try? fm.removeItem(at: stale)
        }
    }

    /// 一批记录 → Parquet（detail 先脱敏）
    public static func encode(_ events: [AuditEvent], host: String, appVersion: String) throws -> Data {
        let redacted = events.map { AuditRedactor.redact(detail: $0.detail, tool: $0.tool) }
        typealias Column = ParquetWriter.Column
        let columns: [Column] = [
            Column(name: "event_id", values: .string(events.map(\.opId)), required: true),
            Column(name: "source", values: .string(events.map(\.source.rawValue)), required: true),
            Column(name: "session_id", values: .string(events.map(\.sessionId)), required: true),
            Column(name: "ts", values: .timestampMicros(events.map {
                Int64(($0.timestamp.timeIntervalSince1970 * 1_000_000).rounded())
            }), required: true),
            Column(name: "kind", values: .string(events.map(\.kind.rawValue)), required: true),
            Column(name: "tool", values: .string(events.map(\.tool)), required: true),
            Column(name: "detail", values: .string(redacted.map(\.text)), required: true),
            Column(name: "detail_redacted", values: .bool(redacted.map(\.redacted)), required: true),
            Column(name: "cwd", values: .string(events.map(\.cwd)), required: false),
            Column(name: "exit_code", values: .int32(events.map { $0.exitCode.map(Int32.init) }), required: false),
            Column(name: "is_error", values: .bool(events.map(\.isError)), required: true),
            Column(name: "risk_level", values: .int32(events.map { Int32($0.riskLevel?.rawValue ?? 0) }), required: true),
            Column(name: "risk_rule", values: .string(events.map(\.riskRule)), required: false),
            Column(name: "host", values: .string(events.map { _ in host }), required: true),
            Column(name: "app_version", values: .string(events.map { _ in appVersion }), required: true),
        ]
        return try ParquetWriter.write(
            columns: columns, compression: .gzip, createdBy: "eureka \(appVersion)")
    }

    /// 按文件名拼回 dir 下的路径——不能用 contentsOfDirectory(at:) 返回的 URL：
    /// 它会把 /var 解析成 /private/var，与 sync_state 里记的路径对不上
    static func partFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("part-") && $0.hasSuffix(".parquet") }
            .sorted()
            .map { dir.appendingPathComponent($0) }
    }

    static func utcDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
