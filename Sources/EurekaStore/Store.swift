import Foundation
import EurekaKit

/// SQLite 持久化入口。所有方法都应在同一队列上调用（app 内用 UsageService 的队列）。
public final class EurekaStore {
    public let db: SQLiteDB
    public let history: TaskHistoryRepo
    public let usage: UsageRepo
    public let scanState: ScanStateRepo

    public init(path: URL) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try SQLiteDB(path: path.path)
        try Schema.migrate(db)
        history = TaskHistoryRepo(db: db)
        usage = UsageRepo(db: db)
        scanState = ScanStateRepo(db: db)
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
            (id, source, session_id, title, cwd, started_at, finished_at, outcome, detail)
        VALUES (?,?,?,?,?,?,?,?,?)
        """, [
            .text(task.id), .text(task.source.rawValue), .text(task.sessionId),
            .string(task.title), .string(task.cwd),
            .date(task.startedAt), .date(task.finishedAt),
            .text(task.outcome.rawValue), .string(task.detail),
        ])
    }

    public func recent(limit: Int = 50) throws -> [FinishedTask] {
        try db.query("""
        SELECT source, session_id, title, cwd, started_at, finished_at, outcome, detail
        FROM task_history ORDER BY finished_at DESC LIMIT ?
        """, [.int(Int64(limit))]) { row in
            FinishedTask(
                source: AgentSource(rawValue: row.text(0) ?? "") ?? .claude,
                sessionId: row.text(1) ?? "",
                title: row.text(2),
                cwd: row.text(3),
                startedAt: row.date(4),
                finishedAt: row.date(5) ?? Date(),
                outcome: TaskOutcome(rawValue: row.text(6) ?? "") ?? .success,
                detail: row.text(7)
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
            (source, model, project, ts, input_tokens, output_tokens,
             cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens)
        VALUES (?,?,?,?,?,?,?,?,?)
        """, [
            .text(record.source.rawValue), .text(record.model),
            .string(record.project),
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

    /// 近 N 天按日导出（CSV 用），本地时区日界
    public func dailyRows(from: Date, to: Date) throws -> [DailyUsageRow] {
        try db.query("""
        SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS day,
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
