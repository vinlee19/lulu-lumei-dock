import Foundation

/// 逐轮诊断指标的一行（跨会话诊断页的数据单元）。
/// 刻意只存**指标**不存图：图打开时现算（单轮 <1ms），而跨会话聚合要扫 ~2GB / 2000 个文件。
public struct TurnMetricRow: Equatable, Sendable {
    public var source: String
    public var sessionId: String
    public var turnIndex: Int
    public var promptMessageId: Int?
    public var ts: Date
    public var durationMs: Int?
    public var promptChars: Int
    public var stepCount: Int
    public var nodeCount: Int
    public var exploreNodes: Int
    public var rereadCount: Int
    public var reworkCount: Int
    public var retryMax: Int
    public var editChurn: Int
    public var errorSteps: Int
    public var subagentCount: Int
    public var askedUser: Bool
    /// 0 干净 / 1 有提示 / 2 有问题
    public var severity: Int
    /// 命中的规则 id，逗号分隔（聚合「最常犯哪类问题」用）
    public var rules: [String]

    public init(
        source: String, sessionId: String, turnIndex: Int, promptMessageId: Int? = nil,
        ts: Date, durationMs: Int? = nil, promptChars: Int = 0, stepCount: Int = 0,
        nodeCount: Int = 0, exploreNodes: Int = 0, rereadCount: Int = 0,
        reworkCount: Int = 0, retryMax: Int = 0, editChurn: Int = 0, errorSteps: Int = 0,
        subagentCount: Int = 0, askedUser: Bool = false, severity: Int = 0,
        rules: [String] = []
    ) {
        self.source = source
        self.sessionId = sessionId
        self.turnIndex = turnIndex
        self.promptMessageId = promptMessageId
        self.ts = ts
        self.durationMs = durationMs
        self.promptChars = promptChars
        self.stepCount = stepCount
        self.nodeCount = nodeCount
        self.exploreNodes = exploreNodes
        self.rereadCount = rereadCount
        self.reworkCount = reworkCount
        self.retryMax = retryMax
        self.editChurn = editChurn
        self.errorSteps = errorSteps
        self.subagentCount = subagentCount
        self.askedUser = askedUser
        self.severity = severity
        self.rules = rules
    }
}

/// 跨会话聚合结果（诊断页顶部卡与排行用）
public struct TurnMetricsAggregate: Equatable, Sendable {
    public var turnCount = 0
    public var cleanTurns = 0
    public var noticeTurns = 0
    public var badTurns = 0
    public var totalReread = 0
    public var totalRetry = 0
    public var totalRework = 0
    public var churnTurns = 0
    public var averageExploreRatio: Double = 0
    /// 规则 id → 命中轮数
    public var ruleHits: [String: Int] = [:]
    /// 来源 → 轮数
    public var bySource: [String: Int] = [:]

    public init() {}
}

/// `turn_metrics` / `turn_files` 读写。派生表：升级直接 DROP，下轮扫描自动重建。
public final class TurnMetricsRepo {
    private let db: SQLiteDB

    init(db: SQLiteDB) { self.db = db }

    // MARK: - 水位（size+mtime 指纹；轮次指标是整轮聚合，逐行 offset 拿不到轮边界）

    public func fingerprints() throws -> [String: (size: Int64, mtime: Double)] {
        var result: [String: (Int64, Double)] = [:]
        let rows = try db.query("SELECT path, size, mtime FROM turn_files") { row in
            (row.text(0) ?? "", row.int(1), row.real(2))
        }
        for (path, size, mtime) in rows where !path.isEmpty {
            result[path] = (size, mtime)
        }
        return result
    }

