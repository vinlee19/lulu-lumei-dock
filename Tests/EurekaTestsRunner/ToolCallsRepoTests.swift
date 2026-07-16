import EurekaKit
import EurekaStore
import Foundation

func toolCallsRepoTests(_ t: TestRunner) {
    t.suite("ToolCallsRepo · 工具/技能/插件计数")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-toolcalls-\(UUID()).sqlite")
    }

    t.test("bump 累加 + totals 降序 + 时间窗 + 来源过滤") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        try store.toolCalls.bump(day: "2026-07-05", source: .claude, kind: "skill", name: "dataviz")
        try store.toolCalls.bump(day: "2026-07-05", source: .claude, kind: "skill", name: "dataviz")
        try store.toolCalls.bump(day: "2026-07-06", source: .claude, kind: "skill", name: "dataviz")
        try store.toolCalls.bump(day: "2026-07-06", source: .claude, kind: "tool", name: "Bash", by: 5)
        try store.toolCalls.bump(day: "2026-07-06", source: .codex, kind: "mcp", name: "notion.search")

        // 全窗聚合，count 降序：Bash(5) > dataviz(3) > notion.search(1)
        let all = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000))
        try expectEqual(all.map(\.name), ["Bash", "dataviz", "notion.search"])
        try expectEqual(all[0].count, 5)
        try expectEqual(all[1].count, 3)

        // 来源过滤
        let claudeOnly = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000), source: .claude)
        try expect(claudeOnly.allSatisfy { $0.source == .claude })
        try expectEqual(claudeOnly.count, 2)

        // 时间窗：只 2026-07-05
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        let day5 = formatter.date(from: "2026-07-05")!
        let windowed = try store.toolCalls.totals(from: day5, to: day5)
        try expectEqual(windowed.count, 1)
        try expectEqual(windowed[0].name, "dataviz")
        try expectEqual(windowed[0].count, 2)
    }

    t.test("空名/零次不写入") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(day: "2026-07-06", source: .claude, kind: "tool", name: "", by: 3)
        try store.toolCalls.bump(day: "2026-07-06", source: .claude, kind: "tool", name: "X", by: 0)
        let all = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000))
        try expect(all.isEmpty)
    }

    t.test("skillStats：次数累加 + last_ts 取 MAX + tokens 累加；dailySeries 按天") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        let t1 = 1_780_000_000.0
        let t2 = 1_780_100_000.0  // 更晚
        try store.toolCalls.bump(
            day: "2026-07-05", source: .claude, kind: "skill", name: "dataviz",
            ts: t1, tokens: 100)
        try store.toolCalls.bump(
            day: "2026-07-06", source: .claude, kind: "skill", name: "dataviz",
            ts: t2, tokens: 150)
        // 非 skill kind / 其它来源不应混入 skillStats
        try store.toolCalls.bump(
            day: "2026-07-06", source: .grok, kind: "tool", name: "dataviz", ts: t2)

        let stats = try store.toolCalls.skillStats()
        try expectEqual(stats.count, 1)  // 仅 kind='skill'
        try expectEqual(stats[0].name, "dataviz")
        try expectEqual(stats[0].count, 2)                        // 两天累加
        try expectEqual(stats[0].tokens, 250)                     // 100+150
        try expectEqual(stats[0].lastTs, Date(timeIntervalSince1970: t2))  // MAX
        let codexStats = try store.toolCalls.skillStats(source: .codex)
        try expect(codexStats.isEmpty)

        let series = try store.toolCalls.dailySeries(
            source: .claude, kind: "skill", name: "dataviz",
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000))
        try expectEqual(series.count, 2)              // 两天各一条
        try expectEqual(series.map(\.count), [1, 1])
    }
}
