import Foundation
import EurekaKit
import EurekaStore

/// 扫描 opencode.db 的 message 表（assistant 行）累计 token 用量。
/// 只读打开外部库；按 message.rowid 水位增量，只结算「已完成」的消息，
/// 进行中的 turn 停在水位前、下次再扫（故每条消息只计一次，无需跨文件去重）。
public final class OpencodeUsageScanner {
    private let dbPath: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    /// 超过此时长仍未完成的消息视为终态（防止异常中断的 turn 卡死水位）
    private let staleAfterMs: Double = 5 * 60 * 1000

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    public init(dbPath: URL, store: EurekaStore) {
        self.dbPath = dbPath
        self.store = store
    }

    @discardableResult
    public func scanOnce(now: Date = Date()) throws -> Int {
        let path = dbPath.path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLiteDB(path: path, readOnly: true) else { return 0 }

        // 水位 = 上次处理到的 message.rowid；db 重建（inode 变）则归零重扫
        let inode = fileInode(path)
        let saved = try store.scanState.fileState(path: path)
        let watermark: Int64 = (saved?.inode == inode ? saved?.offset : nil) ?? 0

        let rows = try db.query("""
            SELECT m.rowid, m.session_id, m.time_updated, m.data, s.directory
            FROM message m LEFT JOIN session s ON s.id = m.session_id
            WHERE m.rowid > ?
            ORDER BY m.rowid ASC
            """, [.int(watermark)]) { row -> (Int64, String?, Double, Data?, String?) in
            (row.int(0), row.text(1), row.real(2),
             row.text(3).flatMap { $0.data(using: .utf8) }, row.text(4))
        }

        let nowMs = now.timeIntervalSince1970 * 1000
        var records: [UsageRecord] = []
        var newWatermark = watermark
        loop: for (rowid, sessionId, timeUpdated, dataBytes, directory) in rows {
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else {
                newWatermark = rowid  // 解析失败（不应发生）：推进以免卡死
                continue
            }
            if (data["role"] as? String) == "assistant" {
                let time = data["time"] as? [String: Any]
                let completed = time?["completed"] != nil
                let stale = timeUpdated < nowMs - staleAfterMs
                if !completed && !stale { break loop }  // 进行中的 turn：停在此，下次再扫
                if let record = usageRecord(data: data, sessionId: sessionId, directory: directory) {
                    records.append(record)
                }
            }
            newWatermark = rowid
        }

        var inserted = 0
        try store.scanState.transaction {
            try store.usage.insert(records)
            try store.scanState.setFileState(
                path: path, .init(inode: inode, offset: newWatermark, extra: nil))
            inserted = records.count
        }
        try scanPartsForTools(db: db, inode: inode)
        return inserted
    }

    /// part 表 tool 类型分片 → 工具调用计数（独立 rowid 水位，键 "<db>#parts"）
    private func scanPartsForTools(db: SQLiteDB, inode: Int64) throws {
        let key = dbPath.path + "#parts"
        let saved = try store.scanState.fileState(path: key)
        let watermark: Int64 = (saved?.inode == inode ? saved?.offset : nil) ?? 0
        // part 表在旧版 opencode 库可能不存在 → 查询失败视为无工具数据（不影响用量扫描）
        let rows = (try? db.query("""
            SELECT rowid, time_created, data FROM part WHERE rowid > ? ORDER BY rowid ASC
            """, [.int(watermark)]) { row -> (Int64, Double, String?) in
            (row.int(0), row.real(1), row.text(2))
        }) ?? []
        guard !rows.isEmpty else { return }
        var newWatermark = watermark
        var bumps: [String: Int] = [:]   // "day\u{1}tool" → count
        for (rowid, timeCreated, dataJSON) in rows {
            newWatermark = max(newWatermark, rowid)
            guard let dataJSON,
                  let obj = try? JSONSerialization.jsonObject(with: Data(dataJSON.utf8)),
                  let data = obj as? [String: Any],
                  data["type"] as? String == "tool",
                  let tool = data["tool"] as? String, !tool.isEmpty
            else { continue }
            let day = Self.dayFormatter.string(
                from: timeCreated > 0 ? Date(timeIntervalSince1970: timeCreated / 1000) : Date())
            bumps["\(day)\u{1}\(tool)", default: 0] += 1
        }
        try store.scanState.transaction {
            for (composite, count) in bumps {
                let parts = composite.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                try store.toolCalls.bump(
                    day: parts[0], source: .opencode, kind: "tool", name: parts[1], by: count)
            }
            try store.scanState.setFileState(path: key, .init(inode: inode, offset: newWatermark))
        }
    }

    private func usageRecord(
        data: [String: Any], sessionId: String?, directory: String?
    ) -> UsageRecord? {
        guard let tokens = data["tokens"] as? [String: Any] else { return nil }
        let input = tokens["input"] as? Int ?? 0
        let output = tokens["output"] as? Int ?? 0
        let reasoning = tokens["reasoning"] as? Int ?? 0
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let cacheRead = cache["read"] as? Int ?? 0
        let cacheWrite = cache["write"] as? Int ?? 0
        guard input > 0 || output > 0 || reasoning > 0 || cacheRead > 0 || cacheWrite > 0 else {
            return nil
        }
        let model = (data["modelID"] as? String) ?? (data["providerID"] as? String) ?? "opencode"
        let createdMs = ((data["time"] as? [String: Any])?["created"] as? NSNumber)?.doubleValue ?? 0
        let timestamp = createdMs > 0 ? Date(timeIntervalSince1970: createdMs / 1000) : Date()
        return UsageRecord(
            source: .opencode,
            model: model,
            project: projectResolver.projectName(forCwd: directory),
            sessionId: sessionId,
            timestamp: timestamp,
            inputTokens: input,
            outputTokens: output + reasoning,  // reasoning 计入 output 侧
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead)
    }

    private func fileInode(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.systemFileNumber] as? Int).map(Int64.init) ?? 0
    }
}
