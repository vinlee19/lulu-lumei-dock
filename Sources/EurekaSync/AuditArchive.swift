import EurekaKit
import EurekaStore
import Foundation

/// Materializes audit records into Parquet per UTC day (after redaction) for the backup engine
/// to upload to
/// `<prefix>/<host>/eureka/audit/dt=YYYY-MM-DD/audit-events-YYYY-MM-DD.parquet` (Hive
/// partitions, queryable directly from Athena / DuckDB).
///
/// Same pattern as EurekaDBSnapshot: write a local temp file then move it atomically; the backup
/// engine uploads incrementally by size+mtime.
/// Key constraints:
/// - One fingerprint per day (row count : max id : backfilled exit_code count : failure count);
///   a day is rewritten only when it changes;
/// - **Days already uploaded and older than the retention period are never rewritten**: local
///   pruning deletes those rows, so a rewrite would only overwrite the remote with fewer rows;
/// - Local pruning deletes only days that are "uploaded with an unchanged fingerprint"
///   (`prunableDays`); if uploads fail, keep rows past retention rather than lose them.
public enum AuditArchive {
    /// Row cap per file; overflow goes to `audit-events-<day>-2.parquet`, `-3`, …
    public static let rowsPerFile = 200_000

    /// Self-describing file name: a file downloaded on its own still says what it holds and which day.
    /// The first chunk has no suffix; later chunks (only past `rowsPerFile` rows in one day) get `-2`, `-3`, …
    public static func fileName(day: String, chunk: Int) -> String {
        chunk == 0 ? "audit-events-\(day).parquet" : "audit-events-\(day)-\(chunk + 1).parquet"
    }

    static let filePrefix = "audit-events-"

    /// Renames the `part-NNNN.parquet` files that 0.35.0 wrote to the self-describing names.
    /// Idempotent. If the new name already exists the legacy file is a stale duplicate and is dropped,
    /// so a half-finished run can never overwrite a newer file. Returns the number of files renamed.
    @discardableResult
    public static func migrateLegacyFileNames(in outDir: URL) -> Int {
        let fm = FileManager.default
        var renamed = 0
        for dirName in (try? fm.contentsOfDirectory(atPath: outDir.path)) ?? [] where dirName.hasPrefix("dt=") {
            let day = String(dirName.dropFirst(3))
            let dir = outDir.appendingPathComponent(dirName, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
                guard name.hasPrefix("part-"), name.hasSuffix(".parquet"),
                      let chunk = Int(name.dropFirst(5).dropLast(8)) else { continue }
                let legacy = dir.appendingPathComponent(name)
                let target = dir.appendingPathComponent(fileName(day: day, chunk: chunk))
                if fm.fileExists(atPath: target.path) {
                    try? fm.removeItem(at: legacy)
                } else if (try? fm.moveItem(at: legacy, to: target)) != nil {
                    renamed += 1
                }
            }
        }
        return renamed
    }

    public struct Outcome: Equatable {
        public var writtenDays: [String] = []
        public var errors: [String] = []
    }

    /// Materializes every day that needs (re)writing. cutoff = retention cutoff (nil = keep
    /// forever).
    @discardableResult
    public static func materialize(
        store: EurekaStore, outDir: URL, host: String, appVersion: String,
        cutoff: Date?, now: Date = Date()
    ) -> Outcome {
        var outcome = Outcome()
        migrateLegacyFileNames(in: outDir)
        guard let fingerprints = try? store.audit.dayFingerprints(),
              let ledgerRows = try? store.auditArchive.all()
        else {
            outcome.errors.append(L10n.text("Failed to read the audit database", zhHans: "读取审计库失败"))
            return outcome
        }
        let ledger = Dictionary(uniqueKeysWithValues: ledgerRows.map { ($0.day, $0) })
        let cutoffDay = cutoff.map(utcDay)
        let fm = FileManager.default

        for day in fingerprints where !day.day.isEmpty {
            let entry = ledger[day.day]
            let dir = outDir.appendingPathComponent("dt=\(day.day)", isDirectory: true)
            // Older than retention and already uploaded: final, never touched again
            if let cutoffDay, day.day < cutoffDay, entry?.uploadedAt != nil { continue }
            let fileMissing = !fm.fileExists(atPath: dir.appendingPathComponent(fileName(day: day.day, chunk: 0)).path)
            let needsWrite = entry?.fingerprint != day.fingerprint
                || (fileMissing && entry?.uploadedFingerprint != day.fingerprint)
            guard needsWrite else { continue }
            do {
                let events = try store.audit.events(onDay: day.day)
                try writeDay(events, day: day.day, to: dir, host: host, appVersion: appVersion)
                try store.auditArchive.recordWritten(
                    day: day.day, fingerprint: day.fingerprint, rows: events.count,
                    filePath: dir.path, at: now)
                outcome.writtenDays.append(day.day)
            } catch {
                outcome.errors.append(L10n.format("%@: %@", zhHans: "%@：%@", String(day.day), String(describing: error)))
            }
        }
        return outcome
    }

