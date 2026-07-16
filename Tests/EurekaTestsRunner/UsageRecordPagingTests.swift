import EurekaKit
import EurekaStore
import Foundation

func usageRecordPagingTests(_ t: TestRunner) {
    t.suite("UsageRepo · 请求日志分页")

    func makeRecord(source: AgentSource, model: String, ts: Double) -> UsageRecord {
        UsageRecord(
            source: source, model: model, project: "proj", sessionId: "s",
            timestamp: Date(timeIntervalSince1970: ts),
            inputTokens: 10, outputTokens: 5,
            cacheCreationTokens: 2, cacheCreation1hTokens: 1, cacheReadTokens: 100)
    }

    t.test("倒序分页、来源过滤、时间窗、计数") {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-paging-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        // 5 条：claude ts=100,200,300；codex ts=150,250
        try store.usage.insert([
            makeRecord(source: .claude, model: "m1", ts: 100),
            makeRecord(source: .claude, model: "m2", ts: 200),
            makeRecord(source: .claude, model: "m3", ts: 300),
            makeRecord(source: .codex, model: "g1", ts: 150),
            makeRecord(source: .codex, model: "g2", ts: 250),
        ])

        // 全量计数 + 倒序首页
        try expectEqual(try store.usage.recordCount(), 5)
        let page1 = try store.usage.recentRecords(limit: 2)
        try expectEqual(page1.map(\.model), ["m3", "g2"])
        // 第二页（offset）
        let page2 = try store.usage.recentRecords(limit: 2, offset: 2)
        try expectEqual(page2.map(\.model), ["m2", "g1"])
        // 来源过滤
        try expectEqual(try store.usage.recordCount(source: .codex), 2)
        let codexRows = try store.usage.recentRecords(source: .codex, limit: 10)
        try expectEqual(codexRows.map(\.model), ["g2", "g1"])
        // 时间窗 [150, 300)
        let windowed = try store.usage.recentRecords(
            from: Date(timeIntervalSince1970: 150),
            to: Date(timeIntervalSince1970: 300), limit: 10)
        try expectEqual(windowed.map(\.model), ["g2", "m2", "g1"])
        try expectEqual(
            try store.usage.recordCount(
                from: Date(timeIntervalSince1970: 150),
                to: Date(timeIntervalSince1970: 300)), 3)
        // 行字段完整
        let first = page1[0]
        try expectEqual(first.inputTokens, 10)
        try expectEqual(first.cacheReadTokens, 100)
        try expectEqual(first.project, "proj")
    }
}
