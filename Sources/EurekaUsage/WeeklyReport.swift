import EurekaKit
import EurekaStore
import Foundation

/// vibe coding 周报：一周用量/花费/任务/技能的聚合快照（全部来自本地库，只读）。
public struct WeeklyReport: Equatable {
    public struct Entry: Equatable, Identifiable {
        public var id: String { name }
        public var name: String
        public var tokens: Int
        public var costUSD: Double?
    }

    public struct SessionEntry: Equatable, Identifiable {
        public var id: String { sessionId }
        public var sessionId: String
        public var project: String?
        public var tokens: Int
        public var costUSD: Double?
    }

    public var weekStart: Date
    public var weekEnd: Date
    /// 有请求的（日期, 小时）桶数 ≈ 活跃小时数
    public var activeHours: Int
    /// 深夜（23 点后或凌晨 5 点前）有活动的天数
    public var lateNightDays: Int
    public var totalTokens: Int
    public var totalCostUSD: Double?
    public var requestCount: Int
    public var bySource: [Entry]
    public var byModel: [Entry]
    public var byProject: [Entry]
    public var topSessions: [SessionEntry]
    public var successCount: Int
    public var errorCount: Int
    public var interruptedCount: Int
    public var topSkills: [(name: String, count: Int)]

    public static func == (lhs: WeeklyReport, rhs: WeeklyReport) -> Bool {
        lhs.weekStart == rhs.weekStart && lhs.weekEnd == rhs.weekEnd
            && lhs.totalTokens == rhs.totalTokens && lhs.requestCount == rhs.requestCount
    }

    public var isEmpty: Bool { requestCount == 0 && successCount + errorCount + interruptedCount == 0 }
}

