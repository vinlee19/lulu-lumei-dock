import Foundation
import EurekaKit
import EurekaStore

/// Headline metrics of one range, folded from model-granular aggregates (dashboard hero card and
/// tiles). Kept pure so the dashboard and the tests share one definition.
public struct UsageMetrics: Equatable, Sendable {
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheWriteTokens = 0
    public var cacheReadTokens = 0
    /// Rows in the ledger. One row is one API call for most sources, but one whole turn for Grok,
    /// so a cross-source sum mixes the two granularities.
    public var requests = 0
    /// nil = nothing in the range is priced
    public var costUSD: Double?
    /// nil = no priced aggregate had cache reads to save on
    public var cacheSavingsUSD: Double?

    public init() {}

    public init(totals: [UsageTotals], pricing: PricingTable) {
        for t in totals {
            inputTokens += t.inputTokens
            outputTokens += t.outputTokens
            cacheWriteTokens += t.cacheCreationTokens
            cacheReadTokens += t.cacheReadTokens
            requests += t.requestCount
            if let cost = pricing.cost(of: t) { costUSD = (costUSD ?? 0) + cost }
            if t.cacheReadTokens > 0, let saved = pricing.cacheSavings(of: t) {
                cacheSavingsUSD = (cacheSavingsUSD ?? 0) + saved
            }
        }
    }

    public var totalTokens: Int { inputTokens + outputTokens + cacheWriteTokens + cacheReadTokens }

    /// Share of prompt-side tokens served from cache: read / (input + write + read). Output is
    /// left out because it can never be a cache hit.
    public var cacheHitRate: Double {
        let prompt = inputTokens + cacheWriteTokens + cacheReadTokens
        return prompt > 0 ? Double(cacheReadTokens) / Double(prompt) : 0
    }

    public var tokensPerRequest: Double? {
        requests > 0 ? Double(totalTokens) / Double(requests) : nil
    }

    public var costPerRequest: Double? {
        guard requests > 0, let costUSD else { return nil }
        return costUSD / Double(requests)
    }
}

/// Period-over-period comparison for the dashboard: the range one period earlier covering the same
/// elapsed time, so "today so far" is compared with "yesterday up to the same hour".
public enum UsageComparison {
    public enum Period: Sendable {
        case day, week, month
        /// An arbitrary range: compare with the equally long range right before it
        case span
    }

    public static func previousRange(
        from: Date, to: Date, period: Period, calendar: Calendar = .current
    ) -> (from: Date, to: Date)? {
        let elapsed = to.timeIntervalSince(from)
        guard elapsed > 0 else { return nil }
        let component: Calendar.Component
        switch period {
        case .span:
            return (from.addingTimeInterval(-elapsed), from)
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let previousFrom = calendar.date(byAdding: component, value: -1, to: from) else {
            return nil
        }
        // A short previous month (31st vs 30 days) must not spill into the current one
        return (previousFrom, min(previousFrom.addingTimeInterval(elapsed), from))
    }

    /// Relative change (0.25 = +25%); nil when there is no baseline to compare against
    public static func change(current: Double, previous: Double) -> Double? {
        guard previous > 0 else { return nil }
        return (current - previous) / previous
    }
}
