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

    /// 提问节（Prompt 库）：窗口内新提的问 + 复用榜。nil = 该周无提问数据。
    public struct PromptSection: Equatable {
        public var askedCount: Int
        /// 窗口内复用过的提问（标题 + 累计次数，按次数降序）
        public var topReused: [(name: String, count: Int)]

        public init(askedCount: Int, topReused: [(name: String, count: Int)]) {
            self.askedCount = askedCount
            self.topReused = topReused
        }

        public static func == (lhs: PromptSection, rhs: PromptSection) -> Bool {
            lhs.askedCount == rhs.askedCount
                && lhs.topReused.map(\.name) == rhs.topReused.map(\.name)
                && lhs.topReused.map(\.count) == rhs.topReused.map(\.count)
        }
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
    /// 提问节（Prompt 库数据；默认 nil 兼容旧构造点）
    public var promptSection: PromptSection? = nil

    public static func == (lhs: WeeklyReport, rhs: WeeklyReport) -> Bool {
        lhs.weekStart == rhs.weekStart && lhs.weekEnd == rhs.weekEnd
            && lhs.totalTokens == rhs.totalTokens && lhs.requestCount == rhs.requestCount
    }

    public var isEmpty: Bool {
        requestCount == 0 && successCount + errorCount + interruptedCount == 0
            && (promptSection?.askedCount ?? 0) == 0
    }
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
        // 同 (来源, 模型) 可能按 provider 拆成多行，合并回一条（口径同改动前）
        var modelIndex: [String: Int] = [:]
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
            let key = "\(totals.source.rawValue)\u{1}\(totals.model)"
            if let index = modelIndex[key] {
                modelEntries[index].tokens += tokenCount
                if let cost { modelEntries[index].costUSD = (modelEntries[index].costUSD ?? 0) + cost }
            } else {
                modelIndex[key] = modelEntries.count
                modelEntries.append(.init(name: totals.model, tokens: tokenCount, costUSD: cost))
            }
        }
        modelEntries.sort { ($0.costUSD ?? 0, $0.tokens) > ($1.costUSD ?? 0, $1.tokens) }

        // 按项目（totalsByProject 的 UsageTotals 逐行带模型，可直接计价）
        var projectAgg: [String: (tokens: Int, cost: Double?)] = [:]
        for (project, totals) in try store.usage.totalsByProject(from: weekStart, to: weekEnd) {
            let name = project?.isEmpty == false ? project! : L10n.text("(Unknown project)", zhHans: "（未知项目）")
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

        // 提问节（Prompt 库）：窗口内新提的问 + 复用榜；两者皆空则整节省略
        let promptStats = try store.prompts.weeklyStats(from: weekStart, to: weekEnd)
        let promptSection: WeeklyReport.PromptSection? =
            (promptStats.askedCount > 0 || !promptStats.topReused.isEmpty)
            ? .init(
                askedCount: promptStats.askedCount,
                topReused: promptStats.topReused
                    .map { (name: $0.title, count: $0.useCount) })
            : nil

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
            topSkills: topSkills,
            promptSection: promptSection)
    }

    /// 导出 Markdown（sessionNames：sessionId → 展示名，UI 层从会话索引补充）
    public static func markdown(
        _ report: WeeklyReport, sessionNames: [String: String] = [:]
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.current.locale
        formatter.dateFormat = L10n.text("MMM d", zhHans: "M 月 d 日")
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
        lines.append(L10n.format("# vibe coding weekly report (%@ – ", zhHans: "# vibe coding 周报（%@ – ", String(formatter.string(from: report.weekStart)))
            + "\(formatter.string(from: report.weekEnd.addingTimeInterval(-1))))")
        lines.append("")
        lines.append(L10n.format("- Active time: about %@ hours (hours with requests)", zhHans: "- 活跃时长：约 %@ 小时（有请求的小时数）", String(report.activeHours)))
        lines.append(L10n.format("- Total usage: %@ tokens · ", zhHans: "- 总消耗：%@ tokens · ", String(tokens(report.totalTokens)))
            + L10n.format("%@ requests · ≈%@", zhHans: "%@ 次请求 · ≈%@", String(report.requestCount), String(cost(report.totalCostUSD))))
        let total = report.successCount + report.errorCount + report.interruptedCount
        if total > 0 {
            lines.append(L10n.format("- Tasks: %@ (success %@ / ", zhHans: "- 任务：%@ 个（成功 %@ / ", String(total), String(report.successCount))
                + L10n.format("error %@ / interrupted %@)", zhHans: "出错 %@ / 中断 %@）", String(report.errorCount), String(report.interruptedCount)))
        }
        if let prompts = report.promptSection {
            var line = L10n.format("- Prompts: %@ this week", zhHans: "- 提问：本周 %@ 个", String(prompts.askedCount))
            if !prompts.topReused.isEmpty {
                line += L10n.text("; most reused: ", zhHans: "；复用最多：") + prompts.topReused
                    .map { L10n.format("%@ (%@ times)", zhHans: "%@（%@ 次）", String($0.name), String($0.count)) }
                    .joined(separator: L10n.text(", ", zhHans: "、"))
            }
            lines.append(line)
        }
        if report.lateNightDays > 0 {
            lines.append(L10n.format("- Late-night coding: %@ days (tasks still running after 23:00)", zhHans: "- 深夜编码：%@ 天（23 点后仍在跑任务）", String(report.lateNightDays)))
        }
        if !report.bySource.isEmpty {
            lines.append("")
            lines.append(L10n.text("## By source", zhHans: "## 按来源"))
            for entry in report.bySource {
                lines.append(L10n.format("- %@: %@ tokens · ≈%@", zhHans: "- %@：%@ tokens · ≈%@", String(entry.name), String(tokens(entry.tokens)), String(cost(entry.costUSD))))
            }
        }
        if !report.byModel.isEmpty {
            lines.append("")
            lines.append(L10n.format("## Top %@ models", zhHans: "## 模型 Top %@", String(report.byModel.count)))
            for entry in report.byModel {
                lines.append(L10n.format("- %@: %@ tokens · ≈%@", zhHans: "- %@：%@ tokens · ≈%@", String(entry.name), String(tokens(entry.tokens)), String(cost(entry.costUSD))))
            }
        }
        if !report.byProject.isEmpty {
            lines.append("")
            lines.append(L10n.format("## Top %@ projects", zhHans: "## 项目 Top %@", String(report.byProject.count)))
            for entry in report.byProject {
                lines.append(L10n.format("- %@: %@ tokens · ≈%@", zhHans: "- %@：%@ tokens · ≈%@", String(entry.name), String(tokens(entry.tokens)), String(cost(entry.costUSD))))
            }
        }
        if !report.topSessions.isEmpty {
            lines.append("")
            lines.append(L10n.format("## Top %@ most expensive sessions", zhHans: "## 最贵会话 Top %@", String(report.topSessions.count)))
            for entry in report.topSessions {
                let name = sessionNames[entry.sessionId] ?? L10n.format("Session %@", zhHans: "会话 %@", String(entry.sessionId.prefix(8)))
                let project = entry.project.map { L10n.format("(%@)", zhHans: "（%@）", String($0)) } ?? ""
                lines.append(L10n.format("- %@%@: %@ tokens · ≈%@", zhHans: "- %@%@：%@ tokens · ≈%@", String(name), String(project), String(tokens(entry.tokens)), String(cost(entry.costUSD))))
            }
        }
        if !report.topSkills.isEmpty {
            lines.append("")
            lines.append(L10n.format("## Top %@ skill calls", zhHans: "## 技能调用 Top %@", String(report.topSkills.count)))
            for skill in report.topSkills {
                lines.append(L10n.format("- %@: %@ times", zhHans: "- %@：%@ 次", String(skill.name), String(skill.count)))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
