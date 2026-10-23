import EurekaKit
import Foundation

/// AI session summary runs (issue #12). One row per run, kept as history: a regeneration adds a
/// row and never overwrites the previous successful summary.
///
/// User-requested artifacts, not scan-derived data → never in the migration DROP list.
public final class SummaryRunsRepo {
    private let db: SQLiteDB

    /// Diagnostic text stored per run is capped (bytes of UTF-8)
    public static let errorMessageLimit = 2000

    init(db: SQLiteDB) {
        self.db = db
    }

    static let createSQL = """
        CREATE TABLE IF NOT EXISTS summary_runs (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            status TEXT NOT NULL,
            executor TEXT NOT NULL,
            executor_version TEXT,
            model TEXT,
            template_version INTEGER NOT NULL,
            language TEXT NOT NULL,
            fingerprint TEXT NOT NULL DEFAULT '',
            coverage TEXT NOT NULL DEFAULT '{}',
            started_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            finished_at REAL,
            markdown TEXT,
            error_kind TEXT,
            error_message TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_summary_runs_session
            ON summary_runs(source, session_id, started_at DESC);
        """

    private static let columns = """
        id, source, session_id, status, executor, executor_version, model, template_version,
        language, fingerprint, coverage, started_at, updated_at, finished_at, markdown,
        error_kind, error_message, input_tokens, output_tokens, template_id, template_name,
        candidate_state
        """

