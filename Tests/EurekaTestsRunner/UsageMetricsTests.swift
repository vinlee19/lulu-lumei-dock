import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func usageMetricsTests(_ t: TestRunner) {
    t.suite("UsageMetrics")

    let pricing = PricingTable(models: [
        ModelPrice(match: "claude-opus", inputPerM: 15, outputPerM: 75),
        ModelPrice(match: "gpt-5", inputPerM: 1.25, outputPerM: 10, cacheReadPerM: 0.125),
        ModelPrice(match: "cursor/", unknown: true, authoritative: true),
    ])

    func totals(
        _ model: String, input: Int = 0, output: Int = 0, write: Int = 0, read: Int = 0,
        requests: Int = 1, source: AgentSource = .claude, reported: Double? = nil
    ) -> UsageTotals {
        UsageTotals(
            source: source, model: model, inputTokens: input, outputTokens: output,
            cacheCreationTokens: write, cacheCreation1hTokens: 0, cacheReadTokens: read,
            requestCount: requests, reportedCostUSD: reported)
    }

    t.test("缓存命中率分母不含输出") {
        let m = UsageMetrics(
            totals: [totals("claude-opus-4", input: 100, output: 900, write: 100, read: 800)],
            pricing: pricing)
        // 800 / (100 + 100 + 800); the 900 output tokens must not dilute it
        try expect(abs(m.cacheHitRate - 0.8) < 1e-9, "got \(m.cacheHitRate)")
        try expectEqual(m.totalTokens, 1900)
    }

    t.test("无用量时命中率为 0、均值为 nil") {
        let m = UsageMetrics(totals: [], pricing: pricing)
        try expectEqual(m.cacheHitRate, 0)
        try expect(m.tokensPerRequest == nil && m.costPerRequest == nil)
        try expect(m.costUSD == nil && m.cacheSavingsUSD == nil)
    }

    t.test("缓存节省 = 读取量 ×（输入价 − 缓存读价）") {
        let m = UsageMetrics(totals: [
            // opus: read price derived as 0.1x → saves 1M × (15 − 1.5) = $13.5
            totals("claude-opus-4", read: 1_000_000),
            // gpt-5: explicit read price → saves 2M × (1.25 − 0.125) = $2.25
            totals("gpt-5-codex", read: 2_000_000, source: .codex),
        ], pricing: pricing)
        try expect(abs((m.cacheSavingsUSD ?? 0) - 15.75) < 1e-9, "got \(String(describing: m.cacheSavingsUSD))")
    }

    t.test("未定价与自报成本的行不计入缓存节省") {
        let m = UsageMetrics(totals: [
            totals("cursor/auto", read: 1_000_000, source: .cursor),
            totals("grok-4", read: 1_000_000, source: .grok, reported: 0.4),
        ], pricing: pricing)
        try expect(m.cacheSavingsUSD == nil)
        try expectEqual(m.costUSD, 0.4)
    }

    t.test("单次请求均值按请求数平摊") {
        let m = UsageMetrics(totals: [
            totals("claude-opus-4", input: 1_000_000, requests: 3),
            totals("claude-opus-4", output: 200_000, requests: 1),
        ], pricing: pricing)
        try expectEqual(m.requests, 4)
        try expectEqual(m.tokensPerRequest, 300_000)
        // 15 + 15 = $30 over 4 requests
        try expect(abs((m.costPerRequest ?? 0) - 7.5) < 1e-9)
    }

    t.suite("UsageComparison")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    calendar.firstWeekday = 2
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    t.test("今日对比昨日同一时段") {
        let range = UsageComparison.previousRange(
            from: date(2026, 10, 20), to: date(2026, 10, 20, 15), period: .day, calendar: calendar)
        try expectEqual(range?.from, date(2026, 10, 19))
        try expectEqual(range?.to, date(2026, 10, 19, 15))
    }

    t.test("本周对比上周同期") {
        let range = UsageComparison.previousRange(
            from: date(2026, 10, 19), to: date(2026, 10, 21, 9), period: .week, calendar: calendar)
        try expectEqual(range?.from, date(2026, 10, 12))
        try expectEqual(range?.to, date(2026, 10, 14, 9))
    }

    t.test("本月对比上月：上月较短时不越过本月月初") {
        // Mar 1 → Mar 31 elapsed 30 days; Feb has 28, so the window stops at Mar 1
        let range = UsageComparison.previousRange(
            from: date(2026, 3, 1), to: date(2026, 3, 31), period: .month, calendar: calendar)
        try expectEqual(range?.from, date(2026, 2, 1))
        try expectEqual(range?.to, date(2026, 3, 1))
    }

    t.test("自定义区间对比紧邻的等长区间") {
        let range = UsageComparison.previousRange(
            from: date(2026, 10, 10), to: date(2026, 10, 17), period: .span, calendar: calendar)
        try expectEqual(range?.from, date(2026, 10, 3))
        try expectEqual(range?.to, date(2026, 10, 10))
    }

    t.test("变化率：无基线返回 nil") {
        try expectEqual(UsageComparison.change(current: 150, previous: 100), 0.5)
        try expectEqual(UsageComparison.change(current: 50, previous: 100), -0.5)
        try expect(UsageComparison.change(current: 10, previous: 0) == nil)
    }
}