public enum WeeklyReportBuilder {
    /// 聚合一周（[weekStart, weekEnd)）。查询全部走现有仓库，不写库。
    public static func build(
        store: EurekaStore, pricing: PricingTable, weekStart: Date, weekEnd: Date
    ) throws -> WeeklyReport {
        func tokens(_ totals: UsageTotals) -> Int {
            totals.inputTokens + totals.outputTokens
                + totals.cacheCreationTokens + totals.cacheReadTokens
        }

        // 按模型（同时滚出总量与按源聚合；成本逐模型算——价格表按模型前缀匹配）
        let byModelTotals = try store.usage.totalsByModel(from: weekStart, to: weekEnd)
        var totalTokens = 0
        var totalCost: Double?
        var requestCount = 0
        var sourceAgg: [String: (tokens: Int, cost: Double?)] = [:]
        var modelEntries: [WeeklyReport.Entry] = []
        for totals in byModelTotals {
            let tokenCount = tokens(totals)
            let cost = pricing.cost(of: totals)
            totalTokens += tokenCount
            requestCount += totals.requestCount
            if let cost { totalCost = (totalCost ?? 0) + cost }
            var slot = sourceAgg[totals.source.rawValue] ?? (0, nil)
            slot.tokens += tokenCount
            if let cost { slot.cost = (slot.cost ?? 0) + cost }
            sourceAgg[totals.source.rawValue] = slot
            modelEntries.append(.init(name: totals.model, tokens: tokenCount, costUSD: cost))
        }
        modelEntries.sort { ($0.costUSD ?? 0, $0.tokens) > ($1.costUSD ?? 0, $1.tokens) }

        // 按项目（totalsByProject 的 UsageTotals 逐行带模型，可直接计价）
        var projectAgg: [String: (tokens: Int, cost: Double?)] = [:]
        for (project, totals) in try store.usage.totalsByProject(from: weekStart, to: weekEnd) {
            let name = project?.isEmpty == false ? project! : "（未知项目）"
            var slot = projectAgg[name] ?? (0, nil)
            slot.tokens += tokens(totals)
            if let cost = pricing.cost(of: totals) { slot.cost = (slot.cost ?? 0) + cost }
            projectAgg[name] = slot
        }

        // 最贵会话 Top 3
        var sessionAgg: [String: WeeklyReport.SessionEntry] = [:]
        for row in try store.usage.totalsBySession(from: weekStart, to: weekEnd) {
            var entry = sessionAgg[row.sessionId] ?? .init(
                sessionId: row.sessionId, project: row.project, tokens: 0, costUSD: nil)
            entry.tokens += tokens(row.totals)
            if let cost = pricing.cost(of: row.totals) {
                entry.costUSD = (entry.costUSD ?? 0) + cost
            }
            sessionAgg[row.sessionId] = entry
        }
        let topSessions = sessionAgg.values
            .sorted { ($0.costUSD ?? 0, $0.tokens) > ($1.costUSD ?? 0, $1.tokens) }
            .prefix(3)

        // 活跃小时 / 深夜天数
        let buckets = try store.usage.activeHourBuckets(from: weekStart, to: weekEnd)
        let lateNightDays = Set(buckets.filter { $0.hour >= 23 || $0.hour < 5 }.map(\.day)).count

        // 任务结局
        let outcomes = try store.history.outcomeCounts(from: weekStart, to: weekEnd)

        // 技能榜（kind == skill）
        let skillTotals = try store.toolCalls.totals(from: weekStart, to: weekEnd)
            .filter { $0.kind == "skill" }
        var skillAgg: [String: Int] = [:]
        for total in skillTotals { skillAgg[total.name, default: 0] += total.count }
        let topSkills = skillAgg.sorted { $0.value > $1.value }.prefix(5)
            .map { (name: $0.key, count: $0.value) }

        return WeeklyReport(
            weekStart: weekStart, weekEnd: weekEnd,
            activeHours: buckets.count,
            lateNightDays: lateNightDays,
            totalTokens: totalTokens,
            totalCostUSD: totalCost,
            requestCount: requestCount,
            bySource: sourceAgg
                .map { .init(name: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
                .sorted { ($0.costUSD ?? 0, $0.tokens) > ($1.costUSD ?? 0, $1.tokens) },
            byModel: Array(modelEntries.prefix(5)),
            byProject: projectAgg
                .map { .init(name: $0.key, tokens: $0.value.tokens, costUSD: $0.value.cost) }
                .sorted { ($0.costUSD ?? 0, $0.tokens) > ($1.costUSD ?? 0, $1.tokens) }
                .prefix(5).map { $0 },
            topSessions: Array(topSessions),
            successCount: outcomes["success"] ?? 0,
            errorCount: outcomes["error"] ?? 0,
            interruptedCount: outcomes["interrupted"] ?? 0,
            topSkills: topSkills)
    }

    /// 导出 Markdown（sessionNames：sessionId → 展示名，UI 层从会话索引补充）
    public static func markdown(
        _ report: WeeklyReport, sessionNames: [String: String] = [:]
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M 月 d 日"
        func cost(_ usd: Double?) -> String {
            usd.map { String(format: "$%.2f", $0) } ?? "—"
        }
        func tokens(_ count: Int) -> String {
            switch count {
            case ..<1000: return "\(count)"
            case ..<1_000_000: return String(format: "%.1fk", Double(count) / 1000)
            default: return String(format: "%.2fM", Double(count) / 1_000_000)
            }
        }

        var lines: [String] = []
        lines.append("# vibe coding 周报（\(formatter.string(from: report.weekStart)) – "
            + "\(formatter.string(from: report.weekEnd.addingTimeInterval(-1))))")
        lines.append("")
        lines.append("- 活跃时长：约 \(report.activeHours) 小时（有请求的小时数）")
        lines.append("- 总消耗：\(tokens(report.totalTokens)) tokens · "
            + "\(report.requestCount) 次请求 · ≈\(cost(report.totalCostUSD))")
        let total = report.successCount + report.errorCount + report.interruptedCount
        if total > 0 {
            lines.append("- 任务：\(total) 个（成功 \(report.successCount) / "
                + "出错 \(report.errorCount) / 中断 \(report.interruptedCount)）")
        }
        if report.lateNightDays > 0 {
            lines.append("- 深夜编码：\(report.lateNightDays) 天（23 点后仍在跑任务）")
        }
        if !report.bySource.isEmpty {
            lines.append("")
            lines.append("## 按来源")
            for entry in report.bySource {
                lines.append("- \(entry.name)：\(tokens(entry.tokens)) tokens · ≈\(cost(entry.costUSD))")
            }
        }
        if !report.byModel.isEmpty {
            lines.append("")
            lines.append("## 模型 Top \(report.byModel.count)")
            for entry in report.byModel {
                lines.append("- \(entry.name)：\(tokens(entry.tokens)) tokens · ≈\(cost(entry.costUSD))")
            }
        }
        if !report.byProject.isEmpty {
            lines.append("")
            lines.append("## 项目 Top \(report.byProject.count)")
            for entry in report.byProject {
                lines.append("- \(entry.name)：\(tokens(entry.tokens)) tokens · ≈\(cost(entry.costUSD))")
            }
        }
        if !report.topSessions.isEmpty {
            lines.append("")
            lines.append("## 最贵会话 Top \(report.topSessions.count)")
            for entry in report.topSessions {
                let name = sessionNames[entry.sessionId] ?? "会话 \(entry.sessionId.prefix(8))"
                let project = entry.project.map { "（\($0)）" } ?? ""
                lines.append("- \(name)\(project)：\(tokens(entry.tokens)) tokens · ≈\(cost(entry.costUSD))")
            }
        }
        if !report.topSkills.isEmpty {
            lines.append("")
            lines.append("## 技能调用 Top \(report.topSkills.count)")
            for skill in report.topSkills {
                lines.append("- \(skill.name)：\(skill.count) 次")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