    /// Insert or fully replace one run
    public func save(_ run: SummaryRunRecord) throws {
        let coverage = (try? JSONEncoder().encode(run.coverage))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        try db.run("""
            INSERT OR REPLACE INTO summary_runs (\(Self.columns))
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
            .text(run.id), .text(run.source.rawValue), .text(run.sessionId),
            .text(run.status.rawValue), .text(run.executor.rawValue),
            .string(run.executorVersion), .string(run.model),
            .int(Int64(run.templateVersion)), .text(run.language), .text(run.fingerprint),
            .text(coverage), .date(run.startedAt), .date(run.updatedAt), .date(run.finishedAt),
            .string(run.markdown), .string(run.errorKind?.rawValue),
            .string(run.errorMessage.map { Self.bounded($0) }),
            run.inputTokens.map { .int(Int64($0)) } ?? .null,
            run.outputTokens.map { .int(Int64($0)) } ?? .null,
            .string(run.templateId), .string(run.templateName),
            .string(Self.encodeDecisions(run.candidateDecisions)),
        ])
    }

    /// Records the person's per-item decisions on a run's "worth keeping" candidates
    public func updateCandidateDecisions(
        id: String, decisions: [String: SummaryCandidateDecision]
    ) throws {
        try db.run(
            "UPDATE summary_runs SET candidate_state = ? WHERE id = ?",
            [.string(Self.encodeDecisions(decisions)), .text(id)])
    }

    private static func encodeDecisions(_ decisions: [String: SummaryCandidateDecision]) -> String? {
        guard !decisions.isEmpty, let data = try? JSONEncoder().encode(decisions) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Lightweight stage update while a run progresses (no rewrite of the output columns)
    public func updateStatus(id: String, status: SummaryStage, at: Date) throws {
        try db.run(
            "UPDATE summary_runs SET status = ?, updated_at = ? WHERE id = ?",
            [.text(status.rawValue), .date(at), .text(id)])
    }

    public func run(id: String) throws -> SummaryRunRecord? {
        try db.query(
            "SELECT \(Self.columns) FROM summary_runs WHERE id = ?", [.text(id)],
            map: Self.record).first
    }

    /// Every run of one session, newest first (generation history)
    public func runs(source: AgentSource, sessionId: String, limit: Int = 50) throws -> [SummaryRunRecord] {
        try db.query("""
            SELECT \(Self.columns) FROM summary_runs
            WHERE source = ? AND session_id = ?
            ORDER BY started_at DESC LIMIT ?
            """, [.text(source.rawValue), .text(sessionId), .int(Int64(limit))], map: Self.record)
    }

    /// Most recent successful summary of one session
    public func latestCompleted(source: AgentSource, sessionId: String) throws -> SummaryRunRecord? {
        try db.query("""
            SELECT \(Self.columns) FROM summary_runs
            WHERE source = ? AND session_id = ? AND status = 'completed'
            ORDER BY finished_at DESC LIMIT 1
            """, [.text(source.rawValue), .text(sessionId)], map: Self.record).first
    }

    /// Compact per-session status for list rows: newest run status and whether any run completed.
    /// Keys are `AgentTask.key(source:sessionId:)`.
    public func statusBySession() throws -> [String: (latest: SummaryStage, hasCompleted: Bool)] {
        let rows = try db.query("""
            SELECT source, session_id, status, started_at FROM summary_runs
            ORDER BY started_at ASC
            """) { row in
            (row.text(0) ?? "", row.text(1) ?? "", row.text(2) ?? "")
        }
        var result: [String: (latest: SummaryStage, hasCompleted: Bool)] = [:]
        for (source, sessionId, statusRaw) in rows {
            guard let agent = AgentSource(rawValue: source),
                  let status = SummaryStage(rawValue: statusRaw) else { continue }
            let key = AgentTask.key(source: agent, sessionId: sessionId)
            let completed = (result[key]?.hasCompleted ?? false) || status == .completed
            result[key] = (latest: status, hasCompleted: completed)
        }
        return result
    }

    /// Launch-time reconciliation: any run still marked active belongs to a previous process that
    /// is gone. Mark it interrupted (keeping its draft) instead of showing a phantom running task.
    @discardableResult
    public func markUnfinishedInterrupted(at: Date) throws -> Int {
        let active = SummaryStage.allCases.filter(\.isActive).map { "'\($0.rawValue)'" }
            .joined(separator: ",")
        try db.run("""
            UPDATE summary_runs
            SET status = 'interrupted', error_kind = 'interrupted', updated_at = ?,
                finished_at = COALESCE(finished_at, ?)
            WHERE status IN (\(active))
            """, [.date(at), .date(at)])
        return db.changes
    }

    static func bounded(_ text: String) -> String {
        guard text.utf8.count > errorMessageLimit else { return text }
        var cut = ""
        for character in text {
            if cut.utf8.count + String(character).utf8.count > errorMessageLimit - 3 { break }
            cut.append(character)
        }
        return cut + "…"
    }

    private static func record(_ row: SQLiteRow) -> SummaryRunRecord {
        let coverage = row.text(10)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(SummaryCoverage.self, from: $0) }
            ?? SummaryCoverage()
        return SummaryRunRecord(
            id: row.text(0) ?? "",
            source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
            sessionId: row.text(2) ?? "",
            status: SummaryStage(rawValue: row.text(3) ?? "") ?? .failed,
            executor: SummaryExecutorKind(rawValue: row.text(4) ?? "") ?? .claude,
            executorVersion: row.text(5),
            model: row.text(6),
            templateVersion: Int(row.int(7)),
            templateId: row.text(19),
            templateName: row.text(20),
            language: row.text(8) ?? "en",
            fingerprint: row.text(9) ?? "",
            coverage: coverage,
            startedAt: row.date(11) ?? Date(timeIntervalSince1970: 0),
            updatedAt: row.date(12) ?? Date(timeIntervalSince1970: 0),
            finishedAt: row.date(13),
            markdown: row.text(14),
            errorKind: row.text(15).flatMap(SummaryFailureKind.init(rawValue:)),
            errorMessage: row.text(16),
            inputTokens: row.isNull(17) ? nil : Int(row.int(17)),
            outputTokens: row.isNull(18) ? nil : Int(row.int(18)),
            candidateDecisions: row.text(21)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String: SummaryCandidateDecision].self, from: $0) }
                ?? [:])
    }
}
