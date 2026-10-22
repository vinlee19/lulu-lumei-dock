import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func usageBudgetTests(_ t: TestRunner) {
    t.suite("CostBreakdown")

    let pricing = PricingTable(models: [
        ModelPrice(match: "claude-opus", inputPerM: 15, outputPerM: 75),
    ])

    t.test("按 token 类型拆分，合计等于 cost(of:)") {
        let totals = UsageTotals(
            source: .claude, model: "claude-opus-4-1",
            inputTokens: 1_000_000, outputTokens: 100_000,
            cacheCreationTokens: 200_000, cacheCreation1hTokens: 50_000,
            cacheReadTokens: 500_000, requestCount: 1)
        let split = CostBreakdown(totals: [totals], pricing: pricing)
        try expect(abs(split.input - 15) < 1e-9)
        try expect(abs(split.output - 7.5) < 1e-9)
        try expect(abs(split.cacheRead - 0.75) < 1e-9)
        // 150k × 18.75/M + 50k × 30/M
        try expect(abs(split.cacheWrite - 4.3125) < 1e-9)
        try expect(abs(split.total - (pricing.cost(of: totals) ?? 0)) < 1e-9)
    }

    t.test("自报成本单列，未定价模型不计入") {
        let split = CostBreakdown(totals: [
            UsageTotals(source: .grok, model: "grok-4", inputTokens: 10, outputTokens: 10,
                        cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0,
                        requestCount: 1, reportedCostUSD: 0.3),
            UsageTotals(source: .cursor, model: "cursor/auto", inputTokens: 10, outputTokens: 10,
                        cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0,
                        requestCount: 1),
        ], pricing: pricing)
        try expectEqual(split.reported, 0.3)
        try expectEqual(split.total, 0.3)
    }

    t.suite("MonthForecast")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h))!
    }

    t.test("月底预测 = 已花费 + 近 7 天日均 × 剩余天数") {
        // Oct 21 00:00 → Nov 1 00:00 leaves 11 days; $70 over 7 days = $10/day
        let projected = MonthForecast.projected(
            monthToDate: 200, trailingSevenDays: 70, now: date(2026, 10, 21), calendar: calendar)
        try expect(abs((projected ?? 0) - 310) < 1e-9, "got \(String(describing: projected))")
    }

    t.test("月末最后一刻预测等于已花费；月份键两位补零") {
        let last = MonthForecast.projected(
            monthToDate: 99, trailingSevenDays: 70,
            now: date(2026, 11, 1).addingTimeInterval(-0.001), calendar: calendar)
        try expect(abs((last ?? 0) - 99) < 0.01)
        try expectEqual(MonthForecast.monthKey(date(2026, 3, 5), calendar: calendar), "2026-03")
    }

    t.suite("BudgetAlert")

    t.test("越过 80% 提醒一次，之后不重复") {
        let first = BudgetAlert.evaluate(spent: 85, budget: 100, alerted: [])
        try expectEqual(first.alert, 0.8)
        let again = BudgetAlert.evaluate(spent: 90, budget: 100, alerted: first.alerted)
        try expect(again.alert == nil)
        let over = BudgetAlert.evaluate(spent: 101, budget: 100, alerted: again.alerted)
        try expectEqual(over.alert, 1.0)
    }

    t.test("一次跳过 100% 只提醒 100%，之后也不补发 80%") {
        let jump = BudgetAlert.evaluate(spent: 150, budget: 100, alerted: [])
        try expectEqual(jump.alert, 1.0)
        try expectEqual(jump.alerted, [0.8, 1.0])
        try expect(BudgetAlert.evaluate(spent: 160, budget: 100, alerted: jump.alerted).alert == nil)
    }

    t.test("未设预算不提醒；回本倍数") {
        try expect(BudgetAlert.evaluate(spent: 999, budget: 0, alerted: []).alert == nil)
        try expectEqual(SubscriptionPayback.multiple(apiEquivalent: 1400, planPrice: 200), 7)
        try expect(SubscriptionPayback.multiple(apiEquivalent: 10, planPrice: 0) == nil)
    }
}