    /// 整文件重建：删旧行 → 插新行 → 记指纹，单事务保证一致（照 SearchRepo.replaceDocs）
    public func replace(
        path: String, size: Int64, mtime: Double, rows: [TurnMetricRow]
    ) throws {
        try db.transaction {
            try db.run("DELETE FROM turn_metrics WHERE path = ?", [.text(path)])
            for row in rows {
                try db.run("""
                INSERT OR REPLACE INTO turn_metrics (
                    path, source, session_id, turn_index, prompt_message_id, ts, duration_ms,
                    prompt_chars, step_count, node_count, explore_nodes, reread_count,
                    rework_count, retry_max, edit_churn, error_steps, subagent_count,
                    asked_user, severity, rules
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                    .text(path), .text(row.source), .text(row.sessionId),
                    .int(Int64(row.turnIndex)),
                    row.promptMessageId.map { .int(Int64($0)) } ?? .null,
                    .real(row.ts.timeIntervalSince1970),
                    row.durationMs.map { .int(Int64($0)) } ?? .null,
                    .int(Int64(row.promptChars)), .int(Int64(row.stepCount)),
                    .int(Int64(row.nodeCount)), .int(Int64(row.exploreNodes)),
                    .int(Int64(row.rereadCount)), .int(Int64(row.reworkCount)),
                    .int(Int64(row.retryMax)), .int(Int64(row.editChurn)),
                    .int(Int64(row.errorSteps)), .int(Int64(row.subagentCount)),
                    .int(row.askedUser ? 1 : 0), .int(Int64(row.severity)),
                    .text(row.rules.joined(separator: ",")),
                ])
            }
            try db.run(
                "INSERT OR REPLACE INTO turn_files (path, size, mtime) VALUES (?,?,?)",
                [.text(path), .int(size), .real(mtime)])
        }
    }

    /// 清理磁盘上已消失的文件
    public func prune(keeping existingPaths: Set<String>) throws {
        let indexed = try db.query("SELECT path FROM turn_files") { $0.text(0) ?? "" }
        for path in indexed where !existingPaths.contains(path) {
            try db.run("DELETE FROM turn_metrics WHERE path = ?", [.text(path)])
            try db.run("DELETE FROM turn_files WHERE path = ?", [.text(path)])
        }
    }

    // MARK: - 查询

    public func count() throws -> Int {
        Int(try db.query("SELECT COUNT(*) FROM turn_metrics") { $0.int(0) }.first ?? 0)
    }

    /// 区间聚合。`source` 为 nil = 全部来源。
    public func aggregate(
        from: Date, to: Date, source: String? = nil
    ) throws -> TurnMetricsAggregate {
        var clause = "WHERE ts >= ? AND ts < ?"
        var bindings: [SQLiteValue] = [
            .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
        ]
        if let source {
            clause += " AND source = ?"
            bindings.append(.text(source))
        }
        var result = TurnMetricsAggregate()
        let rows = try db.query("""
        SELECT severity, reread_count, retry_max, rework_count, edit_churn,
               node_count, explore_nodes, rules, source
        FROM turn_metrics \(clause)
        """, bindings) { row in
            (Int(row.int(0)), Int(row.int(1)), Int(row.int(2)), Int(row.int(3)),
             Int(row.int(4)), Int(row.int(5)), Int(row.int(6)),
             row.text(7) ?? "", row.text(8) ?? "")
        }
        var ratioSum = 0.0
        var ratioCount = 0
        for (severity, reread, retry, rework, churn, nodes, explore, rules, source) in rows {
            result.turnCount += 1
            switch severity {
            case 2: result.badTurns += 1
            case 1: result.noticeTurns += 1
            default: result.cleanTurns += 1
            }
            result.totalReread += reread
            result.totalRetry += retry
            result.totalRework += rework
            if churn >= 3 { result.churnTurns += 1 }
            result.bySource[source, default: 0] += 1
            for rule in rules.split(separator: ",") where !rule.isEmpty {
                result.ruleHits[String(rule), default: 0] += 1
            }
            // 探索比只统计够长的轮（短轮会把均值稀释成噪音，口径同 TurnDiagnostics）
            if nodes >= 6 {
                ratioSum += Double(explore) / Double(nodes)
                ratioCount += 1
            }
        }
        result.averageExploreRatio = ratioCount > 0 ? ratioSum / Double(ratioCount) : 0
        return result
    }

    /// 按天的「有问题轮数 / 总轮数」（趋势用；日期用本地时区）
    public func dailySeries(from: Date, to: Date, source: String? = nil) throws
        -> [(day: Date, total: Int, bad: Int)] {
        var clause = "WHERE ts >= ? AND ts < ?"
        var bindings: [SQLiteValue] = [
            .real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970),
        ]
        if let source {
            clause += " AND source = ?"
            bindings.append(.text(source))
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let rows = try db.query("""
        SELECT date(ts, 'unixepoch', 'localtime') AS day, COUNT(*),
               SUM(CASE WHEN severity = 2 THEN 1 ELSE 0 END)
        FROM turn_metrics \(clause) GROUP BY day ORDER BY day
        """, bindings) { row in
            (row.text(0) ?? "", Int(row.int(1)), Int(row.int(2)))
        }
        return rows.compactMap { day, total, bad in
            formatter.date(from: day).map { ($0, total, bad) }
        }
    }

    /// 最差的若干轮（可直接跳过去看图）
    public func worst(limit: Int = 20, source: String? = nil) throws -> [TurnMetricRow] {
        var clause = "WHERE severity > 0"
        var bindings: [SQLiteValue] = []
        if let source {
            clause += " AND source = ?"
            bindings.append(.text(source))
        }
        return try db.query("""
        SELECT source, session_id, turn_index, prompt_message_id, ts, duration_ms,
               prompt_chars, step_count, node_count, explore_nodes, reread_count,
               rework_count, retry_max, edit_churn, error_steps, subagent_count,
               asked_user, severity, rules
        FROM turn_metrics \(clause)
        ORDER BY severity DESC, (reread_count + retry_max + edit_churn) DESC, ts DESC
        LIMIT \(max(1, limit))
        """, bindings) { row in
            TurnMetricRow(
                source: row.text(0) ?? "", sessionId: row.text(1) ?? "",
                turnIndex: Int(row.int(2)),
                promptMessageId: row.isNull(3) ? nil : Int(row.int(3)),
                ts: Date(timeIntervalSince1970: row.real(4)),
                durationMs: row.isNull(5) ? nil : Int(row.int(5)),
                promptChars: Int(row.int(6)), stepCount: Int(row.int(7)),
                nodeCount: Int(row.int(8)), exploreNodes: Int(row.int(9)),
                rereadCount: Int(row.int(10)), reworkCount: Int(row.int(11)),
                retryMax: Int(row.int(12)), editChurn: Int(row.int(13)),
                errorSteps: Int(row.int(14)), subagentCount: Int(row.int(15)),
                askedUser: row.int(16) != 0, severity: Int(row.int(17)),
                rules: (row.text(18) ?? "").split(separator: ",").map(String.init))
        }
    }
}
