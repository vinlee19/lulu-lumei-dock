import Foundation
import EurekaKit
import EurekaStore

/// 用量汇总（今日 / 本周，本地时区，周一起算）
public struct UsageSummary: Equatable, Sendable {
    public struct ModelLine: Equatable, Sendable {
        public var model: String
        public var totalTokens: Int
        public var costUSD: Double?
    }

    public struct SourceSummary: Equatable, Sendable {
        public var source: AgentSource
        public var requestCount: Int
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public var costUSD: Double?
        /// 未定价模型的 token 数（>0 时 UI 提示"部分未计价"）
        public var unpricedTokens: Int
        public var models: [ModelLine]

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        }
    }

    public var today: [SourceSummary]
    public var thisWeek: [SourceSummary]
    public var generatedAt: Date

    public init(today: [SourceSummary], thisWeek: [SourceSummary], generatedAt: Date) {
        self.today = today
        self.thisWeek = thisWeek
        self.generatedAt = generatedAt
    }
}

public enum UsageAggregator {
    public static func dayStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 周一为一周起点
    public static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)?.start
            ?? cal.startOfDay(for: date)
    }

    public static func summarize(
        store: EurekaStore, pricing: PricingTable, now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> UsageSummary {
        let todayTotals = try store.usage.totalsByModel(
            from: dayStart(of: now, calendar: calendar), to: now)
        let weekTotals = try store.usage.totalsByModel(
            from: weekStart(of: now, calendar: calendar), to: now)
        return UsageSummary(
            today: fold(todayTotals, pricing: pricing),
            thisWeek: fold(weekTotals, pricing: pricing),
            generatedAt: now
        )
    }

    /// 按来源折叠 (source, model) 聚合行
    static func fold(_ totals: [UsageTotals], pricing: PricingTable) -> [UsageSummary.SourceSummary] {
        var bySource: [AgentSource: UsageSummary.SourceSummary] = [:]
        for row in totals {
            var summary = bySource[row.source] ?? UsageSummary.SourceSummary(
                source: row.source, requestCount: 0,
                inputTokens: 0, outputTokens: 0,
                cacheReadTokens: 0, cacheWriteTokens: 0,
                costUSD: nil, unpricedTokens: 0, models: [])
            summary.requestCount += row.requestCount
            summary.inputTokens += row.inputTokens
            summary.outputTokens += row.outputTokens
            summary.cacheReadTokens += row.cacheReadTokens
            summary.cacheWriteTokens += row.cacheCreationTokens

            let rowTokens = row.inputTokens + row.outputTokens
                + row.cacheReadTokens + row.cacheCreationTokens
            if let cost = pricing.cost(of: row) {
                summary.costUSD = (summary.costUSD ?? 0) + cost
                summary.models.append(.init(model: row.model, totalTokens: rowTokens, costUSD: cost))
            } else {
                summary.unpricedTokens += rowTokens
                summary.models.append(.init(model: row.model, totalTokens: rowTokens, costUSD: nil))
            }
            bySource[row.source] = summary
        }
        return bySource.values
            .map { summary in
                var sorted = summary
                sorted.models.sort { $0.totalTokens > $1.totalTokens }
                return sorted
            }
            .sorted { $0.source.rawValue < $1.source.rawValue }
    }
}
