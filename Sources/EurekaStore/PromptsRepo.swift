import EurekaKit
import Foundation

/// Prompt library persistence: extraction upsert (keeps user annotations) + incremental
/// fingerprints + list/annotation reads and writes. favorite/tags/use_count/hidden_at are
/// user-written facts — re-extraction only refreshes body columns and never overwrites annotation
/// columns. "Remove" is a soft delete (hidden_at): the row stays in the table to block
/// re-extraction upserts, and every read path filters on hidden_at IS NULL.
public final class PromptsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// Extraction insert: new rows are inserted whole; existing rows only refresh body columns
    /// (text/timestamp/cwd/updated_at), while favorite/tags/use_count/last_used_at/first_seen keep
    /// their values.
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

    /// Evaluation insert: every prompt_eval column is purely derived → ON CONFLICT overwrites the
    /// whole row (no user columns to keep)
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

    /// All evaluations (prompt_id → evaluation); the service layer reads them back into its cache
    /// on refresh
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

    /// Record a session's extraction fingerprint (skip when lastActiveAt is unchanged)
    public func markExtracted(sessionId: String, source: AgentSource, at date: Date) throws {
        try db.run("""
        INSERT INTO prompt_sessions (session_id, source, extracted_at) VALUES (?,?,?)
        ON CONFLICT(session_id) DO UPDATE SET extracted_at = excluded.extracted_at
        """, [.text(sessionId), .text(source.rawValue), .date(date)])
    }

    /// Fingerprints of extracted sessions: session_id → last extraction time
    public func extractionFingerprints() throws -> [String: Date] {
        let rows = try db.query(
            "SELECT session_id, extracted_at FROM prompt_sessions"
        ) { row -> (String, Date) in
            (row.text(0) ?? "", Date(timeIntervalSince1970: row.real(1)))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Full list (first_seen descending = most recently extracted first; removed rows are not
    /// returned)
    public func all() throws -> [PromptEntry] {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts WHERE hidden_at IS NULL ORDER BY first_seen DESC, id
        """) { Self.mapRow($0) }
    }

    /// Favorite count (for the stats card; removed rows are not counted)
    public func favoriteCount() throws -> Int {
        try db.query(
            "SELECT COUNT(*) FROM prompts WHERE favorite = 1 AND hidden_at IS NULL"
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Fetch one by id (direct link to detail; a removed row is treated as nonexistent)
    public func entry(id: String) throws -> PromptEntry? {
        try db.query("""
        SELECT id, source, session_id, message_idx, text, timestamp, cwd,
               favorite, tags, use_count, last_used_at, first_seen
        FROM prompts WHERE id = ? AND hidden_at IS NULL
        """, [.text(id)]) { Self.mapRow($0) }.first
    }

    // MARK: - User annotation writes (fact data, independent of extraction refreshes)

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

    /// Reuse count: +1 and record the time
    public func recordUse(_ id: String, at date: Date = Date()) throws {
        try db.run("""
        UPDATE prompts SET use_count = use_count + 1, last_used_at = ?
        WHERE id = ?
        """, [.date(date), .text(id)])
    }

    /// Removing one = soft delete (set hidden_at). A hard delete doesn't work: while the session is
    /// still active, the next incremental extraction re-upserts the whole batch of prompts and the
    /// deleted one comes back unchanged; keeping the row means ON CONFLICT only refreshes body
    /// columns, so hidden_at survives like every other user annotation. Rows aren't auto-deleted
    /// when a session disappears either — a favorite may point at a finished session.
    public func hide(_ id: String, at date: Date = Date()) throws {
        try db.run(
            "UPDATE prompts SET hidden_at = ? WHERE id = ?",
            [.date(date), .text(id)])
    }

    // MARK: - Weekly report stats

    /// Prompt stats for the weekly report (see weeklyStats for the window semantics)
    public struct WeeklyPromptStats: Equatable {
        /// Number of new prompts asked within the window
        public var askedCount: Int
        public var bySource: [AgentSource: Int]
        /// Prompts reused within the window (last_used_at in the window, by cumulative use_count
        /// descending)
        public var topReused: [PromptEntry]
    }

    /// Weekly stats: the ask time is COALESCE(timestamp, first_seen) (some sources have no message
    /// timestamp, so it degrades to the extraction time); reuse is decided by last_used_at falling
    /// in the window (use_count is an all-time total).
    ///
    /// The asked metric excludes legacy noise rows: leftover pseudo user messages in the DB all start with `<` (injected tags) or `/`
    /// (bare slash commands) — matching the prefix test of the in-memory classifier PromptClassifier.isInjectedArtifact
    /// (an approximation on the SQL side is enough; capture already filters noise, so new rows won't have these prefixes).
    /// Trivial short phrases (e.g. "continue") still count: the metric is "how many times you asked", not "how many were valuable".
    /// Entries the user removed (hidden_at) count on neither side: removals are mostly mis-pastes or things the user doesn't want to see again.
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

    // MARK: - Row mapping

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