    /// After a backup round: mark as uploaded the days whose local files exactly match sync_state
    /// (size + mtime)
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

    /// Days local pruning may delete: uploaded, and the fingerprint at upload time equals the
    /// current one in the database (no newer change left un-uploaded)
    public static func prunableDays(store: EurekaStore) -> Set<String> {
        guard let current = try? store.audit.dayFingerprints(),
              let ledger = try? store.auditArchive.all()
        else { return [] }
        let uploaded = Dictionary(uniqueKeysWithValues: ledger.compactMap { entry in
            entry.uploadedFingerprint.map { (entry.day, $0) }
        })
        return Set(current.filter { uploaded[$0.day] == $0.fingerprint }.map(\.day))
    }

    /// Local pruning while archiving is on: deletes only **whole days** that are "uploaded with an
    /// unchanged fingerprint".
    /// - Retention: prunable days before the cutoff day are deleted whole (the cutoff day itself
    ///   stays until all of it has expired);
    /// - Row cap: if still over, delete whole days starting from the oldest prunable day.
    /// Returns the deleted days. Uploads keep failing → no prunable days → keep rows past retention
    /// rather than lose data.
    @discardableResult
    public static func prune(store: EurekaStore, cutoff: Date?, maxRows: Int) -> [String] {
        let prunable = prunableDays(store: store)
        guard !prunable.isEmpty, let days = try? store.audit.dayFingerprints() else { return [] }
        var deleted: [String] = []
        var total = days.reduce(0) { $0 + $1.rows }
        let cutoffDay = cutoff.map(utcDay)
        for day in days where prunable.contains(day.day) {  // days is sorted by date ascending
            let expired = cutoffDay.map { day.day < $0 } ?? false
            guard expired || total > maxRows else { continue }
            guard (try? store.audit.deleteDay(day.day)) != nil else { continue }
            total -= day.rows
            deleted.append(day.day)
        }
        return deleted
    }

    /// Local Parquet directories older than retention and already uploaded may be deleted (the
    /// remote copy stays; the engine only purges the sync_state rows)
    public static func removeUploadedLocalFiles(store: EurekaStore, cutoff: Date) {
        guard let entries = try? store.auditArchive.all() else { return }
        let cutoffDay = utcDay(cutoff)
        for entry in entries where entry.day < cutoffDay && entry.uploadedAt != nil {
            try? FileManager.default.removeItem(atPath: entry.filePath)
        }
    }

    // MARK: - Writing files

    static func writeDay(_ events: [AuditEvent], day: String, to dir: URL, host: String, appVersion: String) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let chunks = stride(from: 0, to: max(events.count, 1), by: rowsPerFile).map {
            Array(events[$0..<min($0 + rowsPerFile, events.count)])
        }
        var keep: Set<String> = []
        for (index, chunk) in chunks.enumerated() {
            let name = fileName(day: day, chunk: index)
            keep.insert(name)
            let data = try encode(chunk, host: host, appVersion: appVersion)
            let target = dir.appendingPathComponent(name)
            let temp = dir.appendingPathComponent(".\(name).tmp")
            try data.write(to: temp)
            _ = try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
        }
        // Extra chunk files left over after the row count shrank
        for stale in partFiles(in: dir) where !keep.contains(stale.lastPathComponent) {
            try? fm.removeItem(at: stale)
        }
    }

    /// A batch of records → Parquet (detail is redacted first)
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

    /// Rebuilds the path under dir from the file name; the URLs returned by
    /// contentsOfDirectory(at:) can't be used:
    /// they resolve /var to /private/var, which won't match the paths recorded in sync_state
    static func partFiles(in dir: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".parquet") }
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
