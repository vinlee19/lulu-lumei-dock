import Foundation
import EurekaKit
import EurekaStore

/// Scans cumulative token usage from the message table (assistant rows) of opencode.db. Opens the
/// external DB read-only; advances by a message.rowid watermark and settles only "completed"
/// messages, so an in-progress turn stays before the watermark until the next scan (each message
/// counts once, no cross-file dedup needed).
public final class OpencodeUsageScanner {
    private let dbPath: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    /// Messages still incomplete after this long are treated as terminal (keeps an abnormally
    /// interrupted turn from pinning the watermark)
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

        // Watermark = the last processed message.rowid; a rebuilt db (inode changed) resets to zero
        // and rescans
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
                newWatermark = rowid  // Parse failure (should not happen): advance so we do not get stuck
                continue
            }
            if (data["role"] as? String) == "assistant" {
                let time = data["time"] as? [String: Any]
                let completed = time?["completed"] != nil
                let stale = timeUpdated < nowMs - staleAfterMs
                if !completed && !stale { break loop }  // In-progress turn: stop here and rescan next time
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
        return inserted
    }

    /// User prompt count per session. A shared-DB source has no "one file per session", so the
    /// scan_files byte watermark does not apply: a single aggregate query fetches the **absolute
    /// value**, written with `<db>#<sessionId>` as path and `reset: true` to overwrite. This does
    /// not depend on the rowid watermark, rescans are idempotent, and nothing is undercounted when
    /// the watermark stops at an in-progress turn.
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

    /// Tool-type parts in the part table → tool-call counts (separate rowid watermark, key
    /// "<db>#parts")
    private func scanPartsForTools(db: SQLiteDB, inode: Int64) throws {
        let key = dbPath.path + "#parts"
        let saved = try store.scanState.fileState(path: key)
        let watermark: Int64 = (saved?.inode == inode ? saved?.offset : nil) ?? 0
        // The part table may not exist in older opencode DBs → a failed query means no tool data
        // (usage scanning is unaffected)
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
        // providerID distinguishes billing for same-named models (volcengine-agent-plan
        // subscription vs zhipuai pay-as-you-go…)
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
            outputTokens: output + reasoning,  // reasoning counts on the output side
            cacheCreationTokens: cacheWrite,
            cacheReadTokens: cacheRead,
            provider: provider)
    }

    /// One-time provider backfill: rows stored before the provider column existed are NULL, and the
    /// watermark is past them so they are never rescanned. Writes back on an exact (session, model,
    /// timestamp) match (ts uses the same algorithm as at insert time, so doubles compare equal),
    /// touching only NULL rows.
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
