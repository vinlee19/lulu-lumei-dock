import EurekaKit
import EurekaStore
import Foundation

func mcpStoreStatsTests(_ t: TestRunner) {
    t.suite("MCPStoreStats · tool_calls 的 MCP 维度聚合")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-mcpstats-\(UUID()).sqlite")
    }

    t.test("mcpNameTotals / mcpDailyTotals：两种命名形态聚合与按天拆分") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        // Claude 形态 mcp__server__tool；codex/kimi 形态 server.tool；非 mcp 的 kind 不计入
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "mcp", name: "mcp__notion__search", ts: 100)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "mcp", name: "mcp__notion__fetch", ts: 200)
        try store.toolCalls.bump(
            day: "2026-08-02", source: .claude, kind: "mcp", name: "mcp__notion__search", ts: 300)
        try store.toolCalls.bump(
            day: "2026-08-02", source: .codex, kind: "mcp", name: "notion.search", ts: 400)
        try store.toolCalls.bump(
            day: "2026-08-02", source: .codex, kind: "skill", name: "notion.unrelated", ts: 500)

        let totals = try store.toolCalls.mcpNameTotals()
        try expectEqual(totals.count, 3, "三个原始工具名各自聚合")
        let byName = Dictionary(uniqueKeysWithValues: totals.map { ($0.name, $0.count) })
        try expectEqual(byName["mcp__notion__search"], 2)
        try expectEqual(byName["mcp__notion__fetch"], 1)
        try expectEqual(byName["notion.search"], 1)

        let daily = try store.toolCalls.mcpDailyTotals()
        try expectEqual(daily.count, 4, "按 (天, 原始名) 拆成四行")
        let byDayName = Dictionary(uniqueKeysWithValues: daily.map { ("\($0.day)/\($0.name)", $0.count) })
        try expectEqual(byDayName["2026-08-01/mcp__notion__search"], 1)
        try expectEqual(byDayName["2026-08-01/mcp__notion__fetch"], 1)
        try expectEqual(byDayName["2026-08-02/mcp__notion__search"], 1)
        try expectEqual(byDayName["2026-08-02/notion.search"], 1)
        try expect(byDayName["2026-08-02/notion.unrelated"] == nil,
            "kind != mcp 的行绝不能混进来")
    }
}
