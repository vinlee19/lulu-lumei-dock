import Charts
import EurekaKit
import EurekaStore
import EurekaUsage
import SwiftUI

/// 使用统计仪表盘：大数字总消耗 + 请求/成本 + 四宫格分项 + 缓存命中率 +
/// 请求日志（分页）/ 模型统计 / 项目统计 三个子页签。
/// 顶层「用量」页签与 设置→使用统计 共用本组件。
struct UsageDashboardView: View {
    @ObservedObject var usageService: UsageService
    /// 会话索引：按会话排行 join 会话名 + 跳转目标解析（与"会话"页签共享实例）
    @ObservedObject var sessionBrowser: SessionBrowserService

    @State private var period: UsageService.DashboardPeriod = .today
    @State private var sourceFilter: AgentSource?  // nil = 全部
    @State private var subTab: SubTab = .log
    @State private var page = 1
    @State private var trendMode: TrendMode = .byDate
    @State private var trendMetric: TrendMetric = .tokens
    @State private var customFrom = Date().addingTimeInterval(-7 * 86400)
    @State private var customTo = Date()
    @State private var pageInput = ""

    enum SubTab: String, CaseIterable {
        case log = "请求日志"
        case models = "模型统计"
        case projects = "项目统计"
        case sessions = "按会话"
        case tools = "技能/插件"
        case weekly = "周报"

        var title: String {
            switch self {
            case .log: return L10n.text("Request log", zhHans: "请求日志")
            case .models: return L10n.text("Models", zhHans: "模型统计")
            case .projects: return L10n.text("Projects", zhHans: "项目统计")
            case .sessions: return L10n.text("By session", zhHans: "按会话")
            case .tools: return L10n.text("Skills / plugins", zhHans: "技能/插件")
            case .weekly: return L10n.text("Weekly", zhHans: "周报")
            }
        }
    }

    /// Offscreen-render / preview injection: pick the initial period and sub-tab
    /// (same convention as `PlansView(initialLayout:)`).
    init(
        usageService: UsageService, sessionBrowser: SessionBrowserService,
        initialPeriod: UsageService.DashboardPeriod = .today, initialSubTab: SubTab = .log
    ) {
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._sessionBrowser = ObservedObject(wrappedValue: sessionBrowser)
        self._period = State(initialValue: initialPeriod)
        self._subTab = State(initialValue: initialSubTab)
    }

    /// 周报周偏移：0 = 本周，1 = 上周…
    @State private var weekOffset = 0
    @State private var weeklyExportNote: String?

    private enum TrendMode: String, CaseIterable {
        case byDate = "按日期"
        case byModel = "按模型"

        var title: String {
            switch self {
            case .byDate: return L10n.text("By date", zhHans: "按日期")
            case .byModel: return L10n.text("By model", zhHans: "按模型")
            }
        }
    }

    private enum TrendMetric: String, CaseIterable {
        case tokens = "Tokens"
        case cost = "成本"

        var title: String {
            switch self {
            case .tokens: return "Tokens"
            case .cost: return L10n.text("Cost", zhHans: "成本")
            }
        }
    }

