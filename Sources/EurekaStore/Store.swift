import Foundation
import EurekaKit

/// SQLite persistence entry point. Call every method on the same queue (in the app, UsageService's
/// queue).
public final class EurekaStore {
    public let db: SQLiteDB
    public let history: TaskHistoryRepo
    public let usage: UsageRepo
    public let scanState: ScanStateRepo
    public let sessionStats: SessionStatsRepo
    public let syncState: SyncStateRepo
    public let syncRuns: SyncRunsRepo
    public let toolCalls: ToolCallsRepo
    public let audit: AuditRepo
    public let auditArchive: AuditArchiveRepo
    public let search: SearchRepo
    public let knowledge: KnowledgeSearchRepo
    public let limitSamples: LimitSamplesRepo
    public let sessionTerminals: SessionTerminalsRepo
    public let prompts: PromptsRepo

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: path.path)
        try Schema.migrate(db)
        history = TaskHistoryRepo(db: db)
        usage = UsageRepo(db: db)
        scanState = ScanStateRepo(db: db)
        sessionStats = SessionStatsRepo(db: db)
        syncState = SyncStateRepo(db: db)
        syncRuns = SyncRunsRepo(db: db)
        toolCalls = ToolCallsRepo(db: db)
        audit = AuditRepo(db: db)
        auditArchive = AuditArchiveRepo(db: db)
        search = SearchRepo(db: db)
        knowledge = KnowledgeSearchRepo(db: db)
        limitSamples = LimitSamplesRepo(db: db)
        sessionTerminals = SessionTerminalsRepo(db: db)
        prompts = PromptsRepo(db: db)
    }

    /// Defaults to ~/Library/Application Support/Eureka/eureka.sqlite (overridden by
    /// EUREKA_DB_PATH)
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_DB_PATH"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Eureka/eureka.sqlite")
    }
}

