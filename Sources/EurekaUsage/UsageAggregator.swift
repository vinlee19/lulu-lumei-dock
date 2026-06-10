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
    public var todayProjects: [ProjectLine]
    public var weekProjects: [ProjectLine]
    public var generatedAt: Date

    public init(
        today: [SourceSummary], thisWeek: [SourceSummary],
        todayProjects: [ProjectLine] = [], weekProjects: [ProjectLine] = [],
        generatedAt: Date
    ) {
        self.today = today
        self.thisWeek = thisWeek
        self.todayProjects = todayProjects
        self.weekProjects = weekProjects
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
        let todayFrom = dayStart(of: now, calendar: calendar)
        let weekFrom = weekStart(of: now, calendar: calendar)
        return UsageSummary(
            today: fold(try store.usage.totalsByModel(from: todayFrom, to: now), pricing: pricing),
            thisWeek: fold(try store.usage.totalsByModel(from: weekFrom, to: now), pricing: pricing),
            todayProjects: foldProjects(
                try store.usage.totalsByProject(from: todayFrom, to: now), pricing: pricing),
            weekProjects: foldProjects(
                try store.usage.totalsByProject(from: weekFrom, to: now), pricing: pricing),
            generatedAt: now
        )
    }

    /// 按项目折叠（同项目跨来源/模型合并；费用按各模型分别计价后求和）
    static func foldProjects(
        _ rows: [(project: String?, totals: UsageTotals)], pricing: PricingTable
    ) -> [UsageSummary.ProjectLine] {
        var byProject: [String: UsageSummary.ProjectLine] = [:]
        for (project, totals) in rows {
            let name = project ?? "（未知项目）"
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
