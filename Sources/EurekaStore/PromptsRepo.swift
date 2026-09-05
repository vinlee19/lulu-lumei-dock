import EurekaKit
import Foundation

/// Prompt 库持久化：提取 upsert（保留用户标注）+ 增量指纹 + 列表/标注读写。
/// favorite/tags/use_count/hidden_at 是用户写入的事实——重提取只刷新正文列，绝不覆盖标注列。
/// "移除"是软删除（hidden_at）：行留在表里挡住重提取的 upsert，所有读路径按 hidden_at IS NULL 过滤。
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

    /// 评价入库：prompt_eval 全列纯派生 → ON CONFLICT 整行覆盖（无用户列要保）
    public func upsertEval(_ rows: [PromptEval]) throws {
        guard !rows.isEmpty else { return }
        try db.transaction {
            for row in rows {
                try db.run("""
                INSERT INTO prompt_eval
                    (prompt_id, severity, rule_ids, step_count, error_steps, duration,
                     reformulated, corrective, outcome, structure_flags)
                VALUES (?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(prompt_id) DO UPDATE SET
                    severity = excluded.severity,
                    rule_ids = excluded.rule_ids,
                    step_count = excluded.step_count,
                    error_steps = excluded.error_steps,
                    duration = excluded.duration,
                    reformulated = excluded.reformulated,
                    corrective = excluded.corrective,
                    outcome = excluded.outcome,
                    structure_flags = excluded.structure_flags
                """, [
                    .text(row.promptId), .int(Int64(row.severity.rawValue)),
                    .text(row.ruleIds.joined(separator: ",")),
                    .int(Int64(row.stepCount)), .int(Int64(row.errorSteps)),
                    row.duration.map { SQLiteValue.real($0) } ?? .null,
                    .int(Int64(row.reformulated.rawValue)),
                    .int(row.corrective ? 1 : 0),
                    .text(row.outcome), .text(row.structureFlags.encoded),
                ])
            }
        }
    }

    /// 全量评价（prompt_id → 评价）；服务层随刷新读回缓存
    public func evalMap() throws -> [String: PromptEval] {
        let rows = try db.query("""
        SELECT prompt_id, severity, rule_ids, step_count, error_steps, duration,
               reformulated, corrective, outcome, structure_flags
        FROM prompt_eval
        """) { row -> PromptEval in
            PromptEval(
                promptId: row.text(0) ?? "",
                severity: TurnDiagnostics.Severity(rawValue: Int(row.int(1))) ?? .clean,
                ruleIds: (row.text(2) ?? "").split(separator: ",").map(String.init),
                stepCount: Int(row.int(3)),
                errorSteps: Int(row.int(4)),
                duration: row.isNull(5) ? nil : row.real(5),
                reformulated: PromptFollowupSignal.Reformulation(
                    rawValue: Int(row.int(6))) ?? .none,
                corrective: row.int(7) != 0,
                outcome: row.text(8) ?? "clean",
                structureFlags: PromptStructure.Flags.decode(row.text(9) ?? ""))
        }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.promptId, $0) })
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

    /// 全量列表（first_seen 倒序 = 最新提取在前；已移除的不返回）
    public func all() throws -> [PromptEntry] {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts WHERE hidden_at IS NULL ORDER BY first_seen DESC, id
        """) { Self.mapRow($0) }
    }

    /// 收藏计数（统计卡用；已移除的不计）
    public func favoriteCount() throws -> Int {
        try db.query(
            "SELECT COUNT(*) FROM prompts WHERE favorite = 1 AND hidden_at IS NULL"
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// 按 id 取单条（详情直达；已移除的视同不存在）
    public func entry(id: String) throws -> PromptEntry? {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts WHERE id = ? AND hidden_at IS NULL
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

    /// 单条移除 = 软删除（置 hidden_at）。硬删不行：会话还活跃时下一次增量提取会把
    /// 整批 prompt 重新 upsert，被删的那条会原样复活；留行则 ON CONFLICT 只刷正文列，
    /// hidden_at 与其它用户标注一样被保住。会话消失也不自动删——收藏可能指向已结束的会话。
    public func hide(_ id: String, at date: Date = Date()) throws {
        try db.run(
            "UPDATE prompts SET hidden_at = ? WHERE id = ?",
            [.date(date), .text(id)])
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
    ///
    /// asked 口径排除存量噪音行：库里遗留的伪用户消息全以 `<`（注入标签）或 `/`
    /// （裸斜杠命令）开头 —— 与内存分类器 PromptClassifier.isInjectedArtifact 的
    /// 前缀判据对应（SQL 侧做近似即可；采集端已排噪，新行不会再有这些前缀）。
    /// 琐碎短语（"继续"）仍计入：口径是"你问了几次"，不是"几次有价值"。
    /// 用户移除的条目（hidden_at）两边都不计：移除多半是误粘贴/不想再看到的东西。
    public func weeklyStats(from: Date, to: Date, topLimit: Int = 5) throws -> WeeklyPromptStats {
        let askedRows = try db.query("""
        SELECT source, COUNT(*) FROM prompts
        WHERE COALESCE(timestamp, first_seen) >= ? AND COALESCE(timestamp, first_seen) < ?
          AND hidden_at IS NULL
          AND text NOT LIKE '<%' AND SUBSTR(text, 1, 1) != '/'
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
        WHERE last_used_at >= ? AND last_used_at < ? AND use_count > 0 AND hidden_at IS NULL
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