public final class TaskHistoryRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public func insert(_ task: FinishedTask) throws {
        try db.run("""
        INSERT OR REPLACE INTO task_history
            (id, source, session_id, title, cwd, started_at, session_started_at,
             finished_at, outcome, detail)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(task.id), .text(task.source.rawValue), .text(task.sessionId),
            .string(task.title), .string(task.cwd),
            .date(task.startedAt), .date(task.sessionStartedAt), .date(task.finishedAt),
            .text(task.outcome.rawValue), .string(task.detail),
        ])
    }

    /// Task outcome counts in a range (finished_at within the range; feeds the weekly report's
    /// success/failure/interrupted rates)
    public func outcomeCounts(from: Date, to: Date) throws -> [String: Int] {
        let rows = try db.query("""
        SELECT outcome, COUNT(*) FROM task_history
        WHERE finished_at >= ? AND finished_at < ?
        GROUP BY outcome
        """, [.date(from), .date(to)]) { row in
            (row.text(0) ?? "", Int(row.int(1)))
        }
        return Dictionary(uniqueKeysWithValues: rows)
    }

    public func recent(limit: Int = 50) throws -> [FinishedTask] {
        try db.query("""
        SELECT source, session_id, title, cwd, started_at, session_started_at,
               finished_at, outcome, detail
        FROM task_history ORDER BY finished_at DESC LIMIT ?
        """, [.int(Int64(limit))]) { row in
            Self.rowToTask(row)
        }
    }

    /// Tasks in a range (finished_at >= since, newest first; used by the history page's 14-day
    /// window). `recent(limit:)` is kept so callers such as the weekly report keep the same
    /// semantics.
    public func tasks(since: Date, limit: Int) throws -> [FinishedTask] {
        try db.query("""
        SELECT source, session_id, title, cwd, started_at, session_started_at,
               finished_at, outcome, detail
        FROM task_history WHERE finished_at >= ?
        ORDER BY finished_at DESC LIMIT ?
        """, [.date(since), .int(Int64(limit))]) { row in
            Self.rowToTask(row)
        }
    }

    /// Counts aggregated by day × outcome (local-time day boundaries; feeds the history page's
    /// "tasks, last 14 days" stacked chart). Same SQL pattern as UsageRepo.dailyRows; days without
    /// tasks are omitted and the UI layer fills in zeros.
    public func dailyOutcomeCounts(
        since: Date
    ) throws -> [(day: String, outcome: String, count: Int)] {
        try db.query("""
        SELECT strftime('%Y-%m-%d', finished_at, 'unixepoch', 'localtime') AS day,
               outcome, COUNT(*)
        FROM task_history
        WHERE finished_at >= ?
        GROUP BY day, outcome
        ORDER BY day
        """, [.date(since)]) { row in
            (row.text(0) ?? "", row.text(1) ?? "", Int(row.int(2)))
        }
    }

    private static func rowToTask(_ row: SQLiteRow) -> FinishedTask {
        FinishedTask(
            source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
            sessionId: row.text(1) ?? "",
            title: row.text(2),
            cwd: row.text(3),
            startedAt: row.date(4),
            sessionStartedAt: row.date(5),
            finishedAt: row.date(6) ?? Date(),
            outcome: TaskOutcome(rawValue: row.text(7) ?? "") ?? .success,
            detail: row.text(8)
        )
    }
}

public final class UsageRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public func insert(_ records: [UsageRecord]) throws {
        for record in records {
            _ = try insertReturningId(record)
        }
    }

    /// Insert and return the rowid (used to back-fill output for a dedup key)
    public func insertReturningId(_ record: UsageRecord) throws -> Int64 {
        try db.run("""
        INSERT INTO usage_records
            (source, model, project, session_id, ts, input_tokens, output_tokens,
             cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, provider,
             reported_cost_usd)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(record.source.rawValue), .text(record.model),
            .string(record.project),
            .string(record.sessionId),
            .real(record.timestamp.timeIntervalSince1970),
            .int(Int64(record.inputTokens)), .int(Int64(record.outputTokens)),
            .int(Int64(record.cacheCreationTokens)),
            .int(Int64(record.cacheCreation1hTokens)),
            .int(Int64(record.cacheReadTokens)),
            .string(record.provider),
            record.reportedCostUSD.map { .real($0) } ?? .null,
        ])
        return db.lastInsertRowID
    }

    /// Delete every record of a session (sources whose files get rewritten and rescanned from zero
    /// clear first, so nothing is counted twice)
    public func deleteRecords(source: AgentSource, sessionId: String) throws {
        try db.run(
            "DELETE FROM usage_records WHERE source = ? AND session_id = ?",
            [.text(source.rawValue), .text(sessionId)])
    }

    /// Provider back-fill: only writes rows still NULL (when ts is nil, matches on the whole
    /// session × model)
    public func backfillProvider(
        source: AgentSource, sessionId: String, model: String?, ts: Double?, provider: String
    ) throws {
        var conditions = ["source = ?", "session_id = ?", "provider IS NULL"]
        var bindings: [SQLiteValue] = [.text(source.rawValue), .text(sessionId)]
        if let model {
            conditions.append("model = ?")
            bindings.append(.text(model))
        }
        if let ts {
            conditions.append("ts = ?")
            bindings.append(.real(ts))
        }
        try db.run(
            "UPDATE usage_records SET provider = ? WHERE " + conditions.joined(separator: " AND "),
            [.text(provider)] + bindings)
    }

    /// Output growth on streamed duplicate rows: overwrite with the larger final value
    public func updateOutputTokens(recordId: Int64, outputTokens: Int) throws {
        try db.run(
            "UPDATE usage_records SET output_tokens = ? WHERE id = ?",
            [.int(Int64(outputTokens)), .int(recordId)])
    }

    /// Aggregate by (project, source, model) over a time range (per-project stats / cost
    /// conversion); `source` means the same as in `totalsBySession`: nil = all sources.
    public func totalsByProject(
        from: Date, to: Date, source: AgentSource? = nil
    ) throws -> [(project: String?, totals: UsageTotals)] {
        var conditions = ["ts >= ?", "ts < ?"]
        var bindings: [SQLiteValue] = [
            .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
        ]
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        return try db.query("""
        SELECT project, source, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
        FROM usage_records
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY project, source, model, provider
        """, bindings) { row in
            (row.text(0), UsageTotals(
                source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                model: row.text(2) ?? "?",
                inputTokens: Int(row.int(3)),
                outputTokens: Int(row.int(4)),
                cacheCreationTokens: Int(row.int(5)),
                cacheCreation1hTokens: Int(row.int(6)),
                cacheReadTokens: Int(row.int(7)),
                requestCount: Int(row.int(8)),
                provider: row.text(9),
                reportedCostUSD: row.isNull(10) ? nil : row.real(10)
            ))
        }
    }

    /// Per-session × model aggregates for a given set of sessions (session-level cost display)
    public func totalsForSessions(_ ids: [String]) throws -> [String: [UsageTotals]] {
        var result: [String: [UsageTotals]] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({
            Array(ids[$0..<min($0 + 500, ids.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("""
            SELECT session_id, source, model,
                   SUM(input_tokens), SUM(output_tokens),
                   SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
                   SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
            FROM usage_records
            WHERE session_id IN (\(placeholders))
            GROUP BY session_id, source, model, provider
            """, chunk.map { .text($0) }) { row -> (String, UsageTotals) in
                (row.text(0) ?? "", UsageTotals(
                    source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                    model: row.text(2) ?? "?",
                    inputTokens: Int(row.int(3)),
                    outputTokens: Int(row.int(4)),
                    cacheCreationTokens: Int(row.int(5)),
                    cacheCreation1hTokens: Int(row.int(6)),
                    cacheReadTokens: Int(row.int(7)),
                    requestCount: Int(row.int(8)),
                    provider: row.text(9),
                    reportedCostUSD: row.isNull(10) ? nil : row.real(10)
                ))
            }
            for (sessionId, totals) in rows {
                result[sessionId, default: []].append(totals)
            }
        }
        return result
    }

    /// Time-bucket granularity for trends / exports
    public enum TrendGranularity: String, Sendable {
        case day   // yyyy-MM-dd
        case hour  // yyyy-MM-dd HH:00 (for short-range trends)

        var bucketExpr: String {
            switch self {
            case .day: return "strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime')"
            case .hour: return "strftime('%Y-%m-%d %H:00', ts, 'unixepoch', 'localtime')"
            }
        }
    }

    /// Daily/hourly export aggregates (CSV / trend chart), local-time boundaries
    public func dailyRows(
        from: Date, to: Date, granularity: TrendGranularity = .day
    ) throws -> [DailyUsageRow] {
        try db.query("""
        SELECT \(granularity.bucketExpr) AS day,
               source, model, COALESCE(project, ''),
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY day, source, model, project, provider
        ORDER BY day, source, model
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
            DailyUsageRow(
                day: row.text(0) ?? "",
                project: row.text(3) ?? "",
                totals: UsageTotals(
                    source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                    model: row.text(2) ?? "?",
                    inputTokens: Int(row.int(4)),
                    outputTokens: Int(row.int(5)),
                    cacheCreationTokens: Int(row.int(6)),
                    cacheCreation1hTokens: Int(row.int(7)),
                    cacheReadTokens: Int(row.int(8)),
                    requestCount: Int(row.int(9)),
                    provider: row.text(10),
                    reportedCostUSD: row.isNull(11) ? nil : row.real(11)
                )
            )
        }
    }

    /// Raw usage record row (for the paginated request log)
    public struct UsageRecordRow: Equatable, Sendable {
        public var source: AgentSource
        public var model: String
        public var project: String?
        public var ts: Date
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheCreationTokens: Int
        public var cacheCreation1hTokens: Int
        public var cacheReadTokens: Int
        public var provider: String?
        public var reportedCostUSD: Double?
    }

    /// Request log: page through raw records newest first (backed by idx_usage_ts)
    public func recentRecords(
        from: Date? = nil, to: Date? = nil, source: AgentSource? = nil,
        limit: Int, offset: Int = 0
    ) throws -> [UsageRecordRow] {
        let (whereClause, bindings) = Self.recordFilter(from: from, to: to, source: source)
        return try db.query("""
        SELECT source, model, project, ts, input_tokens, output_tokens,
               cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, provider,
               reported_cost_usd
        FROM usage_records \(whereClause)
        ORDER BY ts DESC LIMIT ? OFFSET ?
        """, bindings + [.int(Int64(limit)), .int(Int64(offset))]) { row in
            UsageRecordRow(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                model: row.text(1) ?? "?",
                project: row.text(2),
                ts: Date(timeIntervalSince1970: row.real(3)),
                inputTokens: Int(row.int(4)),
                outputTokens: Int(row.int(5)),
                cacheCreationTokens: Int(row.int(6)),
                cacheCreation1hTokens: Int(row.int(7)),
                cacheReadTokens: Int(row.int(8)),
                provider: row.text(9),
                reportedCostUSD: row.isNull(10) ? nil : row.real(10))
        }
    }

    /// Total request-log row count (for the pager's "N total" label)
    public func recordCount(
        from: Date? = nil, to: Date? = nil, source: AgentSource? = nil
    ) throws -> Int {
        let (whereClause, bindings) = Self.recordFilter(from: from, to: to, source: source)
        return try db.query(
            "SELECT COUNT(*) FROM usage_records \(whereClause)", bindings
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Build the WHERE clause dynamically (ts >= / ts < / source =); returns the clause and its
    /// bindings
    private static func recordFilter(
        from: Date?, to: Date?, source: AgentSource?
    ) -> (String, [SQLiteValue]) {
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let from {
            conditions.append("ts >= ?")
            bindings.append(.real(from.timeIntervalSince1970))
        }
        if let to {
            conditions.append("ts < ?")
            bindings.append(.real(to.timeIntervalSince1970))
        }
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        let clause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (clause, bindings)
    }

    /// (session × source × model) aggregate row (for the per-session usage ranking; the model
    /// dimension is kept so the price table can compute cost)
    public struct SessionUsageRow: Equatable, Sendable {
        public var sessionId: String
        public var project: String?
        public var lastTs: Date  // The session's most recent record within the range
        public var totals: UsageTotals
    }

    /// Aggregate by session over a time range (rows without session_id excluded); callers sort /
    /// limit after computing cost
    public func totalsBySession(
        from: Date, to: Date, source: AgentSource? = nil
    ) throws -> [SessionUsageRow] {
        var conditions = ["ts >= ?", "ts < ?", "session_id IS NOT NULL", "session_id != ''"]
        var bindings: [SQLiteValue] = [
            .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
        ]
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        return try db.query("""
        SELECT session_id, source, model, MAX(project), MAX(ts),
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
        FROM usage_records
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY session_id, source, model, provider
        """, bindings) { row in
            SessionUsageRow(
                sessionId: row.text(0) ?? "",
                project: row.text(3),
                lastTs: Date(timeIntervalSince1970: row.real(4)),
                totals: UsageTotals(
                    source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                    model: row.text(2) ?? "?",
                    inputTokens: Int(row.int(5)),
                    outputTokens: Int(row.int(6)),
                    cacheCreationTokens: Int(row.int(7)),
                    cacheCreation1hTokens: Int(row.int(8)),
                    cacheReadTokens: Int(row.int(9)),
                    requestCount: Int(row.int(10)),
                    provider: row.text(11),
                    reportedCostUSD: row.isNull(12) ? nil : row.real(12)
                ))
        }
    }

    /// Activity heatmap cell (weekday uses SQLite %w semantics: 0=Sunday … 6=Saturday, local time)
    public struct HeatmapCell: Equatable, Sendable {
        public var weekday: Int  // 0-6 (0=Sunday)
        public var hour: Int     // 0-23
        public var requests: Int
        public var tokens: Int

        public init(weekday: Int, hour: Int, requests: Int, tokens: Int) {
            self.weekday = weekday
            self.hour = hour
            self.requests = requests
            self.tokens = tokens
        }
    }

    /// Week × 24-hour aggregate (one SQL aggregation, at most 168 rows)
    public func hourlyHeatmap(
        from: Date, to: Date, source: AgentSource? = nil
    ) throws -> [HeatmapCell] {
        var conditions = ["ts >= ?", "ts < ?"]
        var bindings: [SQLiteValue] = [
            .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
        ]
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        return try db.query("""
        SELECT CAST(strftime('%w', ts, 'unixepoch', 'localtime') AS INTEGER) AS wd,
               CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) AS hr,
               COUNT(*),
               SUM(input_tokens + output_tokens + cache_creation_tokens + cache_read_tokens)
        FROM usage_records
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY wd, hr
        """, bindings) { row in
            HeatmapCell(
                weekday: Int(row.int(0)),
                hour: Int(row.int(1)),
                requests: Int(row.int(2)),
                tokens: Int(row.int(3)))
        }
    }

    /// Aggregate by (source, model) over a time range Distinct (local date, hour) buckets that had
    /// requests in the range: the weekly report's "active hours / late-night days" metric (same
    /// basis as the heatmap)
    public func activeHourBuckets(from: Date, to: Date) throws -> [(day: String, hour: Int)] {
        try db.query("""
        SELECT DISTINCT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime'),
               CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        """, [.date(from), .date(to)]) { row in
            (day: row.text(0) ?? "", hour: Int(row.int(1)))
        }
    }

    /// Every (source, model, provider) ever seen in the ledger with its token volume (for the
    /// unpriced-models list)
    public func distinctModels() throws -> [UsageTotals] {
        try db.query("""
        SELECT source, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
        FROM usage_records
        GROUP BY source, model, provider
        ORDER BY source, model
        """) { row in
            UsageTotals(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                model: row.text(1) ?? "?",
                inputTokens: Int(row.int(2)),
                outputTokens: Int(row.int(3)),
                cacheCreationTokens: Int(row.int(4)),
                cacheCreation1hTokens: Int(row.int(5)),
                cacheReadTokens: Int(row.int(6)),
                requestCount: Int(row.int(7)),
                provider: row.text(8),
                reportedCostUSD: row.isNull(9) ? nil : row.real(9))
        }
    }

    public func totalsByModel(from: Date, to: Date) throws -> [UsageTotals] {
        try db.query("""
        SELECT source, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*), provider, SUM(reported_cost_usd)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY source, model, provider
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
            UsageTotals(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                model: row.text(1) ?? "?",
                inputTokens: Int(row.int(2)),
                outputTokens: Int(row.int(3)),
                cacheCreationTokens: Int(row.int(4)),
                cacheCreation1hTokens: Int(row.int(5)),
                cacheReadTokens: Int(row.int(6)),
                requestCount: Int(row.int(7)),
                provider: row.text(8),
                reportedCostUSD: row.isNull(9) ? nil : row.real(9)
            )
        }
    }
}

/// CSV export row (by day × source × model × project)
public struct DailyUsageRow: Equatable, Sendable {
    public var day: String
    public var project: String
    public var totals: UsageTotals

    public init(day: String, project: String, totals: UsageTotals) {
        self.day = day
        self.project = project
        self.totals = totals
    }
}

/// (source, model, provider) aggregate; provider only matters for pricing, the display layer merges
/// by model
public struct UsageTotals: Equatable, Sendable {
    public var source: AgentSource
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheCreation1hTokens: Int
    public var cacheReadTokens: Int
    public var requestCount: Int
    public var provider: String?
    /// Sum of agent-reported cost (Grok only; nil = nothing reported, use the price table)
    public var reportedCostUSD: Double?

    public init(
        source: AgentSource, model: String,
        inputTokens: Int, outputTokens: Int,
        cacheCreationTokens: Int, cacheCreation1hTokens: Int,
        cacheReadTokens: Int, requestCount: Int,
        provider: String? = nil, reportedCostUSD: Double? = nil
    ) {
        self.source = source
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.requestCount = requestCount
        self.provider = provider
        self.reportedCostUSD = reportedCostUSD
    }
}

/// Conversation count per session (counted by the usage scanners in passing)
public final class SessionStatsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// Overwrite when reset=true (full rescan of the file), otherwise accumulate
    public func recordPrompts(path: String, sessionId: String, count: Int, reset: Bool) throws {
        if reset {
            try db.run("""
            INSERT OR REPLACE INTO session_stats (path, session_id, prompts) VALUES (?,?,?)
            """, [.text(path), .text(sessionId), .int(Int64(count))])
        } else {
            guard count > 0 else { return }
            try db.run("""
            INSERT INTO session_stats (path, session_id, prompts) VALUES (?,?,?)
            ON CONFLICT(path) DO UPDATE SET prompts = prompts + excluded.prompts
            """, [.text(path), .text(sessionId), .int(Int64(count))])
        }
    }

    /// Conversation counts for a given set of sessions
    public func promptCounts(for ids: [String]) throws -> [String: Int] {
        var result: [String: Int] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({
            Array(ids[$0..<min($0 + 500, ids.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query("""
            SELECT session_id, SUM(prompts) FROM session_stats
            WHERE session_id IN (\(placeholders)) GROUP BY session_id
            """, chunk.map { .text($0) }) { row -> (String, Int) in
                (row.text(0) ?? "", Int(row.int(1)))
            }
            for (id, count) in rows {
                result[id] = count
            }
        }
        return result
    }
}

public final class ScanStateRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct FileState: Equatable {
        public var inode: Int64
        public var offset: Int64
        public var extra: String?

        public init(inode: Int64, offset: Int64, extra: String? = nil) {
            self.inode = inode
            self.offset = offset
            self.extra = extra
        }
    }

    public func fileState(path: String) throws -> FileState? {
        try db.query(
            "SELECT inode, offset, extra FROM scan_files WHERE path = ?",
            [.text(path)]
        ) { row in
            FileState(inode: row.int(0), offset: row.int(1), extra: row.text(2))
        }.first
    }

    public func setFileState(path: String, _ state: FileState) throws {
        try db.run("""
        INSERT OR REPLACE INTO scan_files (path, inode, offset, extra) VALUES (?,?,?,?)
        """, [.text(path), .int(state.inode), .int(state.offset), .string(state.extra)])
    }

    public struct DedupEntry: Equatable {
        public var recordId: Int64?
        public var outputTokens: Int

        public init(recordId: Int64?, outputTokens: Int) {
            self.recordId = recordId
            self.outputTokens = outputTokens
        }
    }

    /// Returns the keys that already exist → (record id, recorded output)
    public func existingDedupKeys(_ keys: [String]) throws -> [String: DedupEntry] {
        var existing: [String: DedupEntry] = [:]
        for chunk in stride(from: 0, to: keys.count, by: 500).map({
            Array(keys[$0..<min($0 + 500, keys.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = try db.query(
                "SELECT key, record_id, output_tokens FROM dedup_keys WHERE key IN (\(placeholders))",
                chunk.map { .text($0) }
            ) { row -> (String, DedupEntry) in
                (row.text(0) ?? "",
                 DedupEntry(
                    recordId: row.isNull(1) ? nil : row.int(1),
                    outputTokens: Int(row.int(2))))
            }
            for (key, entry) in rows {
                existing[key] = entry
            }
        }
        return existing
    }

    public func upsertDedupKey(
        _ key: String, recordId: Int64?, outputTokens: Int, at date: Date
    ) throws {
        try db.run("""
        INSERT INTO dedup_keys (key, ts, record_id, output_tokens) VALUES (?,?,?,?)
        ON CONFLICT(key) DO UPDATE SET output_tokens = excluded.output_tokens
        """, [
            .text(key), .real(date.timeIntervalSince1970),
            recordId.map { .int($0) } ?? .null, .int(Int64(outputTokens)),
        ])
    }

    /// Prune to an 8-day window (resume/fork only copy recent rows, so old keys carry no collision
    /// risk)
    public func pruneDedupKeys(before: Date) throws {
        try db.run(
            "DELETE FROM dedup_keys WHERE ts < ?",
            [.real(before.timeIntervalSince1970)])
    }

    public func transaction(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }
}

/// Cloud backup state: path → local fingerprint at the last successful upload (the diff baseline
/// for incremental sync)
public final class SyncStateRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct Entry: Equatable {
        public var path: String
        public var remoteKey: String
        public var size: Int64
        public var mtime: Double
        public var etag: String?
        public var uploadedAt: Date
        /// Backup category (`SyncCandidate.category`, e.g. `claude/skills`). Old rows lack this
        /// column → nil, and the composition stats fall back to parsing remote_key.
        public var category: String?

        public init(
            path: String, remoteKey: String, size: Int64, mtime: Double,
            etag: String? = nil, uploadedAt: Date, category: String? = nil
        ) {
            self.path = path
            self.remoteKey = remoteKey
            self.size = size
            self.mtime = mtime
            self.etag = etag
            self.uploadedAt = uploadedAt
            self.category = category
        }
    }

    public func entry(path: String) throws -> Entry? {
        try db.query("""
        SELECT path, remote_key, size, mtime, etag, uploaded_at, category
        FROM sync_state WHERE path = ?
        """, [.text(path)]) { Self.mapRow($0) }.first
    }

    /// Load everything to diff (a few thousand entries; one SELECT is acceptable)
    public func allEntries() throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        let rows = try db.query("""
        SELECT path, remote_key, size, mtime, etag, uploaded_at, category FROM sync_state
        """) { Self.mapRow($0) }
        for entry in rows {
            result[entry.path] = entry
        }
        return result
    }

    public func upsert(_ entry: Entry) throws {
        try db.run("""
        INSERT OR REPLACE INTO sync_state
            (path, remote_key, size, mtime, etag, uploaded_at, category)
        VALUES (?,?,?,?,?,?,?)
        """, [
            .text(entry.path), .text(entry.remoteKey),
            .int(entry.size), .real(entry.mtime),
            .string(entry.etag), .real(entry.uploadedAt.timeIntervalSince1970),
            .string(entry.category),
        ])
    }

    /// Backup totals (shown on the Backup tab)
    public struct Stats: Equatable {
        public var fileCount: Int
        public var totalBytes: Int64
        public var lastUploadAt: Date?

        public init(fileCount: Int, totalBytes: Int64, lastUploadAt: Date?) {
            self.fileCount = fileCount
            self.totalBytes = totalBytes
            self.lastUploadAt = lastUploadAt
        }
    }

    public func stats() throws -> Stats {
        try db.query("""
        SELECT COUNT(*), COALESCE(SUM(size), 0), MAX(uploaded_at) FROM sync_state
        """) { row in
            Stats(
                fileCount: Int(row.int(0)),
                totalBytes: row.int(1),
                lastUploadAt: row.isNull(2) ? nil : Date(timeIntervalSince1970: row.real(2)))
        }.first ?? Stats(fileCount: 0, totalBytes: 0, lastUploadAt: nil)
    }

    /// One cell of the backup composition: file count and bytes for one category under one source
    public struct CompositionBucket: Equatable, Sendable {
        /// Source segment (`AgentSource.rawValue` or `custom`)
        public var source: String
        /// Category segment (`skills` / `projects` / `plans` / `memories`…);
        /// nil for root files (CLAUDE.md, SOUL.md and the like, whose category equals the source)
        public var kind: String?
        public var count: Int
        public var bytes: Int64

        public init(source: String, kind: String?, count: Int, bytes: Int64) {
            self.source = source
            self.kind = kind
            self.count = count
            self.bytes = bytes
        }
    }

    /// Backup composition (two levels: source → category).
    ///
    /// Prefers the `category` column (`SyncCandidate.category`, exact); old rows have NULL there →
    /// fall back to parsing `remote_key`, where the 4th segment is the category when there are ≥5 segments.
    /// ⚠️ With exactly 4 segments the 4th is a **file name**, not a category (a root file); splitting blindly invents fake categories.
    public func composition() throws -> [CompositionBucket] {
        let rows = try db.query(
            "SELECT remote_key, size, category FROM sync_state"
        ) { row in (row.text(0) ?? "", row.int(1), row.text(2)) }

        var buckets: [String: CompositionBucket] = [:]
        for (key, size, category) in rows {
            let source: String
            var kind: String?
            if let category, !category.isEmpty {
                let parts = category.split(separator: "/", maxSplits: 1)
                source = String(parts[0])
                // Keep only the first category segment: `claude/skills/project/<name>` goes under
                // skills
                kind = parts.count > 1
                    ? parts[1].split(separator: "/").first.map(String.init) : nil
            } else {
                // Old rows (uploaded before the category column existed): derive from remote_key.
                // key = `<prefix>/<host>/<source>/<category>/…`, so parts[3] is the category —
                // **but only with ≥5 segments**: with exactly 4, that segment is a file name (a
                // root file; inspected locally: GEMINI.md / projects.json / opencode.db / AGENTS.md
                // / SOUL.md, 5 in total).
                let parts = key.split(separator: "/")
                guard parts.count >= 3 else { continue }
                source = String(parts[2])
                kind = parts.count >= 5 ? String(parts[3]) : nil
            }
            let bucketKey = "\(source)/\(kind ?? "")"
            var bucket = buckets[bucketKey]
                ?? CompositionBucket(source: source, kind: kind, count: 0, bytes: 0)
            bucket.count += 1
            bucket.bytes += size
            buckets[bucketKey] = bucket
        }
        return buckets.values.sorted {
            $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.source < $1.source
        }
    }

    /// Compatibility for old call sites: totals by source only (the new UI uses `composition()`)
    public func sourceComposition() throws -> [String: (count: Int, bytes: Int64)] {
        var result: [String: (count: Int, bytes: Int64)] = [:]
        for bucket in try composition() {
            var entry = result[bucket.source] ?? (0, 0)
            entry.count += bucket.count
            entry.bytes += bucket.bytes
            result[bucket.source] = entry
        }
        return result
    }

    /// Clear state for files that vanished locally (remote copies are not deleted; upload-only)
    public func deletePaths(_ paths: [String]) throws {
        for chunk in stride(from: 0, to: paths.count, by: 500).map({
            Array(paths[$0..<min($0 + 500, paths.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.run(
                "DELETE FROM sync_state WHERE path IN (\(placeholders))",
                chunk.map { .text($0) })
        }
    }

    public func transaction(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }

    private static func mapRow(_ row: SQLiteRow) -> Entry {
        Entry(
            path: row.text(0) ?? "",
            remoteKey: row.text(1) ?? "",
            size: row.int(2),
            mtime: row.real(3),
            etag: row.text(4),
            uploadedAt: Date(timeIntervalSince1970: row.real(5)),
            category: row.text(6))
    }
}

/// Cloud backup run history: per-run summary + file details (paginated display + file names /
/// sizes)
public final class SyncRunsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct RunFile: Equatable, Sendable {
        public var name: String
        public var size: Int64
        /// Source category (e.g. "claude/skills", "custom/notes"); nil for old records without this
        /// field
        public var category: String?
        public init(name: String, size: Int64, category: String? = nil) {
            self.name = name
            self.size = size
            self.category = category
        }
    }

    public struct Run: Equatable, Sendable, Identifiable {
        public var id: Int64
        public var date: Date
        public var uploaded: Int
        public var uploadedBytes: Int64
        public var failed: Int
        public var deferred: Int
        public var error: String?
        public var files: [RunFile]
    }

    public func insert(
        date: Date, uploaded: Int, uploadedBytes: Int64,
        failed: Int, deferred: Int, error: String?, files: [RunFile]
    ) throws {
        let json = Self.encodeFiles(files)
        try db.run("""
        INSERT INTO sync_runs (ts, uploaded, uploaded_bytes, failed, deferred, error, files)
        VALUES (?,?,?,?,?,?,?)
        """, [
            .real(date.timeIntervalSince1970), .int(Int64(uploaded)),
            .int(uploadedBytes), .int(Int64(failed)), .int(Int64(deferred)),
            .string(error), .string(json),
        ])
    }

    /// Paginated, newest first
    public func recent(limit: Int, offset: Int = 0) throws -> [Run] {
        try db.query("""
        SELECT id, ts, uploaded, uploaded_bytes, failed, deferred, error, files
        FROM sync_runs ORDER BY ts DESC LIMIT ? OFFSET ?
        """, [.int(Int64(limit)), .int(Int64(offset))]) { row in
            Run(
                id: row.int(0),
                date: Date(timeIntervalSince1970: row.real(1)),
                uploaded: Int(row.int(2)),
                uploadedBytes: row.int(3),
                failed: Int(row.int(4)),
                deferred: Int(row.int(5)),
                error: row.text(6),
                files: Self.decodeFiles(row.text(7)))
        }
    }

    public func count() throws -> Int {
        try db.query("SELECT COUNT(*) FROM sync_runs") { Int($0.int(0)) }.first ?? 0
    }

    /// Keep only the most recent N runs
    public func prune(keepingLast: Int) throws {
        try db.run("""
        DELETE FROM sync_runs WHERE id NOT IN (
            SELECT id FROM sync_runs ORDER BY ts DESC LIMIT ?
        )
        """, [.int(Int64(keepingLast))])
    }

    // MARK: - files JSON (keys n=name / s=bytes / c=source category; c was added later, old rows default compatibly)

    public static func encodeFiles(_ files: [RunFile]) -> String? {
        guard !files.isEmpty else { return nil }
        let array = files.map { file -> [String: Any] in
            var item: [String: Any] = ["n": file.name, "s": file.size]
            if let category = file.category, !category.isEmpty { item["c"] = category }
            return item
        }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeFiles(_ json: String?) -> [RunFile] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let name = item["n"] as? String else { return nil }
            let size = (item["s"] as? NSNumber)?.int64Value ?? 0
            return RunFile(name: name, size: size, category: item["c"] as? String)
        }
    }
}

/// Tool / skill / plugin / subagent call counts (aggregated by day × source × kind × name ×
/// session; only Claude writes real session values; counted by the usage scanners in passing)
public final class ToolCallsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct ToolCallTotal: Equatable, Sendable {
        public var source: AgentSource
        public var kind: String
        public var name: String
        public var count: Int
    }

    /// All-time skill call stats (for the Skills analysis view: total count / last active / tokens
    /// at trigger). public init: the app layer back-fills rows for sources the audit log doesn't
    /// cover (Hermes' count file).
    public struct SkillUsageStat: Equatable, Sendable, Identifiable {
        public var source: AgentSource
        public var name: String
        public var count: Int
        public var lastTs: Date?
        public var tokens: Int
        public var id: String { "\(source.rawValue):\(name)" }

        public init(source: AgentSource, name: String, count: Int, lastTs: Date?, tokens: Int) {
            self.source = source
            self.name = name
            self.count = count
            self.lastTs = lastTs
            self.tokens = tokens
        }
    }

    /// All-time aggregate of MCP calls by raw name (the name's shape varies by source: codex/kimi
    /// use `server.tool`, Claude uses `mcp__server__tool` — server-prefix extraction happens in the
    /// app layer; SQL only aggregates)
    public struct MCPCallTotal: Equatable, Sendable {
        public var name: String
        public var count: Int
        public var lastTs: Double
    }

    public func mcpNameTotals() throws -> [MCPCallTotal] {
        try db.query("""
        SELECT name, SUM(count), MAX(last_ts) FROM tool_calls
        WHERE kind = 'mcp' GROUP BY name
        """) { row in
            MCPCallTotal(
                name: row.text(0) ?? "",
                count: Int(row.int(1)),
                lastTs: row.real(2))
        }
    }

    /// All-time aggregate of MCP calls by (day, raw name) (detail page per-server trend and top
    /// tools; server-prefix extraction still happens in the app layer; SQL only aggregates)
    public struct MCPDailyTotal: Equatable, Sendable {
        public var day: String
        public var name: String
        public var count: Int
    }

    public func mcpDailyTotals() throws -> [MCPDailyTotal] {
        try db.query("""
        SELECT day, name, SUM(count) FROM tool_calls
        WHERE kind = 'mcp' GROUP BY day, name
        """) { row in
            MCPDailyTotal(
                day: row.text(0) ?? "",
                name: row.text(1) ?? "",
                count: Int(row.int(2)))
        }
    }

    /// Accumulate counts (merging on day/source/kind/name/session); last_ts keeps the larger value,
    /// tokens add up. session: the triggering session id (only the Claude scanner passes a real
    /// value, others default to empty — consistent with per-skill data currently being
    /// Claude-only).
    public func bump(
        day: String, source: AgentSource, kind: String, name: String,
        by count: Int = 1, ts: Double = 0, tokens: Int = 0, session: String = ""
    ) throws {
        guard count > 0, !name.isEmpty else { return }
        try db.run("""
        INSERT INTO tool_calls (day, source, kind, name, session_id, count, last_ts, tokens)
        VALUES (?,?,?,?,?,?,?,?)
        ON CONFLICT(day, source, kind, name, session_id) DO UPDATE SET
            count = count + excluded.count,
            last_ts = MAX(last_ts, excluded.last_ts),
            tokens = tokens + excluded.tokens
        """, [
            .text(day), .text(source.rawValue), .text(kind), .text(name), .text(session),
            .int(Int64(count)), .real(ts), .int(Int64(tokens)),
        ])
    }

    /// Aggregate by (source, kind, name) over a time range, count descending
    public func totals(
        from: Date, to: Date, source: AgentSource? = nil
    ) throws -> [ToolCallTotal] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var conditions = ["day >= ?", "day <= ?"]
        var bindings: [SQLiteValue] = [
            .text(formatter.string(from: from)), .text(formatter.string(from: to)),
        ]
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        return try db.query("""
        SELECT source, kind, name, SUM(count) FROM tool_calls
        \(whereClause)
        GROUP BY source, kind, name
        ORDER BY SUM(count) DESC
        """, bindings) { row in
            ToolCallTotal(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                kind: row.text(1) ?? "",
                name: row.text(2) ?? "",
                count: Int(row.int(3)))
        }
    }

    /// Skill call stats (kind='skill'), by total count descending. from/to omitted = all-time
    /// totals (the "total count / last active" metric); when given, filter by the day window (the
    /// Top ranking metric).
    public func skillStats(
        source: AgentSource? = nil, from: Date? = nil, to: Date? = nil
    ) throws -> [SkillUsageStat] {
        try statsByName(kind: "skill", source: source, from: from, to: to)
    }

    /// Subagent call stats (kind='agent'), by total count descending (only Claude / Kimi record
    /// subagent calls).
    public func agentStats(
        source: AgentSource? = nil, from: Date? = nil, to: Date? = nil
    ) throws -> [SkillUsageStat] {
        try statsByName(kind: "agent", source: source, from: from, to: to)
    }

    /// Call stats for one kind aggregated by (source, name) (count descending). Shared by skill /
    /// agent.
    private func statsByName(
        kind: String, source: AgentSource?, from: Date?, to: Date?
    ) throws -> [SkillUsageStat] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var conditions = ["kind = ?"]
        var bindings: [SQLiteValue] = [.text(kind)]
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        if let from {
            conditions.append("day >= ?")
            bindings.append(.text(formatter.string(from: from)))
        }
        if let to {
            conditions.append("day <= ?")
            bindings.append(.text(formatter.string(from: to)))
        }
        let whereClause = "WHERE " + conditions.joined(separator: " AND ")
        return try db.query("""
        SELECT source, name, SUM(count), MAX(last_ts), SUM(tokens) FROM tool_calls
        \(whereClause)
        GROUP BY source, name
        ORDER BY SUM(count) DESC
        """, bindings) { row in
            let rawTs = row.real(3)
            return SkillUsageStat(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                name: row.text(1) ?? "",
                count: Int(row.int(2)),
                lastTs: rawTs > 0 ? Date(timeIntervalSince1970: rawTs) : nil,
                tokens: Int(row.int(4)))
        }
    }

    /// Daily call-count series for one item (source × kind × name) (detail page trend chart; day is
    /// already the primary-key prefix, zero schema change).
    public func dailySeries(
        source: AgentSource, kind: String, name: String, from: Date, to: Date
    ) throws -> [(day: Date, count: Int)] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return try db.query("""
        SELECT day, SUM(count) FROM tool_calls
        WHERE source = ? AND kind = ? AND name = ? AND day >= ? AND day <= ?
        GROUP BY day ORDER BY day
        """, [
            .text(source.rawValue), .text(kind), .text(name),
            .text(formatter.string(from: from)), .text(formatter.string(from: to)),
        ]) { row in
            let day = row.text(0).flatMap { formatter.date(from: $0) }
                ?? Date(timeIntervalSince1970: 0)
            return (day, Int(row.int(1)))
        }
    }

    /// Sessions where a skill appeared most recently (all-time; kind fixed to 'skill'). Historic
    /// rows with an empty session are not counted.
    public func recentSkillSessions(
        source: AgentSource, name: String, limit: Int = 10
    ) throws -> [(sessionId: String, lastTs: Date, count: Int)] {
        try db.query("""
        SELECT session_id, MAX(last_ts), SUM(count) FROM tool_calls
        WHERE kind = 'skill' AND source = ? AND name = ? AND session_id != ''
        GROUP BY session_id ORDER BY MAX(last_ts) DESC LIMIT ?
        """, [.text(source.rawValue), .text(name), .int(Int64(limit))]) { row in
            (sessionId: row.text(0) ?? "",
             lastTs: Date(timeIntervalSince1970: row.real(1)),
             count: Int(row.int(2)))
        }
    }
}

/// Agent operation audit log (append-only fact table; full command/path text, no output bodies).
/// Audit archive ledger (audit_archive)
public final class AuditArchiveRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct Entry: Equatable, Sendable {
        public let day: String
        public let fingerprint: String
        public let rows: Int
        public let filePath: String
        public let writtenAt: Date
        public let uploadedAt: Date?
        /// Fingerprint of the file at upload time; the day counts as "fully archived" only when it
        /// equals the current DB fingerprint
        public let uploadedFingerprint: String?
    }

    public func all() throws -> [Entry] {
        try db.query("""
        SELECT day, fingerprint, rows, file_path, written_at, uploaded_at, uploaded_fingerprint
        FROM audit_archive ORDER BY day
        """) { row in
            Entry(
                day: row.text(0) ?? "", fingerprint: row.text(1) ?? "", rows: Int(row.int(2)),
                filePath: row.text(3) ?? "", writtenAt: Date(timeIntervalSince1970: row.real(4)),
                uploadedAt: row.date(5), uploadedFingerprint: row.text(6))
        }
    }

    /// Register after writing the local Parquet file (keep any existing upload record until the new
    /// file is uploaded too)
    public func recordWritten(day: String, fingerprint: String, rows: Int, filePath: String, at date: Date) throws {
        try db.run("""
        INSERT INTO audit_archive (day, fingerprint, rows, file_path, written_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(day) DO UPDATE SET
            fingerprint = excluded.fingerprint, rows = excluded.rows,
            file_path = excluded.file_path, written_at = excluded.written_at
        """, [.text(day), .text(fingerprint), .int(Int64(rows)), .text(filePath), .date(date)])
    }

    /// The day's file uploaded successfully: align the "uploaded fingerprint" with that file's
    /// fingerprint
    public func markUploaded(day: String, fingerprint: String, at date: Date) throws {
        try db.run(
            "UPDATE audit_archive SET uploaded_at = ?, uploaded_fingerprint = ? WHERE day = ? AND fingerprint = ?",
            [.date(date), .text(fingerprint), .text(day), .text(fingerprint)])
    }
}

public final class AuditRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// Filter criteria (shared by the panel and the CLI). keyword matches detail or tool.
    public struct Query: Equatable, Sendable {
        public var source: AgentSource?
        public var kind: ToolKind?
        public var riskOnly: Bool
        public var keyword: String?

        public init(
            source: AgentSource? = nil, kind: ToolKind? = nil,
            riskOnly: Bool = false, keyword: String? = nil
        ) {
            self.source = source
            self.kind = kind
            self.riskOnly = riskOnly
            self.keyword = keyword
        }
    }

    /// Idempotent insert: ignored on (source, session_id, op_id) conflict. Returns whether a row
    /// was actually inserted.
    @discardableResult
    public func insert(_ event: AuditEvent) throws -> Bool {
        try db.run("""
        INSERT OR IGNORE INTO audit_events
            (op_id, source, session_id, ts, kind, tool, detail, cwd, exit_code,
             is_error, risk_level, risk_rule)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(event.opId), .text(event.source.rawValue), .text(event.sessionId),
            .real(event.timestamp.timeIntervalSince1970),
            .text(event.kind.rawValue), .text(event.tool), .text(event.detail),
            .string(event.cwd),
            event.exitCode.map { .int(Int64($0)) } ?? .null,
            .int(event.isError ? 1 : 0),
            .int(Int64(event.riskLevel?.rawValue ?? 0)),
            .string(event.riskRule),
        ])
        return db.changes > 0
    }

    /// Back-fill the execution result (Codex function_call_output finds the matching row via
    /// call_id=op_id).
    public func markOutcome(
        source: AgentSource, sessionId: String, opId: String,
        exitCode: Int?, isError: Bool
    ) throws {
        try db.run("""
        UPDATE audit_events SET exit_code = ?, is_error = ?
        WHERE source = ? AND session_id = ? AND op_id = ?
        """, [
            exitCode.map { .int(Int64($0)) } ?? .null,
            .int(isError ? 1 : 0),
            .text(source.rawValue), .text(sessionId), .text(opId),
        ])
    }

    /// Paginated query, newest first (backed by idx_audit_ts)
    public func recent(_ query: Query = Query(), limit: Int, offset: Int = 0) throws -> [AuditEvent] {
        let (whereClause, bindings) = Self.filter(query)
        return try db.query("""
        SELECT op_id, source, session_id, ts, kind, tool, detail, cwd, exit_code,
               is_error, risk_level, risk_rule
        FROM audit_events \(whereClause)
        ORDER BY ts DESC LIMIT ? OFFSET ?
        """, bindings + [.int(Int64(limit)), .int(Int64(offset))]) { Self.mapRow($0) }
    }

    /// Row count (for the pager's "N total" label)
    public func count(_ query: Query = Query()) throws -> Int {
        let (whereClause, bindings) = Self.filter(query)
        return try db.query(
            "SELECT COUNT(*) FROM audit_events \(whereClause)", bindings
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// Grouped counts on one dimension (for the filter-bar chips and the overview card
    /// distribution).
    ///
    /// Accepts only whitelisted columns; **never splices external strings into SQL**. Precedent: `dailySeries`' GROUP BY in this file.
    /// Measured ~30ms on 25,576 real rows (`source`/`kind` are unindexed, full table scan); at the 200k-row cap of `prune(keepingLast:)`
    /// ~100–200ms — compute once on page load, **never on every keystroke**.
    public enum CountDimension: String {
        case source
        case kind
    }

    public func counts(
        by dimension: CountDimension, _ query: Query = Query()
    ) throws -> [String: Int] {
        let (whereClause, bindings) = Self.filter(query)
        let rows = try db.query("""
        SELECT \(dimension.rawValue), COUNT(*) FROM audit_events \(whereClause)
        GROUP BY \(dimension.rawValue)
        """, bindings) { row in (row.text(0) ?? "", Int(row.int(1))) }
        var result: [String: Int] = [:]
        for (key, count) in rows where !key.isEmpty { result[key] = count }
        return result
    }

    /// Retention policy: delete rows older than date
    public func prune(olderThan date: Date) throws {
        try db.run(
            "DELETE FROM audit_events WHERE ts < ?", [.real(date.timeIntervalSince1970)])
    }

    /// Fallback cap: keep only the most recent N rows (prevents unbounded growth under "keep
    /// forever")
    public func prune(keepingLast: Int) throws {
        try db.run("""
        DELETE FROM audit_events WHERE id NOT IN (
            SELECT id FROM audit_events ORDER BY ts DESC LIMIT ?
        )
        """, [.int(Int64(keepingLast))])
    }

    public func deleteAll() throws {
        try db.run("DELETE FROM audit_events")
    }

    // MARK: - Archive (by UTC day)

    /// Fingerprint of each UTC day: row count : max id : back-filled exit_code count : failure
    /// count. Covers three kinds of change — new inserts, late inserts with old timestamps (id
    /// grows), and Codex back-filling results afterwards (UPDATE).
    public struct DayFingerprint: Equatable, Sendable {
        public let day: String
        public let fingerprint: String
        public let rows: Int
    }

    public func dayFingerprints() throws -> [DayFingerprint] {
        try db.query("""
        SELECT strftime('%Y-%m-%d', ts, 'unixepoch') AS day,
               COUNT(*), MAX(id), COUNT(exit_code), SUM(is_error)
        FROM audit_events GROUP BY day ORDER BY day
        """) { row in
            DayFingerprint(
                day: row.text(0) ?? "",
                fingerprint: "\(row.int(1)):\(row.int(2)):\(row.int(3)):\(row.int(4))",
                rows: Int(row.int(1)))
        }
    }

    /// Every record of one UTC day (time ascending, id as tie-breaker for stable order)
    public func events(onDay day: String) throws -> [AuditEvent] {
        guard let (start, end) = Self.utcDayRange(day) else { return [] }
        return try db.query("""
        SELECT op_id, source, session_id, ts, kind, tool, detail, cwd, exit_code,
               is_error, risk_level, risk_rule
        FROM audit_events WHERE ts >= ? AND ts < ?
        ORDER BY ts ASC, id ASC
        """, [.real(start), .real(end)]) { Self.mapRow($0) }
    }

    /// Delete an entire UTC day (archive-linked cleanup). Deletes whole days only: deleting part
    /// changes that day's fingerprint, and the next cycle would rewrite with fewer rows and
    /// overwrite the complete remote archive
    public func deleteDay(_ day: String) throws {
        guard let (start, end) = Self.utcDayRange(day) else { return }
        try db.run(
            "DELETE FROM audit_events WHERE ts >= ? AND ts < ?", [.real(start), .real(end)])
    }

    public func totalCount() throws -> Int {
        try db.query("SELECT COUNT(*) FROM audit_events") { Int($0.int(0)) }.first ?? 0
    }

    /// "YYYY-MM-DD" (UTC) → [start, end) in Unix seconds
    static func utcDayRange(_ day: String) -> (Double, Double)? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        guard let start = formatter.date(from: day)?.timeIntervalSince1970 else { return nil }
        return (start, start + 86400)
    }

    /// Build the WHERE clause dynamically; returns the clause and its bindings
    private static func filter(_ query: Query) -> (String, [SQLiteValue]) {
        var conditions: [String] = []
        var bindings: [SQLiteValue] = []
        if let source = query.source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
        }
        if let kind = query.kind {
            conditions.append("kind = ?")
            bindings.append(.text(kind.rawValue))
        }
        if query.riskOnly {
            conditions.append("risk_level > 0")
        }
        if let keyword = query.keyword?.trimmingCharacters(in: .whitespaces), !keyword.isEmpty {
            let escaped = keyword
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            conditions.append("(detail LIKE ? ESCAPE '\\' OR tool LIKE ? ESCAPE '\\')")
            bindings.append(.text("%\(escaped)%"))
            bindings.append(.text("%\(escaped)%"))
        }
        let clause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        return (clause, bindings)
    }

    private static func mapRow(_ row: SQLiteRow) -> AuditEvent {
        AuditEvent(
            opId: row.text(0) ?? "",
            source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
            sessionId: row.text(2) ?? "",
            timestamp: Date(timeIntervalSince1970: row.real(3)),
            kind: ToolKind(rawValue: row.text(4) ?? "") ?? .other,
            tool: row.text(5) ?? "",
            detail: row.text(6) ?? "",
            cwd: row.text(7),
            exitCode: row.isNull(8) ? nil : Int(row.int(8)),
            isError: row.int(9) != 0,
            riskLevel: RiskLevel(rawValue: Int(row.int(10))),
            riskRule: row.text(11))
    }
}
