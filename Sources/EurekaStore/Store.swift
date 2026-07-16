import Foundation
import EurekaKit

/// SQLite 持久化入口。所有方法都应在同一队列上调用（app 内用 UsageService 的队列）。
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
    }

    /// 默认 ~/Library/Application Support/Eureka/eureka.sqlite（EUREKA_DB_PATH 覆盖）
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

    public func recent(limit: Int = 50) throws -> [FinishedTask] {
        try db.query("""
        SELECT source, session_id, title, cwd, started_at, session_started_at,
               finished_at, outcome, detail
        FROM task_history ORDER BY finished_at DESC LIMIT ?
        """, [.int(Int64(limit))]) { row in
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

    /// 插入并返回 rowid（去重键回填 output 用）
    public func insertReturningId(_ record: UsageRecord) throws -> Int64 {
        try db.run("""
        INSERT INTO usage_records
            (source, model, project, session_id, ts, input_tokens, output_tokens,
             cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, [
            .text(record.source.rawValue), .text(record.model),
            .string(record.project),
            .string(record.sessionId),
            .real(record.timestamp.timeIntervalSince1970),
            .int(Int64(record.inputTokens)), .int(Int64(record.outputTokens)),
            .int(Int64(record.cacheCreationTokens)),
            .int(Int64(record.cacheCreation1hTokens)),
            .int(Int64(record.cacheReadTokens)),
        ])
        return db.lastInsertRowID
    }

    /// 流式重复行的 output 递增：用更大的最终值覆盖
    public func updateOutputTokens(recordId: Int64, outputTokens: Int) throws {
        try db.run(
            "UPDATE usage_records SET output_tokens = ? WHERE id = ?",
            [.int(Int64(outputTokens)), .int(recordId)])
    }

    /// 时间区间内按 (project, source, model) 聚合（按项目统计/费用折算用）
    public func totalsByProject(from: Date, to: Date) throws -> [(project: String?, totals: UsageTotals)] {
        try db.query("""
        SELECT project, source, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY project, source, model
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
            (row.text(0), UsageTotals(
                source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                model: row.text(2) ?? "?",
                inputTokens: Int(row.int(3)),
                outputTokens: Int(row.int(4)),
                cacheCreationTokens: Int(row.int(5)),
                cacheCreation1hTokens: Int(row.int(6)),
                cacheReadTokens: Int(row.int(7)),
                requestCount: Int(row.int(8))
            ))
        }
    }

    /// 给定会话集合的逐会话×模型聚合（会话级费用展示）
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
                   SUM(cache_read_tokens), COUNT(*)
            FROM usage_records
            WHERE session_id IN (\(placeholders))
            GROUP BY session_id, source, model
            """, chunk.map { .text($0) }) { row -> (String, UsageTotals) in
                (row.text(0) ?? "", UsageTotals(
                    source: AgentSource(rawValue: row.text(1) ?? "") ?? .claude,
                    model: row.text(2) ?? "?",
                    inputTokens: Int(row.int(3)),
                    outputTokens: Int(row.int(4)),
                    cacheCreationTokens: Int(row.int(5)),
                    cacheCreation1hTokens: Int(row.int(6)),
                    cacheReadTokens: Int(row.int(7)),
                    requestCount: Int(row.int(8))
                ))
            }
            for (sessionId, totals) in rows {
                result[sessionId, default: []].append(totals)
            }
        }
        return result
    }

    /// 趋势/导出的时间桶粒度
    public enum TrendGranularity: String, Sendable {
        case day   // yyyy-MM-dd
        case hour  // yyyy-MM-dd HH:00（短区间趋势用）

        var bucketExpr: String {
            switch self {
            case .day: return "strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime')"
            case .hour: return "strftime('%Y-%m-%d %H:00', ts, 'unixepoch', 'localtime')"
            }
        }
    }

    /// 按日/小时导出聚合（CSV / 趋势图用），本地时区界
    public func dailyRows(
        from: Date, to: Date, granularity: TrendGranularity = .day
    ) throws -> [DailyUsageRow] {
        try db.query("""
        SELECT \(granularity.bucketExpr) AS day,
               source, model, COALESCE(project, ''),
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY day, source, model, project
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
                    requestCount: Int(row.int(9))
                )
            )
        }
    }

    /// 原始用量记录行（请求日志分页用）
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
    }

    /// 请求日志：按时间倒序分页取原始记录（idx_usage_ts 支撑）
    public func recentRecords(
        from: Date? = nil, to: Date? = nil, source: AgentSource? = nil,
        limit: Int, offset: Int = 0
    ) throws -> [UsageRecordRow] {
        let (whereClause, bindings) = Self.recordFilter(from: from, to: to, source: source)
        return try db.query("""
        SELECT source, model, project, ts, input_tokens, output_tokens,
               cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens
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
                cacheReadTokens: Int(row.int(8)))
        }
    }

    /// 请求日志总条数（分页「共 N 条」用）
    public func recordCount(
        from: Date? = nil, to: Date? = nil, source: AgentSource? = nil
    ) throws -> Int {
        let (whereClause, bindings) = Self.recordFilter(from: from, to: to, source: source)
        return try db.query(
            "SELECT COUNT(*) FROM usage_records \(whereClause)", bindings
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// 动态拼 WHERE（ts >= / ts < / source =），返回子句与绑定
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

    /// (会话 × 来源 × 模型) 聚合行（按会话用量排行用；model 维度保留供价目表算钱）
    public struct SessionUsageRow: Equatable, Sendable {
        public var sessionId: String
        public var project: String?
        public var lastTs: Date  // 该会话在区间内最近一条记录
        public var totals: UsageTotals
    }

    /// 时间区间内按会话聚合（排除无 session_id 的记录）；排序/limit 由调用方在算完成本后做
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
               SUM(cache_read_tokens), COUNT(*)
        FROM usage_records
        WHERE \(conditions.joined(separator: " AND "))
        GROUP BY session_id, source, model
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
                    requestCount: Int(row.int(10))
                ))
        }
    }

    /// 活跃时段热力格（weekday 用 SQLite %w 语义：0=周日 … 6=周六，本地时区）
    public struct HeatmapCell: Equatable, Sendable {
        public var weekday: Int  // 0-6（0=周日）
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

    /// 周 × 24 小时聚合（一次 SQL 聚合完，最多 168 行）
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

    /// 时间区间内按 (source, model) 聚合
    public func totalsByModel(from: Date, to: Date) throws -> [UsageTotals] {
        try db.query("""
        SELECT source, model,
               SUM(input_tokens), SUM(output_tokens),
               SUM(cache_creation_tokens), SUM(cache_creation_1h_tokens),
               SUM(cache_read_tokens), COUNT(*)
        FROM usage_records
        WHERE ts >= ? AND ts < ?
        GROUP BY source, model
        """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
            UsageTotals(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                model: row.text(1) ?? "?",
                inputTokens: Int(row.int(2)),
                outputTokens: Int(row.int(3)),
                cacheCreationTokens: Int(row.int(4)),
                cacheCreation1hTokens: Int(row.int(5)),
                cacheReadTokens: Int(row.int(6)),
                requestCount: Int(row.int(7))
            )
        }
    }
}

/// CSV 导出行（按日 × 来源 × 模型 × 项目）
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

/// (source, model) 聚合结果
public struct UsageTotals: Equatable, Sendable {
    public var source: AgentSource
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheCreationTokens: Int
    public var cacheCreation1hTokens: Int
    public var cacheReadTokens: Int
    public var requestCount: Int

    public init(
        source: AgentSource, model: String,
        inputTokens: Int, outputTokens: Int,
        cacheCreationTokens: Int, cacheCreation1hTokens: Int,
        cacheReadTokens: Int, requestCount: Int
    ) {
        self.source = source
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.requestCount = requestCount
    }
}

/// 每会话对话数（用量扫描器顺路计数）
public final class SessionStatsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// reset=true（全量重扫该文件）时覆盖，否则累加
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

    /// 给定会话集合的对话数
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

    /// 返回 keys 中已存在的键 → (记录 id, 已记 output)
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

    /// 8 天窗口剪枝（resume/fork 复制的都是近期行，老键无碰撞风险）
    public func pruneDedupKeys(before: Date) throws {
        try db.run(
            "DELETE FROM dedup_keys WHERE ts < ?",
            [.real(before.timeIntervalSince1970)])
    }

    public func transaction(_ body: () throws -> Void) throws {
        try db.transaction(body)
    }
}

/// 云端备份状态：path → 最近一次成功上传时的本地指纹（增量同步的 diff 基准）
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

        public init(
            path: String, remoteKey: String, size: Int64, mtime: Double,
            etag: String? = nil, uploadedAt: Date
        ) {
            self.path = path
            self.remoteKey = remoteKey
            self.size = size
            self.mtime = mtime
            self.etag = etag
            self.uploadedAt = uploadedAt
        }
    }

    public func entry(path: String) throws -> Entry? {
        try db.query("""
        SELECT path, remote_key, size, mtime, etag, uploaded_at
        FROM sync_state WHERE path = ?
        """, [.text(path)]) { Self.mapRow($0) }.first
    }

    /// 全量加载做 diff（条目数千级，一次 SELECT 可接受）
    public func allEntries() throws -> [String: Entry] {
        var result: [String: Entry] = [:]
        let rows = try db.query("""
        SELECT path, remote_key, size, mtime, etag, uploaded_at FROM sync_state
        """) { Self.mapRow($0) }
        for entry in rows {
            result[entry.path] = entry
        }
        return result
    }

    public func upsert(_ entry: Entry) throws {
        try db.run("""
        INSERT OR REPLACE INTO sync_state (path, remote_key, size, mtime, etag, uploaded_at)
        VALUES (?,?,?,?,?,?)
        """, [
            .text(entry.path), .text(entry.remoteKey),
            .int(entry.size), .real(entry.mtime),
            .string(entry.etag), .real(entry.uploadedAt.timeIntervalSince1970),
        ])
    }

    /// 备份总量统计（「备份」页签展示用）
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

    /// 本地已消失的文件清状态（远端不删，上传-only）
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
            uploadedAt: Date(timeIntervalSince1970: row.real(5)))
    }
}

/// 云端备份轮次历史：每轮汇总 + 文件明细（分页展示 + 文件名/数据量）
public final class SyncRunsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    public struct RunFile: Equatable, Sendable {
        public var name: String
        public var size: Int64
        public init(name: String, size: Int64) {
            self.name = name
            self.size = size
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

    /// 倒序分页
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

    /// 只保留最近 N 轮
    public func prune(keepingLast: Int) throws {
        try db.run("""
        DELETE FROM sync_runs WHERE id NOT IN (
            SELECT id FROM sync_runs ORDER BY ts DESC LIMIT ?
        )
        """, [.int(Int64(keepingLast))])
    }

    // MARK: - files JSON（key n=名 / s=字节）

    static func encodeFiles(_ files: [RunFile]) -> String? {
        guard !files.isEmpty else { return nil }
        let array = files.map { ["n": $0.name, "s": $0.size] as [String: Any] }
        guard let data = try? JSONSerialization.data(withJSONObject: array) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeFiles(_ json: String?) -> [RunFile] {
        guard let json, let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return array.compactMap { item in
            guard let name = item["n"] as? String else { return nil }
            let size = (item["s"] as? NSNumber)?.int64Value ?? 0
            return RunFile(name: name, size: size)
        }
    }
}

/// 工具/技能/插件/子代理调用计数（按 日×来源×kind×name 聚合，用量扫描器顺路计数）
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

    /// 全时累计的技能调用统计（供 Skills 分析视图：累计次数 / 最近活跃 / 触发时 token）
    public struct SkillUsageStat: Equatable, Sendable, Identifiable {
        public var source: AgentSource
        public var name: String
        public var count: Int
        public var lastTs: Date?
        public var tokens: Int
        public var id: String { "\(source.rawValue):\(name)" }
    }

    /// 累加计数（同 日/来源/kind/name 合并）；last_ts 取较大值、tokens 累加。
    /// ts=触发时刻（unix epoch）；tokens=触发时 token（仅 Claude 技能传真实值，其余传 0）。
    public func bump(
        day: String, source: AgentSource, kind: String, name: String,
        by count: Int = 1, ts: Double = 0, tokens: Int = 0
    ) throws {
        guard count > 0, !name.isEmpty else { return }
        try db.run("""
        INSERT INTO tool_calls (day, source, kind, name, count, last_ts, tokens)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(day, source, kind, name) DO UPDATE SET
            count = count + excluded.count,
            last_ts = MAX(last_ts, excluded.last_ts),
            tokens = tokens + excluded.tokens
        """, [
            .text(day), .text(source.rawValue), .text(kind), .text(name),
            .int(Int64(count)), .real(ts), .int(Int64(tokens)),
        ])
    }

    /// 时间区间内按 (source, kind, name) 聚合，count 降序
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

    /// 全时累计技能统计（kind='skill'），按累计次数降序。不带日期窗——用于"累计次数/最近活跃"。
    public func skillStats(source: AgentSource? = nil) throws -> [SkillUsageStat] {
        var conditions = ["kind = 'skill'"]
        var bindings: [SQLiteValue] = []
        if let source {
            conditions.append("source = ?")
            bindings.append(.text(source.rawValue))
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

    /// 某项（source×kind×name）按天调用次数序列（详情页趋势图；day 已是主键前缀，零 schema 改动）。
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
}

/// agent 操作审计流水（append-only 事实表；命令/路径全文，无输出正文）。
public final class AuditRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) {
        self.db = db
    }

    /// 筛选条件（面板/CLI 共用）。keyword 命中 detail 或 tool。
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

    /// 幂等插入：(source, session_id, op_id) 冲突则忽略。返回是否真的新插入。
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

    /// 回填执行结果（Codex function_call_output 用 call_id=op_id 找到对应行）。
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

    /// 倒序分页查询（idx_audit_ts 支撑）
    public func recent(_ query: Query = Query(), limit: Int, offset: Int = 0) throws -> [AuditEvent] {
        let (whereClause, bindings) = Self.filter(query)
        return try db.query("""
        SELECT op_id, source, session_id, ts, kind, tool, detail, cwd, exit_code,
               is_error, risk_level, risk_rule
        FROM audit_events \(whereClause)
        ORDER BY ts DESC LIMIT ? OFFSET ?
        """, bindings + [.int(Int64(limit)), .int(Int64(offset))]) { Self.mapRow($0) }
    }

    /// 条数（分页「共 N 条」用）
    public func count(_ query: Query = Query()) throws -> Int {
        let (whereClause, bindings) = Self.filter(query)
        return try db.query(
            "SELECT COUNT(*) FROM audit_events \(whereClause)", bindings
        ) { Int($0.int(0)) }.first ?? 0
    }

    /// 保留策略：删早于 date 的行
    public func prune(olderThan date: Date) throws {
        try db.run(
            "DELETE FROM audit_events WHERE ts < ?", [.real(date.timeIntervalSince1970)])
    }

    /// 兜底上限：只保留最近 N 行（防「永久保留」下无限膨胀）
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

    /// 动态拼 WHERE，返回子句与绑定
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
