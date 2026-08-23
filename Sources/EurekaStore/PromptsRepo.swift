import EurekaKit
import Foundation

/// Prompt 库持久化：提取 upsert（保留用户标注）+ 增量指纹 + 列表/标注读写。
/// favorite/tags/use_count 是用户写入的事实——重提取只刷新正文列，绝不覆盖标注列。
public final class PromptsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// 提取入库：新行整条插入；已存在的行只刷新正文列（text/timestamp/cwd/updated_at），
    /// favorite/tags/use_count/last_used_at/first_seen 保持原值。
    public func upsertExtracted(_ entries: [PromptEntry], at now: Date = Date()) throws {
        guard !entries.isEmpty else { return }
        try db.transaction {
            for entry in entries {
                try db.run("""
                INSERT INTO prompts
                    (id, source, session_id, message_idx, text, timestamp, cwd,
                     favorite, tags, use_count, last_used_at, first_seen, updated_at)
                VALUES (?,?,?,?,?,?,?,0,'[]',0,NULL,?,?)
                ON CONFLICT(id) DO UPDATE SET
                    text = excluded.text,
                    timestamp = excluded.timestamp,
                    cwd = excluded.cwd,
                    updated_at = excluded.updated_at
                """, [
                    .text(entry.id), .text(entry.source.rawValue),
                    .text(entry.sessionId), .int(Int64(entry.messageIdx)),
                    .text(entry.text), .date(entry.timestamp), .string(entry.cwd),
                    .date(entry.firstSeen), .real(now.timeIntervalSince1970),
                ])
            }
        }
    }

    /// 记录会话提取指纹（lastActiveAt 未变即可跳过）
    public func markExtracted(sessionId: String, source: AgentSource, at date: Date) throws {
        try db.run("""
        INSERT INTO prompt_sessions (session_id, source, extracted_at) VALUES (?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET extracted_at = excluded.extracted_at
        """, [.text(sessionId), .text(source.rawValue), .date(date)])
    }

    /// 已提取会话的指纹：session_id → 上次提取时间
    public func extractionFingerprints() throws -> [String: Date] {
        let rows = try db.query(
            "SELECT session_id, extracted_at FROM prompt_sessions"
        ) { row -> (String, Date) in
            (row.text(0) ?? "", Date(timeIntervalSince1970: row.real(1)))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// 全量列表（first_seen 倒序 = 最新提取在前）
    public func all() throws -> [PromptEntry] {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts ORDER BY first_seen DESC, id
        """) { Self.mapRow($0) }
    }

    /// 收藏计数（统计卡用）
    public func favoriteCount() throws -> Int {
        try db.query(
            "SELECT COUNT(*) FROM prompts WHERE favorite = 1"
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// 按 id 取单条（详情直达）
    public func entry(id: String) throws -> PromptEntry? {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts WHERE id = ?
        """, [.text(id)]) { Self.mapRow($0) }.first
    }

    // MARK: - 用户标注写回（事实数据，独立于提取刷新）

    public func setFavorite(_ id: String, favorite: Bool) throws {
        try db.run(
            "UPDATE prompts SET favorite = ? WHERE id = ?",
            [.int(favorite ? 1 : 0), .text(id)])
    }

    public func setTags(_ id: String, tags: [String]) throws {
        try db.run(
            "UPDATE prompts SET tags = ? WHERE id = ?",
            [.text(Self.encodeTags(tags)), .text(id)])
    }

    /// 复用计数：+1 并记录时间
    public func recordUse(_ id: String, at date: Date = Date()) throws {
        try db.run("""
        UPDATE prompts SET use_count = use_count + 1, last_used_at = ?
        WHERE id = ?
        """, [.date(date), .text(id)])
    }

    /// 单条移除（用户主动删；会话消失不自动删——收藏可能指向已结束的会话）
    public func delete(id: String) throws {
        try db.run("DELETE FROM prompts WHERE id = ?", [.text(id)])
    }

    // MARK: - 周报统计

    /// 周报用的提问统计（窗口口径见 weeklyStats）
    public struct WeeklyPromptStats: Equatable {
        /// 窗口内新提出的提问数
        public var askedCount: Int
        public var bySource: [AgentSource: Int]
        /// 窗口内复用过的提问（last_used_at 落窗，按累计 use_count 降序）
        public var topReused: [PromptEntry]
    }

    /// 周报统计：提问时间取 COALESCE(timestamp, first_seen)（个别源无消息时间戳，
    /// 退化为提取时间）；复用按 last_used_at 落窗判定（use_count 是全期累计值）。
    public func weeklyStats(from: Date, to: Date, topLimit: Int = 5) throws -> WeeklyPromptStats {
        let askedRows = try db.query("""
        SELECT source, COUNT(*) FROM prompts
        WHERE COALESCE(timestamp, first_seen) >= ? AND COALESCE(timestamp, first_seen) < ?
        GROUP BY source
        """, [.date(from), .date(to)]) { row in
            (AgentSource(rawValue: row.text(0) ?? "") ?? .claude, Int(row.int(1)))
        }
        var bySource: [AgentSource: Int] = [:]
        var asked = 0
        for (source, count) in askedRows {
            bySource[source] = count
            asked += count
        }
        let reused = try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts
        WHERE last_used_at >= ? AND last_used_at < ? AND use_count > 0
        ORDER BY use_count DESC LIMIT ?
        """, [.date(from), .date(to), .int(Int64(topLimit))]) { Self.mapRow($0) }
        return WeeklyPromptStats(askedCount: asked, bySource: bySource, topReused: reused)
    }

    // MARK: - 行映射

    private static func mapRow(_ row: SQLiteRow) -> PromptEntry {
        PromptEntry(
            id: row.text(0) ?? "",
            source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
            sessionId: row.text(2) ?? "",
            messageIdx: Int(row.int(3)),
            text: row.text(4) ?? "",
            timestamp: row.date(5),
            cwd: row.text(6),
            favorite: row.int(7) != 0,
            tags: decodeTags(row.text(8)),
            useCount: Int(row.int(9)),
            lastUsedAt: row.isNull(10) ? nil : Date(timeIntervalSince1970: row.real(10)),
            firstSeen: Date(timeIntervalSince1970: row.real(11)))
    }

    public static func encodeTags(_ tags: [String]) -> String {
        guard !tags.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: tags)
        else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeTags(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String]
        else { return [] }
        return array
    }
}
