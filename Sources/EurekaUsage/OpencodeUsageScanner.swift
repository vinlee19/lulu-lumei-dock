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
        try backfillProviders(db: db, inode: inode)
        try scanPartsForTools(db: db, inode: inode)
        try recordPromptCounts(db: db)
        inserted += try scanSessionMessages(db: db, inode: inode, nowMs: nowMs)
        try recordV2PromptCounts(db: db)
        return inserted
    }

    // MARK: - opencode 2.x：session_message 表

    /// assistant 行 → 用量 + 工具计数。独立 rowid 水位（键 "<db>#v2"），同 message 表的规则：
    /// 只结算已完成的行，进行中的 turn 停在水位前、下次再扫。表不存在（1.x 库）→ 查询失败 → 0。
    ///
    /// 升级时 1.x 会话连同消息按原 id 复制进 session_message，这些行的用量已由 message 表那条路径
    /// 计过 → 按消息 id 逐行排除。不按会话排除：迁移会话之后续聊的新消息只在 2.x 表里，要照常计
    private func scanSessionMessages(db: SQLiteDB, inode: Int64, nowMs: Double) throws -> Int {
        let key = dbPath.path + "#v2"
        let saved = try store.scanState.fileState(path: key)
        let watermark: Int64 = (saved?.inode == inode ? saved?.offset : nil) ?? 0
        let notCopiedFromV1 = db.tableExists("message")
            ? "AND NOT EXISTS (SELECT 1 FROM message o WHERE o.id = m.id)" : ""
        let rows = (try? db.query("""
            SELECT m.rowid, m.session_id, m.time_updated, m.data, s.directory
            FROM session_message m LEFT JOIN session_v2 s ON s.id = m.session_id
            WHERE m.rowid > ? AND m.type = 'assistant' \(notCopiedFromV1)
            ORDER BY m.rowid ASC
            """, [.int(watermark)]) { row -> (Int64, String?, Double, Data?, String?) in
            (row.int(0), row.text(1), row.real(2),
             row.text(3).flatMap { $0.data(using: .utf8) }, row.text(4))
        }) ?? []
        guard !rows.isEmpty else { return 0 }

        var records: [UsageRecord] = []
        var toolBumps: [String: Int] = [:]   // "day\u{1}tool" → count
        var newWatermark = watermark
        loop: for (rowid, sessionId, timeUpdated, dataBytes, directory) in rows {
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else {
                newWatermark = rowid  // 解析失败（不应发生）：推进以免卡死
                continue
            }
            let time = data["time"] as? [String: Any]
            let completed = time?["completed"] != nil
            let stale = timeUpdated < nowMs - staleAfterMs
            if !completed && !stale { break loop }  // 进行中的 turn：停在此，下次再扫
            let model = data["model"] as? [String: Any]
            var flattened = data
            flattened["modelID"] = model?["id"]
            flattened["providerID"] = model?["providerID"]
            if let record = usageRecord(data: flattened, sessionId: sessionId, directory: directory) {
                records.append(record)
            }
            let createdMs = (time?["created"] as? NSNumber)?.doubleValue ?? 0
            let day = Self.dayFormatter.string(
                from: createdMs > 0 ? Date(timeIntervalSince1970: createdMs / 1000) : Date())
            for item in data["content"] as? [[String: Any]] ?? []
            where item["type"] as? String == "tool" {
                guard let name = item["name"] as? String, !name.isEmpty else { continue }
                toolBumps["\(day)\u{1}\(name)", default: 0] += 1
            }
            newWatermark = rowid
        }

        try store.scanState.transaction {
            try store.usage.insert(records)
            for (composite, count) in toolBumps {
                let parts = composite.components(separatedBy: "\u{1}")
                guard parts.count == 2 else { continue }
                try store.toolCalls.bump(
                    day: parts[0], source: .opencode, kind: "tool", name: parts[1], by: count)
            }
            try store.scanState.setFileState(
                path: key, .init(inode: inode, offset: newWatermark, extra: nil))
        }
        return records.count
    }

    /// 2.x 每会话用户提问数。迁移会话的 session_message 是 message 表的超集（含迁移后续聊的提问），
    /// 本函数在 1.x 那次之后跑、同样 reset 覆盖写 → 以 2.x 的数为准
    private func recordV2PromptCounts(db: SQLiteDB) throws {
        let rows = (try? db.query("""
            SELECT session_id, COUNT(*) FROM session_message
            WHERE type = 'user'
            GROUP BY session_id
            """) { row -> (String, Int) in (row.text(0) ?? "", Int(row.int(1))) }) ?? []
        guard !rows.isEmpty else { return }
        try store.scanState.transaction {
            for (sessionId, count) in rows where !sessionId.isEmpty {
                try store.sessionStats.recordPrompts(
                    path: "\(dbPath.path)#\(sessionId)", sessionId: sessionId,
                    count: count, reset: true)
            }
        }
    }

    /// 每会话的用户提问数。共享库来源没有「每会话一个文件」，故 scan_files 那套字节水位用不上：
    /// 直接一条聚合查询取**绝对值**，用 `<db>#<sessionId>` 作 path、`reset: true` 覆盖写。
    /// 这样不依赖 rowid 水位，重扫幂等，也不会因为水位停在进行中的 turn 而少算。
    private func recordPromptCounts(db: SQLiteDB) throws {
        let rows = (try? db.query("""
            SELECT session_id, COUNT(*) FROM message
            WHERE json_extract(data, '$.role') = 'user'
            GROUP BY session_id
            """) { row -> (String, Int) in (row.text(0) ?? "", Int(row.int(1))) }) ?? []
        guard !rows.isEmpty else { return }
        try store.scanState.transaction {
            for (sessionId, count) in rows where !sessionId.isEmpty {
                try store.sessionStats.recordPrompts(
                    path: "\(dbPath.path)#\(sessionId)", sessionId: sessionId,
                    count: count, reset: true)
            }
        }
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
        // providerID 区分同名模型的计费方式（volcengine-agent-plan 订阅 vs zhipuai 按量…）
        let provider = data["modelID"] != nil ? data["providerID"] as? String : nil
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
            cacheReadTokens: cacheRead,
            provider: provider)
    }

    /// 一次性回填 provider：provider 列上线前入库的行都是 NULL，而水位已越过它们、不会重扫。
    /// 按 (会话, 模型, 时间戳) 精确匹配回写（ts 与入库时同一算法，双精度相等），只动 NULL 行。
    private func backfillProviders(db: SQLiteDB, inode: Int64) throws {
        let key = dbPath.path + "#provider-v1"
        guard try store.scanState.fileState(path: key)?.inode != inode else { return }
        let rows = (try? db.query("""
            SELECT session_id,
                   json_extract(data, '$.modelID'), json_extract(data, '$.providerID'),
                   json_extract(data, '$.time.created')
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND json_extract(data, '$.providerID') IS NOT NULL
              AND json_extract(data, '$.modelID') IS NOT NULL
            """) { row -> (String, String, String, Double) in
            (row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "", row.real(3))
        }) ?? []
        try store.scanState.transaction {
            for (sessionId, model, provider, createdMs) in rows
            where !sessionId.isEmpty && !provider.isEmpty && createdMs > 0 {
                try store.usage.backfillProvider(
                    source: .opencode, sessionId: sessionId, model: model,
                    ts: createdMs / 1000, provider: provider)
            }
            try store.scanState.setFileState(path: key, .init(inode: inode, offset: 1))
        }
    }

    private func fileInode(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.systemFileNumber] as? Int).map(Int64.init) ?? 0
    }
}