    private let pageSize = 50

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.module) {
                filterRow
                if let error = usageService.lastError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
                if usageService.summary != nil {
                    heroCard
                    metricGrid
                    cacheHitCard
                    trendCard
                    UsageHeatmapView(cells: usageService.heatmapCells)
                    subTabBar
                    switch subTab {
                    case .log: requestLog
                    case .models: modelStats
                    case .projects: projectStats
                    case .sessions: sessionStats
                    case .tools: toolStats
                    case .weekly: weeklySection
                    }
                    footerRow
                } else {
                    ProgressView(L10n.text("Scanning local sessions…", zhHans: "正在扫描本地会话…"))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                }
            }
            .padding(Theme.spacing.page)
        }
        .onAppear {
            usageService.refreshNow()
            reload()
        }
        .onChange(of: period) { _, _ in
            page = 1
            reload()
        }
        .onChange(of: sourceFilter) { _, _ in
            page = 1
            reload()
        }
        .onChange(of: customFrom) { _, _ in if period == .custom { page = 1; reload() } }
        .onChange(of: customTo) { _, _ in if period == .custom { page = 1; reload() } }
        .onChange(of: usageService.pricingRevision) { _, _ in reload() }
    }

    // MARK: - 区间与数据聚合

    /// 当前时间区间：固定档 = (startDate, now)；自定义 = (起当天零点, 止当天末)，自动纠正颠倒
    private func currentRange() -> (from: Date, to: Date) {
        if period == .custom {
            let cal = Calendar.current
            let lo = min(customFrom, customTo)
            let hi = max(customFrom, customTo)
            let from = cal.startOfDay(for: lo)
            let to = cal.date(bySettingHour: 23, minute: 59, second: 59, of: hi) ?? hi
            return (from, to)
        }
        return (period.startDate, Date())
    }

    /// 英雄卡/四宫格/命中率数据源：selected range 的 modelTotals（按 sourceFilter 过滤）
    private var filteredModelTotals: [UsageTotals] {
        usageService.modelTotals.filter { sourceFilter == nil || $0.source == sourceFilter }
    }
    private var totalInput: Int { filteredModelTotals.reduce(0) { $0 + $1.inputTokens } }
    private var totalOutput: Int { filteredModelTotals.reduce(0) { $0 + $1.outputTokens } }
    private var totalCacheWrite: Int { filteredModelTotals.reduce(0) { $0 + $1.cacheCreationTokens } }
    private var totalCacheRead: Int { filteredModelTotals.reduce(0) { $0 + $1.cacheReadTokens } }
    private var totalRequests: Int { filteredModelTotals.reduce(0) { $0 + $1.requestCount } }
    private var totalTokens: Int { totalInput + totalOutput + totalCacheWrite + totalCacheRead }
    private var totalCost: Double? {
        let costs = filteredModelTotals.compactMap { usageService.cost(of: $0) }
        return costs.isEmpty ? nil : costs.reduce(0, +)
    }
    private var cacheHitRate: Double {
        totalTokens > 0 ? Double(totalCacheRead) / Double(totalTokens) : 0
    }

    private func reload() {
        let range = currentRange()
        usageService.loadRecords(
            page: page, pageSize: pageSize, source: sourceFilter,
            from: range.from, to: range.to)
        usageService.loadModelTotals(from: range.from, to: range.to)
        usageService.loadProjectTotals(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadToolCalls(source: sourceFilter, from: range.from, to: range.to)
        usageService.loadTrend(from: range.from, to: range.to)
        usageService.loadSessionTotals(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadHeatmap(from: range.from, to: range.to, source: sourceFilter)
    }

    // MARK: - 技能/插件统计

    @State private var toolKindFilter: String?  // nil = 全部；skill/mcp/agent/command/tool

    private static let kindOrder = ["skill", "mcp", "agent", "command", "tool"]

    private static func kindMeta(_ kind: String) -> (label: String, icon: String, color: Color) {
        switch kind {
        case "skill":
            return (L10n.text("Skill", zhHans: "技能"), "wand.and.stars", .purple)
        case "mcp":
            return (L10n.text("MCP plugin", zhHans: "MCP 插件"), "puzzlepiece.extension.fill", .indigo)
        case "agent":
            return (L10n.text("Subagent", zhHans: "子代理"), "person.2.fill", .teal)
        case "command":
            return (L10n.text("Command", zhHans: "命令"), "terminal.fill", .gray)
        case "tool":
            return (L10n.text("Tool", zhHans: "工具"), "wrench.and.screwdriver.fill", .secondary)
        default:
            return (kind, "questionmark", .secondary)
        }
    }

    @ViewBuilder
    private var toolStats: some View {
        let rows = usageService.toolCallTotals
            .filter { toolKindFilter == nil || $0.kind == toolKindFilter }
        let maxCount = rows.map(\.count).max() ?? 1
        VStack(alignment: .leading, spacing: 0) {
            // kind 筛选 chips
            HStack(spacing: 4) {
                kindChip(nil, L10n.text("All", zhHans: "全部"))
                ForEach(Self.kindOrder, id: \.self) { key in
                    kindChip(key, Self.kindMeta(key).label)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()

            if rows.isEmpty {
                Text(L10n.text("No skill or plugin calls in this range", zhHans: "该时段暂无技能/插件调用记录"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(rows.prefix(50).enumerated()), id: \.offset) { _, row in
                    toolRow(row, maxCount: maxCount)
                    Divider().opacity(0.3)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    private func kindChip(_ kind: String?, _ label: String) -> some View {
        let selected = toolKindFilter == kind
        return Button {
            toolKindFilter = kind
        } label: {
            Text(label)
                .font(.system(size: 10, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(
                    selected ? Theme.brandFill(0.16) : Color.primary.opacity(0.05)))
                .foregroundStyle(selected ? Theme.brandFg : .secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toolRow(_ row: ToolCallsRepo.ToolCallTotal, maxCount: Int) -> some View {
        let meta = Self.kindMeta(row.kind)
        return HStack(spacing: 8) {
            Image(systemName: meta.icon)
                .font(.system(size: 10))
                .foregroundStyle(meta.color)
                .frame(width: 16)
            SourceBadge(source: row.source, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.system(size: 11).monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 比例条
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(LinearGradient(
                                colors: [Theme.brand.opacity(0.55), Theme.brand],
                                startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, proxy.size.width
                                * CGFloat(row.count) / CGFloat(max(1, maxCount))))
                    }
                }
                .frame(height: 4)
            }
            Text(meta.label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text("\(row.count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.brandFg)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.spacing.row)
    }

    // MARK: - 趋势图

    /// 图表分类色：来源品牌色（app 全局一致的固定 3 色分类方案）
    private func brandColor(_ source: AgentSource) -> Color { source.brandColor }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Trend", zhHans: "趋势"))
                    .font(.system(size: 12, weight: .semibold))
                if usageService.trendIsHourly && trendMode == .byDate {
                    Text(L10n.text("Hourly", zhHans: "小时粒度"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                Spacer()
                Picker("", selection: $trendMetric) {
                    ForEach(TrendMetric.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .controlSize(.mini)
                Picker("", selection: $trendMode) {
                    ForEach(TrendMode.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
                .controlSize(.mini)
            }
            Group {
                switch trendMode {
                case .byDate: byDateChart
                case .byModel: byModelChart
                }
            }
            .frame(height: 170)
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    /// 成本轴/标注格式（小额保留 4 位，避免全显示 $0.00）
    private func costLabel(_ usd: Double) -> String {
        usd >= 1 ? String(format: "$%.2f", usd) : String(format: "$%.4f", usd)
    }

    @ViewBuilder
    private var byDateChart: some View {
        let points = usageService.trend.filter {
            sourceFilter == nil || $0.source == sourceFilter
        }
        let hourly = usageService.trendIsHourly
        let range = currentRange()
        if points.isEmpty {
            emptyChart(L10n.text("No usage in this range", zhHans: "该时段暂无用量"))
        } else {
            let sources = orderedSources(points.map(\.source))
            // "All" starts at 1970: clamp the domain to the first data day, scale ticks to the span
            let axis = TrendAxis.layout(
                rangeFrom: range.from, rangeTo: range.to,
                firstBucket: points.map(\.bucket).min())
            Chart(points) { point in
                BarMark(
                    x: .value(L10n.text("Time", zhHans: "时间"), point.bucket, unit: hourly ? .hour : .day),
                    y: .value(
                        trendMetric.title,
                        trendMetric == .tokens ? Double(point.tokens) : point.costUSD))
                .foregroundStyle(by: .value(L10n.text("Source", zhHans: "来源"), point.source.displayName))
            }
            .chartForegroundStyleScale(domain: sources.map(\.displayName),
                                       range: sources.map(brandColor))
            .chartXScale(domain: axis.domain)  // fixed domain so a lone bar cannot fill the axis
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if trendMetric == .tokens, let tokens = value.as(Int.self) {
                            Text(formatTokens(tokens))
                        } else if trendMetric == .cost, let usd = value.as(Double.self) {
                            Text(costLabel(usd))
                        }
                    }
                }
            }
            .chartXAxis {
                if hourly {
                    AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                    }
                } else {
                    AxisMarks(values: .stride(by: .day, count: axis.strideDays)) { _ in
                        AxisGridLine()
                        if axis.showsYear {
                            AxisValueLabel(format: .dateTime.year(.twoDigits).month(.defaultDigits))
                        } else {
                            AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 6)
        }
    }

    @ViewBuilder
    private var byModelChart: some View {
        // 同 (来源, 模型) 的多个 provider 行先合并，再取前 8（否则同一模型占多根柱）
        let merged = Dictionary(
            grouping: usageService.modelTotals.filter { sourceFilter == nil || $0.source == sourceFilter },
            by: { "\($0.source.rawValue)\u{1}\($0.model)" }
        ).values.map { group -> (UsageTotals, cost: Double) in
            var first = group[0]
            for extra in group.dropFirst() {
                first.inputTokens += extra.inputTokens
                first.outputTokens += extra.outputTokens
                first.cacheCreationTokens += extra.cacheCreationTokens
                first.cacheCreation1hTokens += extra.cacheCreation1hTokens
                first.cacheReadTokens += extra.cacheReadTokens
                first.requestCount += extra.requestCount
            }
            return (first, group.compactMap { usageService.cost(of: $0) }.reduce(0, +))
        }
        let models = merged
            .map { totals, cost in
                (totals,
                 metricValue: trendMetric == .tokens
                    ? Double(totals.inputTokens + totals.outputTokens
                        + totals.cacheCreationTokens + totals.cacheReadTokens)
                    : cost)
            }
            .sorted { $0.metricValue > $1.metricValue }
            .prefix(8)
        if models.isEmpty || models.allSatisfy({ $0.metricValue == 0 }) {
            emptyChart(trendMetric == .tokens
                ? L10n.text("No model usage in this range", zhHans: "该时段暂无模型用量")
                : L10n.text("No priced usage in this range", zhHans: "该时段暂无可计价用量"))
        } else {
            Chart(Array(models.enumerated()), id: \.offset) { _, item in
                BarMark(
                    x: .value(trendMetric.title, item.metricValue),
                    y: .value(L10n.text("Model", zhHans: "模型"), item.0.model))
                .foregroundStyle(brandColor(item.0.source))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(trendMetric == .tokens
                        ? formatTokens(Int(item.metricValue))
                        : costLabel(item.metricValue))
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(trendMetric == .tokens
                                ? formatTokens(Int(number)) : costLabel(number))
                        }
                    }
                }
            }
        }
    }

    private func emptyChart(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 来源按固定顺序（品牌色不随数据变化重排）
    private func orderedSources(_ present: [AgentSource]) -> [AgentSource] {
        let set = Set(present)
        return AgentSource.allCases.filter { set.contains($0) }
    }

    // MARK: - 筛选行

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $period) {
                    ForEach(UsageService.DashboardPeriod.allCases, id: \.self) {
                        Text(periodTitle($0))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .controlSize(.small)

                Spacer(minLength: 8)

                // 手动刷新：增量重扫本地用量 + 重算当前区间聚合（同 onAppear）
                RefreshButton(help: L10n.text("Refresh statistics (rescan local usage)", zhHans: "刷新统计（重新扫描本地用量）")) {
                    usageService.refreshNow()
                    reload()
                }
            }

            // 来源筛选 chips：全部 + 各来源徽标；流式布局超宽自动折行，避免最小窗口宽度下被裁剪
            // （antigravity 内容为 protobuf 无法取用量；qoder 的 CN 后端 token 全零无用量，
            //   故均不入用量；grok / kimi 有真实 token 账 → 自动包含）
            FlowLayout(spacing: 8, lineSpacing: 6) {
                sourceChip(nil, label: L10n.text("All", zhHans: "全部"))
                // 没有 token 记账的源不给 chip（否则永远是空列表）：
                // antigravity 无本地 token；qoder 的 CN 后端报零；
                // trae 的会话库经 SQLCipher 加密，本地一个 token 都读不到。
                // （grok 1.0.4x 起 updates.jsonl 每轮带 usage，已入账）
                // antigravity 只在实验开关打开时有账
                ForEach(AgentSource.allCases.filter {
                    ($0 != .antigravity || AntigravityExperiment.isEnabled) && $0 != .qoder && $0 != .trae
                }, id: \.self) { source in
                    sourceChip(source, label: source.displayName)
                }
            }
            if period == .custom {
                HStack(spacing: 6) {
                    DatePicker("", selection: $customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                    Text(L10n.text("to", zhHans: "至")).font(.system(size: 10)).foregroundStyle(.secondary)
                    DatePicker("", selection: $customTo, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func sourceChip(_ source: AgentSource?, label: String) -> some View {
        let selected = sourceFilter == source
        return Button {
            sourceFilter = source
        } label: {
            HStack(spacing: 4) {
                if let source {
                    SourceBadge(source: source, size: 10)
                }
                Text(label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(
                selected ? Theme.brandFill(0.16) : Color.primary.opacity(0.05)))
            .foregroundStyle(selected ? Theme.brandFg : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 英雄卡

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.brandFill(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Tokens used (%@)", zhHans: "消耗 Tokens（%@）", periodTitle(period)))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(totalTokens.formatted(.number.grouping(.automatic)))
                        .font(.system(size: 26, weight: .bold).monospacedDigit())
                    Text("≈ \(chineseUnit(totalTokens))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
            }
            Spacer(minLength: 10)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Requests", zhHans: "总请求数"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Text("\(totalRequests)")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    }
                    Divider().frame(height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L10n.text("Total cost", zhHans: "总成本"))
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Text(totalCost.map { String(format: "$%.4f", $0) } ?? "—")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.cost)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.radius.container).fill(Theme.surfaceSecondary))
        }
        .padding(Theme.spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - 四宫格

    private var metricGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricCard(L10n.text("New input", zhHans: "新增输入"), totalInput, icon: "arrow.down.to.line", tint: .blue)
            metricCard(L10n.text("Output", zhHans: "输出"), totalOutput, icon: "arrow.up.to.line", tint: .purple)
            metricCard(L10n.text("Cache write", zhHans: "缓存创建"), totalCacheWrite, icon: "externaldrive.badge.plus", tint: .orange)
            metricCard(L10n.text("Cache read", zhHans: "缓存命中"), totalCacheRead, icon: "sparkles", tint: Theme.brandFg)
        }
    }

    private func metricCard(_ label: String, _ value: Int, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(chineseUnit(value))
                    .font(.system(size: 14, weight: .semibold).monospacedDigit())
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - 缓存命中率

    private var cacheHitCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Cache hit rate", zhHans: "缓存命中率"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", cacheHitRate * 100))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.brandFg)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(LinearGradient(
                            colors: [Theme.brand.opacity(0.6), Theme.brand],
                            startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, proxy.size.width * cacheHitRate))
                }
            }
            .frame(height: 6)
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - 子页签

    private var subTabBar: some View {
        CapsuleTabTray {
            ForEach(SubTab.allCases, id: \.self) { tab in
                CapsuleTabButton(
                    title: tab.title, fillWidth: false, isSelected: subTab == tab
                ) {
                    subTab = tab
                }
            }
            Spacer()
        }
    }

    // MARK: - 周报

    private var weeklySection: some View {
        // Monday-based, same seven days as the "本周" period above (UsageAggregator pins Monday)
        let range = UsageAggregator.weekRange(offset: weekOffset)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    weekOffset += 1
                    loadWeekly()
                } label: { Image(systemName: "chevron.left").font(.system(size: 10)) }
                .buttonStyle(.borderless)
                Text(weekOffset == 0
                    ? L10n.text("This week", zhHans: "本周")
                    : (weekOffset == 1
                        ? L10n.text("Last week", zhHans: "上周")
                        : L10n.format("%@ weeks ago", zhHans: "%@ 周前", String(weekOffset))))
                    .font(.system(size: 12, weight: .semibold))
                Text("\(range.start, format: .dateTime.month().day()) – \(range.end.addingTimeInterval(-1), format: .dateTime.month().day())")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    weekOffset = max(0, weekOffset - 1)
                    loadWeekly()
                } label: { Image(systemName: "chevron.right").font(.system(size: 10)) }
                .buttonStyle(.borderless)
                .disabled(weekOffset == 0)
                // The report is a whole-week digest with its own 按来源 breakdown; say so instead of
                // letting a highlighted source chip imply the numbers below are filtered.
                if sourceFilter != nil {
                    Text(L10n.text("The weekly report counts every source and ignores the source filter", zhHans: "周报按全部来源统计，不受来源筛选影响"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let note = weeklyExportNote {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Button(L10n.text("Export Markdown", zhHans: "导出 Markdown")) { exportWeekly() }
                    .controlSize(.small)
                    .disabled(usageService.weeklyReport?.isEmpty ?? true)
            }

            if let report = usageService.weeklyReport, !report.isEmpty {
                weeklyStats(report)
            } else {
                Text(L10n.text("No activity that week", zhHans: "该周没有活动记录"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
        .onAppear { loadWeekly() }
    }

    @ViewBuilder
    private func weeklyStats(_ report: WeeklyReport) -> some View {
        // 概览行
        HStack(spacing: 16) {
            weeklyStat(L10n.text("Active time", zhHans: "活跃时长"), L10n.format("≈%@ hours", zhHans: "≈%@ 小时", String(report.activeHours)))
            weeklyStat(L10n.text("Tokens", zhHans: "消耗"), formatTokens(report.totalTokens))
            weeklyStat(L10n.text("Cost", zhHans: "费用"), formatCost(report.totalCostUSD ?? 0), color: Theme.cost)
            let total = report.successCount + report.errorCount + report.interruptedCount
            if total > 0 {
                weeklyStat(
                    L10n.text("Tasks", zhHans: "任务"),
                    L10n.format("%@ · %@ succeeded", zhHans: "%@ 个 · 成功 %@", String(total), String(report.successCount)))
            }
            if let prompts = report.promptSection, prompts.askedCount > 0 {
                weeklyStat(L10n.text("Prompts", zhHans: "提问"), L10n.format("%@ asked", zhHans: "%@ 个", String(prompts.askedCount)))
            }
            if report.lateNightDays > 0 {
                weeklyStat(
                    L10n.text("Late-night coding", zhHans: "深夜编码"),
                    L10n.format("%@ days", zhHans: "%@ 天", String(report.lateNightDays)),
                    color: .orange)
            }
            Spacer(minLength: 0)
        }
        Divider()
        HStack(alignment: .top, spacing: 18) {
            weeklyRankColumn(L10n.text("By source", zhHans: "按来源"), report.bySource)
            weeklyRankColumn(L10n.text("Top models", zhHans: "模型 Top"), report.byModel)
            weeklyRankColumn(L10n.text("Top projects", zhHans: "项目 Top"), report.byProject)
        }
        if !report.topSessions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Most expensive sessions", zhHans: "最贵会话"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSessions) { entry in
                    HStack(spacing: 6) {
                        Text(sessionBrowser.sessionsById[entry.sessionId]?.name
                            ?? L10n.format("Session %@", zhHans: "会话 %@", String(entry.sessionId.prefix(8))))
                            .font(.system(size: 11))
                            .lineLimit(1)
                        if let project = entry.project {
                            Text(project)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 6)
                        Text(formatTokens(entry.tokens))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(formatCost(entry.costUSD ?? 0))
                            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.cost)
                    }
                }
            }
        }
        if !report.topSkills.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Top skill calls", zhHans: "技能调用 Top"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSkills, id: \.name) { skill in
                    HStack {
                        Text(skill.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.format("%@ times", zhHans: "%@ 次", String(skill.count)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let prompts = report.promptSection, !prompts.topReused.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Most reused prompts", zhHans: "提问复用 Top"))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(prompts.topReused, id: \.name) { prompt in
                    HStack {
                        Text(prompt.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.format("%@ times total", zhHans: "累计 %@ 次", String(prompt.count)))
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func weeklyStat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    private func weeklyRankColumn(_ title: String, _ entries: [WeeklyReport.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("—").font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatCost(entry.costUSD ?? 0))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Theme.cost)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func loadWeekly() {
        let range = UsageAggregator.weekRange(offset: weekOffset)
        usageService.loadWeeklyReport(weekStart: range.start, weekEnd: range.end)
    }

    private func exportWeekly() {
        guard let report = usageService.weeklyReport else { return }
        let names = sessionBrowser.sessionsById.compactMapValues(\.name)
        let md = WeeklyReportBuilder.markdown(report, sessionNames: names)
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "vibe-weekly-\(formatter.string(from: report.weekStart)).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(md.utf8).write(to: url)
            weeklyExportNote = L10n.format("Exported %@", zhHans: "已导出 %@", url.lastPathComponent)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { weeklyExportNote = nil }
        }
    }

    // MARK: - 请求日志（分页表格）

    private var requestLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头
            HStack(spacing: 8) {
                Text(L10n.text("Time", zhHans: "时间")).frame(width: 76, alignment: .leading)
                Text(L10n.text("Source", zhHans: "来源")).frame(width: 66, alignment: .leading)
                Text(L10n.text("Model", zhHans: "模型")).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Input", zhHans: "输入")).frame(width: 76, alignment: .trailing)
                Text(L10n.text("Output", zhHans: "输出")).frame(width: 56, alignment: .trailing)
                Text(L10n.text("Cost", zhHans: "成本")).frame(width: 66, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.records.isEmpty {
                Text(L10n.text("No requests in this range", zhHans: "该时段暂无请求记录"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(usageService.records) { record in
                    logRow(record)
                    Divider().opacity(0.4)
                }
            }

            paginationBar
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    private func logRow(_ record: UsageService.RecordDisplay) -> some View {
        HStack(spacing: 8) {
            Text(record.row.ts, format: .dateTime.month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 3) {
                SourceBadge(source: record.row.source, size: 9)
                Text(record.row.source.rawValue)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 66, alignment: .leading)
            Text(record.row.model)
                .font(.system(size: 10).monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatTokens(record.row.inputTokens))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                if record.row.cacheReadTokens > 0 {
                    Text("R\(formatTokens(record.row.cacheReadTokens))")
                        .font(.system(size: 8.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 76, alignment: .trailing)
            Text(formatTokens(record.row.outputTokens))
                .font(.system(size: 10.5).monospacedDigit())
                .frame(width: 56, alignment: .trailing)
            Text(record.costUSD.map { String(format: "$%.4f", $0) } ?? "—")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.cost)
                .frame(width: 66, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.spacing.row)
    }

    private var totalPages: Int {
        max(1, (usageService.recordTotal + pageSize - 1) / pageSize)
    }

    private var paginationBar: some View {
        HStack(spacing: 8) {
            Text(L10n.format("%@ total", zhHans: "共 %@ 条", String(usageService.recordTotal)))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                page = max(1, page - 1)
                reload()
            } label: {
                Image(systemName: "chevron.left").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page <= 1)
            Text("\(page) / \(totalPages)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                page = min(totalPages, page + 1)
                reload()
            } label: {
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page >= totalPages)
            // 跳页
            Text(L10n.text("Go to", zhHans: "跳至")).font(.system(size: 10)).foregroundStyle(.tertiary)
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let target = Int(pageInput.trimmingCharacters(in: .whitespaces)) {
                        page = min(max(1, target), totalPages)
                        reload()
                    }
                    pageInput = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 模型统计

    private var modelStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("Model", zhHans: "模型")).frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Requests", zhHans: "请求")).frame(width: 46, alignment: .trailing)
                Text(L10n.text("Input", zhHans: "输入")).frame(width: 62, alignment: .trailing)
                Text(L10n.text("Output", zhHans: "输出")).frame(width: 62, alignment: .trailing)
                Text(L10n.text("Cache", zhHans: "缓存")).frame(width: 62, alignment: .trailing)
                Text(L10n.text("Cost", zhHans: "成本")).frame(width: 66, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            let filtered = usageService.modelTotals.filter {
                sourceFilter == nil || $0.source == sourceFilter
            }
            if filtered.isEmpty {
                Text(L10n.text("No model usage in this range", zhHans: "该时段暂无模型用量"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, totals in
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            SourceBadge(source: totals.source, size: 9)
                            Text(totals.model)
                                .font(.system(size: 10).monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // 同名模型按 provider 分行（订阅套餐 vs 按量计费）
                            if let provider = totals.provider {
                                Text(provider)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                        Text("\(totals.requestCount)")
                            .font(.system(size: 10.5).monospacedDigit())
                            .frame(width: 46, alignment: .trailing)
                        Text(formatTokens(totals.inputTokens))
                            .font(.system(size: 10.5).monospacedDigit())
                            .frame(width: 62, alignment: .trailing)
                        Text(formatTokens(totals.outputTokens))
                            .font(.system(size: 10.5).monospacedDigit())
                            .frame(width: 62, alignment: .trailing)
                        Text(formatTokens(totals.cacheReadTokens + totals.cacheCreationTokens))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                        Text(usageService.cost(of: totals).map { String(format: "$%.4f", $0) } ?? "—")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.cost)
                            .frame(width: 66, alignment: .trailing)
                            .help(usageService.priceResolution(of: totals).summary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.spacing.row)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - 按会话统计

    @ViewBuilder
    private var sessionStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.text("Session", zhHans: "会话")).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Project", zhHans: "项目")).frame(width: 90, alignment: .leading)
                Text(L10n.text("Requests", zhHans: "请求")).frame(width: 42, alignment: .trailing)
                Text("Tokens").frame(width: 58, alignment: .trailing)
                Text(L10n.text("Cost", zhHans: "成本")).frame(width: 62, alignment: .trailing)
                Text(L10n.text("Last active", zhHans: "最近活跃")).frame(width: 64, alignment: .trailing)
                Text("").frame(width: 12)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.sessionTotals.isEmpty {
                Text(L10n.text("No session usage in this range", zhHans: "该时段暂无会话用量"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(usageService.sessionTotals) { line in
                    sessionRow(line)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
        .onAppear {
            // 会话名来自文件索引；首次进入子页签时索引可能还没建
            if sessionBrowser.sessionsById.isEmpty {
                sessionBrowser.refresh()
            }
        }
    }

    private func sessionRow(_ line: UsageService.SessionTotal) -> some View {
        let info = sessionBrowser.sessionsById[line.sessionId]
        // 索引窗之外的老会话查不到名字，回退短 id 且不可跳转
        let canJump = info != nil
        return Button {
            guard canJump else { return }
            NotificationCenter.default.post(
                name: .eurekaRevealSession, object: line.sessionId)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    SourceBadge(source: line.source, size: 9)
                    Text(info?.name ?? L10n.format("Session %@", zhHans: "会话 %@", String(line.sessionId.prefix(8))))
                        .font(.system(size: 10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                Text(line.project ?? "—")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 90, alignment: .leading)
                Text("\(line.requests)")
                    .font(.system(size: 10.5).monospacedDigit())
                    .frame(width: 42, alignment: .trailing)
                Text(formatTokens(line.tokens))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .frame(width: 58, alignment: .trailing)
                Text(line.costUSD.map { String(format: "$%.4f", $0) } ?? "—")
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.cost)
                    .frame(width: 62, alignment: .trailing)
                Text(relativeFormatter.localizedString(
                    for: line.lastActiveAt, relativeTo: Date()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .frame(width: 12)
                    .opacity(canJump ? 1 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, Theme.spacing.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(canJump
            ? L10n.text("Open this session", zhHans: "跳转到会话页签查看详情")
            : L10n.text("This session is outside the index window (usage only)", zhHans: "该会话不在索引窗口内（仅显示用量）"))
    }

    // MARK: - 项目统计

    private var projectStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usageService.projectTotals.isEmpty {
                Text(L10n.text("No project usage in this range", zhHans: "该时段暂无项目用量"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(usageService.projectTotals) { line in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.brandFg.opacity(0.7))
                        Text(line.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer()
                        Text(formatTokens(line.tokens))
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                        Text(line.costUSD.map { String(format: "$%.4f", $0) } ?? "—")
                            .font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(Theme.cost)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.spacing.row)
                    Divider().opacity(0.4)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - 底部

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button(L10n.text("Export the last 30 days as CSV", zhHans: "导出近 30 天 CSV")) { usageService.exportCSV() }
                    .controlSize(.small)
                if let message = usageService.exportMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("Cost is estimated locally from public LiteLLM / models.dev prices. Subscription plans use the API-equivalent rate, so it can differ from your bill. Hover a cost to see where the price came from. Settings → Advanced → Model prices lists unpriced models and accepts custom prices.", zhHans: "费用为本地估算（LiteLLM / models.dev 公开价格，订阅套餐按 API 等价价折算），与账单可能有出入；悬停费用可看价格来源，设置 → 高级 → 模型价格可查看未定价模型并自定义。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func periodTitle(_ period: UsageService.DashboardPeriod) -> String {
        switch period {
        case .today: return L10n.text("Today", zhHans: "今日")
        case .week: return L10n.text("This week", zhHans: "本周")
        case .month: return L10n.text("This month", zhHans: "本月")
        case .all: return L10n.text("All", zhHans: "全部")
        case .custom: return L10n.text("Custom", zhHans: "自定义")
        }
    }

    /// 中文单位（万/亿）副标签
    private func chineseUnit(_ value: Int) -> String {
        switch value {
        case ..<10_000: return "\(value)"
        case ..<100_000_000:
            return L10n.format("%@ ×10k", zhHans: "%@ 万", String(format: "%.1f", Double(value) / 10_000))
        default:
            return L10n.format("%@ ×100M", zhHans: "%@ 亿", String(format: "%.2f", Double(value) / 100_000_000))
        }
    }
}

extension Notification.Name {
    /// 用量"按会话"排行 → 切到会话页签并选中（携带 session id）。
    /// 用通知而非透传 navigation：设置页里的用量面板也能跳转。
    static let eurekaRevealSession = Notification.Name("eurekaRevealSession")
    /// 跨页直达：知识面条目（object = 文件路径 String；userInfo["kind"] = skill/memory/instruction）
    static let eurekaRevealKnowledge = Notification.Name("eurekaRevealKnowledge")
    /// 跨页直达：计划条目（object = 文件路径 String）
    static let eurekaRevealPlan = Notification.Name("eurekaRevealPlan")
    /// 跨页直达：Prompt 库条目（object = 条目 id String）
    static let eurekaRevealPrompt = Notification.Name("eurekaRevealPrompt")
    /// ⌘K 全局搜索面板开关（MainMenu 发、PopoverRootView 收）
    static let eurekaToggleCommandPalette = Notification.Name("eurekaToggleCommandPalette")
}
