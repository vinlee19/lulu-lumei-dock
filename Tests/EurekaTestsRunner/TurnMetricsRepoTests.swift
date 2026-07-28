import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// turn_metrics 落库：指纹水位 + 整文件替换 + 区间聚合。
func turnMetricsRepoTests(_ t: TestRunner) {
    t.suite("TurnMetricsRepo · 逐轮指标落库")

    func tempStore() throws -> (EurekaStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-turnmetrics-\(UUID()).sqlite")
        return (try EurekaStore(path: path), path)
    }

    func row(
        _ index: Int, source: String = "claude", session: String = "s1",
        ts: Double = 1_700_000_000, severity: Int = 0, reread: Int = 0, retry: Int = 0,
        churn: Int = 0, nodes: Int = 0, explore: Int = 0, rules: [String] = []
    ) -> TurnMetricRow {
        TurnMetricRow(
            source: source, sessionId: session, turnIndex: index,
            ts: Date(timeIntervalSince1970: ts), nodeCount: nodes, exploreNodes: explore,
            rereadCount: reread, retryMax: retry, editChurn: churn,
            severity: severity, rules: rules)
    }

    t.test("整文件替换：重扫同一路径不叠加，旧轮次被清掉") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }

        try store.turnMetrics.replace(
            path: "/a.jsonl", size: 100, mtime: 1,
            rows: [row(0), row(1), row(2)])
        try expectEqual(try store.turnMetrics.count(), 3)

        // 文件变短（会话被截断/改写）→ 旧的第 3 轮必须消失，而不是留着
        try store.turnMetrics.replace(
            path: "/a.jsonl", size: 50, mtime: 2, rows: [row(0)])
        try expectEqual(try store.turnMetrics.count(), 1)

        let fingerprints = try store.turnMetrics.fingerprints()
        try expectEqual(fingerprints["/a.jsonl"]?.size, 50)
        try expectEqual(fingerprints["/a.jsonl"]?.mtime, 2)
    }

    t.test("prune：磁盘上消失的文件连指标带指纹一起清") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.turnMetrics.replace(path: "/a.jsonl", size: 1, mtime: 1, rows: [row(0)])
        try store.turnMetrics.replace(
            path: "/b.jsonl", size: 1, mtime: 1, rows: [row(0, session: "s2")])
        try expectEqual(try store.turnMetrics.count(), 2)

        try store.turnMetrics.prune(keeping: ["/a.jsonl"])
        try expectEqual(try store.turnMetrics.count(), 1)
        let remaining = try store.turnMetrics.fingerprints()
        try expect(remaining["/b.jsonl"] == nil)
    }

    t.test("区间聚合：严重度分布 / 规则命中 / 探索比只算够长的轮") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let now = Date().timeIntervalSince1970
        try store.turnMetrics.replace(path: "/a.jsonl", size: 1, mtime: 1, rows: [
            row(0, ts: now - 3600, severity: 0, nodes: 3, explore: 3),
            row(1, ts: now - 3600, severity: 1, reread: 2, nodes: 10, explore: 8,
                rules: ["reread"]),
            row(2, ts: now - 3600, severity: 2, retry: 4, churn: 6, nodes: 10, explore: 2,
                rules: ["retry", "churn"]),
            // 窗口之外，不该被统计
            row(3, ts: now - 100 * 86400, severity: 2, rules: ["retry"]),
        ])

        let aggregate = try store.turnMetrics.aggregate(
            from: Date(timeIntervalSince1970: now - 7 * 86400),
            to: Date(timeIntervalSince1970: now + 86400))
        try expectEqual(aggregate.turnCount, 3, "窗口外的轮不该进来")
        try expectEqual(aggregate.cleanTurns, 1)
        try expectEqual(aggregate.noticeTurns, 1)
        try expectEqual(aggregate.badTurns, 1)
        try expectEqual(aggregate.totalReread, 2)
        try expectEqual(aggregate.totalRetry, 4)
        try expectEqual(aggregate.churnTurns, 1)
        try expectEqual(aggregate.ruleHits["retry"], 1)
        try expectEqual(aggregate.ruleHits["churn"], 1)
        // 只有 nodes>=6 的两轮参与：(8/10 + 2/10)/2 = 0.5；3 节点那轮不该稀释它
        try expect(
            abs(aggregate.averageExploreRatio - 0.5) < 0.001,
            "实得 \(aggregate.averageExploreRatio)")
        try expectEqual(aggregate.bySource["claude"], 3)
    }

    t.test("来源过滤与 worst 排序") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let now = Date().timeIntervalSince1970
        try store.turnMetrics.replace(path: "/a.jsonl", size: 1, mtime: 1, rows: [
            row(0, source: "claude", ts: now, severity: 2, retry: 5, rules: ["retry"]),
            row(1, source: "claude", ts: now, severity: 1, reread: 1, rules: ["reread"]),
            row(2, source: "codex", session: "s2", ts: now, severity: 2, churn: 9,
                rules: ["churn"]),
        ])
        let claudeOnly = try store.turnMetrics.aggregate(
            from: Date(timeIntervalSince1970: now - 86400),
            to: Date(timeIntervalSince1970: now + 86400), source: "claude")
        try expectEqual(claudeOnly.turnCount, 2)

        // 三行 severity 分别是 2/1/2，全都 > 0 → 都该出现，且按严重度降序
        let worst = try store.turnMetrics.worst(limit: 10)
        try expectEqual(worst.count, 3)
        try expectEqual(worst[0].severity, 2)
        try expectEqual(worst.last?.severity, 1, "有提示的排在最后")
    }

    t.test("发现返回空集时绝不 prune（否则一次 IO 抖动清光整个索引）") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.turnMetrics.replace(path: "/a.jsonl", size: 1, mtime: 1, rows: [row(0)])
        try expectEqual(try store.turnMetrics.count(), 1)

        // 空会话列表：索引器必须什么都不删（真实场景里这行代码曾把 1979 行清光）
        let rebuilt = try TurnMetricsIndexer(store: store).indexOnce(sessions: [])
        try expectEqual(rebuilt, 0)
        try expectEqual(
            try store.turnMetrics.count(), 1,
            "发现为空时不能 prune —— 宁可留旧行，也不能凭一次空结果清库")
    }

    t.test("升级到 v17 时派生表被重建（回拨 user_version 重开）") {
        let (store, path) = try tempStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.turnMetrics.replace(path: "/a.jsonl", size: 1, mtime: 1, rows: [row(0)])
        try expectEqual(try store.turnMetrics.count(), 1)
        try store.db.execute("PRAGMA user_version = 16")

        let reopened = try EurekaStore(path: path)
        try expectEqual(
            try reopened.turnMetrics.count(), 0,
            "派生表升级应重建（下轮扫描自动恢复），而不是留着可能过时的行")
    }
}
