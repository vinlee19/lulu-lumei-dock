import Foundation
import EurekaStore

/// Cost of a range split by token type, so the dashboard can say where the money goes (cache
/// reads are most of the tokens but rarely most of the cost).
public struct CostBreakdown: Equatable, Sendable {
    public var input = 0.0
    public var output = 0.0
    public var cacheWrite = 0.0
    public var cacheRead = 0.0
    /// Self-reported cost (Grok) that comes without a per-token split
    public var reported = 0.0

    public init() {}

    /// Sum over aggregates; unpriced ones are left out, as in `UsageMetrics.costUSD`
    public init(totals: [UsageTotals], pricing: PricingTable) {
        for t in totals {
            guard let split = pricing.costBreakdown(of: t) else { continue }
            input += split.input
            output += split.output
            cacheWrite += split.cacheWrite
            cacheRead += split.cacheRead
            reported += split.reported
        }
    }

    public var total: Double { input + output + cacheWrite + cacheRead + reported }
}

/// Month-end projection: what is spent so far, plus the trailing week's daily rate for the time
/// left. The trailing week (not the month so far) keeps the first days of a month from swinging
/// wildly.
public enum MonthForecast {
    public static func projected(
        monthToDate: Double, trailingSevenDays: Double, now: Date, calendar: Calendar = .current
    ) -> Double? {
        guard let month = calendar.dateInterval(of: .month, for: now) else { return nil }
        let remainingDays = max(0, month.end.timeIntervalSince(now)) / 86_400
        return monthToDate + trailingSevenDays / 7 * remainingDays
    }

    /// "2026-10": the key budget alerts are remembered under, so each month alerts afresh
    public static func monthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }
}

/// Monthly budget alerts: one alert per threshold per month, highest newly crossed one only
public enum BudgetAlert {
    public static let thresholds: [Double] = [0.8, 1.0]

    /// `alert` = the highest threshold newly reached (nil = nothing new, or no budget set);
    /// `alerted` = every reached threshold, so jumping straight past 100% never alerts 80% later
    public static func evaluate(
        spent: Double, budget: Double, alerted: Set<Double>
    ) -> (alert: Double?, alerted: Set<Double>) {
        guard budget > 0 else { return (nil, alerted) }
        let reached = Set(thresholds.filter { spent >= budget * $0 })
        let fresh = reached.subtracting(alerted)
        return (fresh.max(), alerted.union(reached))
    }
}

/// Subscription payback: API-equivalent cost ÷ what the plan costs per month
public enum SubscriptionPayback {
    public static func multiple(apiEquivalent: Double, planPrice: Double) -> Double? {
        planPrice > 0 ? apiEquivalent / planPrice : nil
    }
}
