import Foundation
import EurekaKit
import EurekaStore

/// Usage summary (today / this week, local time zone, weeks start on Monday)
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
        /// Tokens of unpriced models (when > 0 the UI notes "partially unpriced")
        public var unpricedTokens: Int
        public var models: [ModelLine]

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        }
    }

    public struct ProjectLine: Equatable, Sendable {
        public var name: String
        public var totalTokens: Int
        public var costUSD: Double?

        public init(name: String, totalTokens: Int, costUSD: Double?) {
            self.name = name
            self.totalTokens = totalTokens
            self.costUSD = costUSD
        }
    }

    public var today: [SourceSummary]
    public var thisWeek: [SourceSummary]
    public var thisMonth: [SourceSummary]
    public var todayProjects: [ProjectLine]
    public var weekProjects: [ProjectLine]
    public var monthProjects: [ProjectLine]
    public var generatedAt: Date

    public init(
        today: [SourceSummary], thisWeek: [SourceSummary],
        thisMonth: [SourceSummary] = [],
        todayProjects: [ProjectLine] = [], weekProjects: [ProjectLine] = [],
        monthProjects: [ProjectLine] = [],
        generatedAt: Date
    ) {
        self.today = today
        self.thisWeek = thisWeek
        self.thisMonth = thisMonth
        self.todayProjects = todayProjects
        self.weekProjects = weekProjects
        self.monthProjects = monthProjects
        self.generatedAt = generatedAt
    }
}

public enum UsageAggregator {
    public static func dayStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// Monday is the first day of the week
    public static func weekStart(of date: Date, calendar: Calendar = .current) -> Date {
        var cal = calendar
        cal.firstWeekday = 2
        return cal.dateInterval(of: .weekOfYear, for: date)?.start
            ?? cal.startOfDay(for: date)
    }

    /// Report week `[Monday 00:00, next Monday 00:00)`, `offset` weeks back from `now`.
    /// Pins Monday regardless of the calendar's `firstWeekday` so the weekly report and the
    /// "This week" dashboard period (both Monday-based) describe the same seven days.
    public static func weekRange(
        offset: Int, now: Date = Date(), calendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        var cal = calendar
        cal.firstWeekday = 2
        let anchor = cal.date(byAdding: .weekOfYear, value: -offset, to: now) ?? now
        let start = weekStart(of: anchor, calendar: cal)
        let end = cal.date(byAdding: .weekOfYear, value: 1, to: start)
            ?? start.addingTimeInterval(7 * 86400)
        return (start, end)
    }

    /// Start of the calendar month (local time zone)
    public static func monthStart(of date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
    }

    public static func summarize(
        store: EurekaStore, pricing: PricingTable, now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> UsageSummary {
        let todayFrom = dayStart(of: now, calendar: calendar)
        let weekFrom = weekStart(of: now, calendar: calendar)
        let monthFrom = monthStart(of: now, calendar: calendar)
        return UsageSummary(
            today: fold(try store.usage.totalsByModel(from: todayFrom, to: now), pricing: pricing),
            thisWeek: fold(try store.usage.totalsByModel(from: weekFrom, to: now), pricing: pricing),
            thisMonth: fold(
                try store.usage.totalsByModel(from: monthFrom, to: now), pricing: pricing),
            todayProjects: foldProjects(
                try store.usage.totalsByProject(from: todayFrom, to: now), pricing: pricing),
            weekProjects: foldProjects(
                try store.usage.totalsByProject(from: weekFrom, to: now), pricing: pricing),
            monthProjects: foldProjects(
                try store.usage.totalsByProject(from: monthFrom, to: now), pricing: pricing),
            generatedAt: now
        )
    }

    /// Folds by project (same project merged across sources/models; cost is priced per model, then
    /// summed)
    static func foldProjects(
        _ rows: [(project: String?, totals: UsageTotals)], pricing: PricingTable
    ) -> [UsageSummary.ProjectLine] {
        var byProject: [String: UsageSummary.ProjectLine] = [:]
        for (project, totals) in rows {
            let name = project ?? L10n.text("(Unknown project)", zhHans: "（未知项目）")
            var line = byProject[name]
                ?? UsageSummary.ProjectLine(name: name, totalTokens: 0, costUSD: nil)
            line.totalTokens += totals.inputTokens + totals.outputTokens
                + totals.cacheReadTokens + totals.cacheCreationTokens
            if let cost = pricing.cost(of: totals) {
                line.costUSD = (line.costUSD ?? 0) + cost
            }
            byProject[name] = line
        }
        return byProject.values.sorted { $0.totalTokens > $1.totalTokens }
    }

    /// Folds (source, model) aggregate rows by source
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
            let cost = pricing.cost(of: row)
            if let cost {
                summary.costUSD = (summary.costUSD ?? 0) + cost
            } else {
                summary.unpricedTokens += rowTokens
            }
            // The same model may be split into several rows by provider (subscription vs
            // pay-as-you-go); display merges them by model: cost is the sum of the priced parts,
            // and nil only when all of it is unpriced
            if let index = summary.models.firstIndex(where: { $0.model == row.model }) {
                summary.models[index].totalTokens += rowTokens
                if let cost {
                    summary.models[index].costUSD = (summary.models[index].costUSD ?? 0) + cost
                }
            } else {
                summary.models.append(.init(model: row.model, totalTokens: rowTokens, costUSD: cost))
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
