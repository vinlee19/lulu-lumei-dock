import Charts
import EurekaKit
import EurekaStore
import EurekaUsage
import SwiftUI

/// Usage stats dashboard: big total-consumption number + requests/cost + four-tile breakdown +
/// cache hit rate + three sub-tabs: request log (paged) / model stats / project stats. Shared by
/// the top-level Usage tab and Settings → Usage stats.
struct UsageDashboardView: View {
    @ObservedObject var usageService: UsageService
    /// Session index: joins session names into the per-session ranking + resolves jump targets
    /// (instance shared with the Sessions tab)
    @ObservedObject var sessionBrowser: SessionBrowserService
    /// Monthly budget and subscription prices (month card)
    @ObservedObject var settings: AppSettings

    @State private var period: UsageService.DashboardPeriod = .today
    @State private var sourceFilter: AgentSource?  // nil = all
    @State private var subTab: SubTab = .overview
    @State private var page = 1
    @State private var trendMode: TrendMode = .byDate
    @State private var trendMetric: TrendMetric = .tokens
    @State private var customFrom = Date().addingTimeInterval(-7 * 86400)
    @State private var customTo = Date()
    @State private var pageInput = ""

    enum SubTab: String, CaseIterable {
        case overview = "概览"
        case log = "请求日志"
        case models = "模型统计"
        case projects = "项目统计"
        case sessions = "按会话"
        case tools = "技能/插件"
        case weekly = "周报"

        var title: String {
            switch self {
            case .overview: return L10n.text("Overview", zhHans: "概览")
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
        usageService: UsageService, sessionBrowser: SessionBrowserService, settings: AppSettings,
        initialPeriod: UsageService.DashboardPeriod = .today, initialSubTab: SubTab = .overview
    ) {
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._sessionBrowser = ObservedObject(wrappedValue: sessionBrowser)
        self._settings = ObservedObject(wrappedValue: settings)
        self._period = State(initialValue: initialPeriod)
        self._subTab = State(initialValue: initialSubTab)
    }

    /// Weekly report week offset: 0 = this week, 1 = last week...
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
        case requests = "请求"
        case cost = "成本"

        var title: String {
            switch self {
            case .tokens: return "Tokens"
            case .requests: return L10n.text("Requests", zhHans: "请求")
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
                        .font(Theme.font.themed(11))
                        .foregroundStyle(.red)
                }
                if usageService.summary != nil {
                    // Tabs sit right under the shared filters so a detail table is one click
                    // away; the charts live on Overview instead of above every table, and the
                    // headline total stays on top of each tab for context.
                    subTabBar
                    heroCard
                    switch subTab {
                    case .overview:
                        UsageMonthCard(usageService: usageService, settings: settings)
                        metricGrid
                        costStructureCard
                        cacheHitCard
                        HStack(alignment: .top, spacing: 10) {
                            turnCard
                            concentrationCard
                        }
                        trendCard
                        UsageHeatmapView(cells: usageService.heatmapCells)
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
        // New data landed (the first-install backfill publishes interim summaries; later passes
        // every 60s): reads run on their own connection, so refreshing the page is cheap
        .onChange(of: usageService.summary?.generatedAt) { _, _ in reload() }
    }

    // MARK: - Range and data aggregation

    /// Current time range: fixed periods = (startDate, now); custom = (start day's midnight, end
    /// day's end), auto-correcting reversed bounds
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

    /// Data source for the hero card/four tiles/hit rate: modelTotals of the selected range
    /// (filtered by sourceFilter)
    private var filteredModelTotals: [UsageTotals] {
        usageService.modelTotals.filter { sourceFilter == nil || $0.source == sourceFilter }
    }
    private var metrics: UsageMetrics { usageService.metrics(of: filteredModelTotals) }
    /// Same metrics over the comparison range; nil = no comparison for this period
    private var previousMetrics: UsageMetrics? {
        usageService.comparisonTotals.map { totals in
            usageService.metrics(of: totals.filter { sourceFilter == nil || $0.source == sourceFilter })
        }
    }

    /// Comparison range for the hero card deltas: one period earlier over the same elapsed time
    private func comparisonRange(_ range: (from: Date, to: Date)) -> (from: Date, to: Date)? {
        let kind: UsageComparison.Period
        switch period {
        case .today: kind = .day
        case .week: kind = .week
        case .month: kind = .month
        case .custom: kind = .span
        case .all: return nil
        }
        return UsageComparison.previousRange(from: range.from, to: range.to, period: kind)
    }

    private func reload() {
        let range = currentRange()
        usageService.loadRecords(
            page: page, pageSize: pageSize, source: sourceFilter,
            from: range.from, to: range.to)
        usageService.loadModelTotals(from: range.from, to: range.to)
        let previous = comparisonRange(range)
        usageService.loadComparisonTotals(from: previous?.from, to: previous?.to)
        usageService.loadProjectTotals(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadToolCalls(source: sourceFilter, from: range.from, to: range.to)
        usageService.loadTrend(from: range.from, to: range.to)
        usageService.loadSessionTotals(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadHeatmap(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadTurnSummary(from: range.from, to: range.to, source: sourceFilter)
    }

    // MARK: - Skill/plugin stats

    @State private var toolKindFilter: String?  // nil = all; skill/mcp/agent/command/tool

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
            // kind filter chips
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
                    .font(Theme.font.themed(11))
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
        .dashboardCard()
    }

    private func kindChip(_ kind: String?, _ label: String) -> some View {
        CompactFilterChip(label: label, verticalPadding: 3, isSelected: toolKindFilter == kind) {
            toolKindFilter = kind
        }
    }

    private func toolRow(_ row: ToolCallsRepo.ToolCallTotal, maxCount: Int) -> some View {
        let meta = Self.kindMeta(row.kind)
        return HStack(spacing: 8) {
            Image(systemName: meta.icon)
                .font(Theme.font.themed(10))
                .foregroundStyle(meta.color)
                .frame(width: 16)
            SourceBadge(source: row.source, size: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(Theme.font.monoSkillName(11, weight: .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Proportion bar
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.06))
                        Capsule()
                            .fill(Theme.barFill(Theme.brand, from: 0.55))
                            .frame(width: max(3, proxy.size.width
                                * CGFloat(row.count) / CGFloat(max(1, maxCount))))
                    }
                }
                .frame(height: 4)
            }
            Text(meta.label)
                .font(Theme.font.themed(9))
                .foregroundStyle(.tertiary)
            Text("\(row.count)")
                .font(Theme.font.themedMono(11, .semibold))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 42, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, Theme.spacing.row)
    }

    // MARK: - Trend chart

    /// Chart category colors: source brand colors (the app-wide fixed 3-color categorical scheme)
    private func brandColor(_ source: AgentSource) -> Color { source.brandColor }

    private var trendCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Trend", zhHans: "趋势"))
                    .font(Theme.font.themed(12, .semibold))
                if usageService.trendIsHourly && trendMode == .byDate {
                    Text(L10n.text("Hourly", zhHans: "小时粒度"))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                Spacer()
                ThemedSegmentedPicker(
                    selection: $trendMetric, options: TrendMetric.allCases,
                    label: \.title, classicWidth: 110, controlSize: .mini)
                ThemedSegmentedPicker(
                    selection: $trendMode, options: TrendMode.allCases,
                    label: \.title, classicWidth: 140, controlSize: .mini)
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
        .dashboardCard()
    }

    /// Days whose total (in the selected metric) is at least 2× the median of the previous 7
    /// active days; marked with an orange triangle and the multiple
    private func spikeMarks(_ points: [UsageService.TrendPoint]) -> [(day: Date, total: Double, multiple: Double)] {
        var totals: [Date: Double] = [:]
        for point in points { totals[point.bucket, default: 0] += trendValue(point) }
        let days = totals.keys.sorted()
        let values = days.map { totals[$0] ?? 0 }
        return UsageStats.spikes(values)
            .sorted { $0.key < $1.key }
            .map { (day: days[$0.key], total: values[$0.key], multiple: $0.value) }
    }

    private func trendValue(_ point: UsageService.TrendPoint) -> Double {
        switch trendMetric {
        case .tokens: return Double(point.tokens)
        case .requests: return Double(point.requests)
        case .cost: return point.costUSD
        }
    }

    private func modelMetricValue(_ totals: UsageTotals, cost: Double) -> Double {
        switch trendMetric {
        case .tokens:
            return Double(totals.inputTokens + totals.outputTokens
                + totals.cacheCreationTokens + totals.cacheReadTokens)
        case .requests: return Double(totals.requestCount)
        case .cost: return cost
        }
    }

    /// Axis / annotation label for a value of the selected trend metric
    private func trendLabel(_ value: Double) -> String {
        switch trendMetric {
        case .tokens: return formatTokens(Int(value))
        case .requests: return Int(value).formatted(.number.notation(.compactName))
        case .cost: return costLabel(value)
        }
    }

    /// Cost axis/annotation format (small amounts keep 4 decimals so not everything shows $0.00)
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
            // Daily view only: an hour-by-hour baseline is too noisy to call anything a spike
            let spikes = hourly ? [] : spikeMarks(points)
            Chart {
                ForEach(points) { point in
                    BarMark(
                        x: .value(L10n.text("Time", zhHans: "时间"), point.bucket, unit: hourly ? .hour : .day),
                        y: .value(trendMetric.title, trendValue(point)))
                    .foregroundStyle(by: .value(L10n.text("Source", zhHans: "来源"), point.source.displayName))
                }
                ForEach(spikes, id: \.day) { spike in
                    PointMark(
                        x: .value(L10n.text("Time", zhHans: "时间"), spike.day, unit: .day),
                        y: .value(trendMetric.title, spike.total))
                    .symbol(.triangle)
                    .symbolSize(40)
                    .foregroundStyle(.orange)
                    .annotation(position: .top, spacing: 2) {
                        Text(String(format: "%.1f×", spike.multiple))
                            .font(Theme.font.themedMono(8.5, .semibold))
                            .foregroundStyle(.orange)
                    }
                }
            }
            .chartForegroundStyleScale(domain: sources.map(\.displayName),
                                       range: sources.map(brandColor))
            .chartXScale(domain: axis.domain)  // fixed domain so a lone bar cannot fill the axis
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(trendLabel(number))
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
        // Merge multiple provider rows of the same (source, model) first, then take the top 8
        // (otherwise one model takes several bars)
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
                 metricValue: modelMetricValue(totals, cost: cost))
            }
            .sorted { $0.metricValue > $1.metricValue }
            .prefix(8)
        if models.isEmpty || models.allSatisfy({ $0.metricValue == 0 }) {
            emptyChart(trendMetric == .cost
                ? L10n.text("No priced usage in this range", zhHans: "该时段暂无可计价用量")
                : L10n.text("No model usage in this range", zhHans: "该时段暂无模型用量"))
        } else {
            Chart(Array(models.enumerated()), id: \.offset) { _, item in
                BarMark(
                    x: .value(trendMetric.title, item.metricValue),
                    y: .value(L10n.text("Model", zhHans: "模型"), item.0.model))
                .foregroundStyle(brandColor(item.0.source))
                .annotation(position: .trailing, alignment: .leading) {
                    Text(trendLabel(item.metricValue))
                        .font(Theme.font.themedMono(8))
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(trendLabel(number))
                        }
                    }
                }
            }
        }
    }

    private func emptyChart(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Sources in a fixed order (brand colors don't reshuffle as the data changes)
    private func orderedSources(_ present: [AgentSource]) -> [AgentSource] {
        let set = Set(present)
        return AgentSource.allCases.filter { set.contains($0) }
    }

    // MARK: - Filter row

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ThemedSegmentedPicker(
                    selection: $period, options: UsageService.DashboardPeriod.allCases,
                    label: { periodTitle($0) }, classicWidth: 230, controlSize: .small)

                Spacer(minLength: 8)

                // Manual refresh: incremental rescan of local usage + recompute aggregates for the
                // current range (same as onAppear)
                RefreshButton(help: L10n.text("Refresh statistics (rescan local usage)", zhHans: "刷新统计（重新扫描本地用量）")) {
                    usageService.refreshNow()
                    reload()
                }
            }

            // Source filter chips: All + per-source logos; flow layout wraps when too wide so
            // nothing is clipped at the minimum window width (antigravity content is protobuf so no
            // usage can be extracted; qoder's CN backend reports all-zero tokens so there's no
            // usage --
            //   neither enters usage; grok / kimi have real token accounting → included automatically)
            FlowLayout(spacing: 8, lineSpacing: 6) {
                sourceChip(nil, label: L10n.text("All", zhHans: "全部"))
                // Sources without token accounting get no chip (otherwise it's always an empty
                // list): antigravity has no local tokens; qoder's CN backend reports zero; trae's
                // session DB is SQLCipher-encrypted, so not a single token can be read locally.
                // (since grok 1.0.4x, updates.jsonl carries usage per turn and is in the ledger)
                // antigravity has ledger entries only when the experiment toggle is on
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
                    Text(L10n.text("to", zhHans: "至")).font(Theme.font.themed(10)).foregroundStyle(.secondary)
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
        CompactFilterChip(label: label, source: source, isSelected: sourceFilter == source) {
            sourceFilter = source
        }
    }

    // MARK: - Hero card

    @ViewBuilder
    private var heroCard: some View {
        let m = metrics
        let previous = previousMetrics
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(Theme.font.themed(18))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.brandFill(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Tokens used (%@)", zhHans: "消耗 Tokens（%@）", periodTitle(period)))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(m.totalTokens.formatted(.number.grouping(.automatic)))
                        .font(Theme.font.themedMono(26, .bold))
                    Text("≈ \(chineseUnit(m.totalTokens))")
                        .font(Theme.font.themed(11))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                deltaLabel(
                    current: Double(m.totalTokens), previous: previous.map { Double($0.totalTokens) },
                    showsBaseline: true)
            }
            Spacer(minLength: 10)
            HStack(spacing: 14) {
                heroStat(
                    L10n.text("Requests", zhHans: "总请求数"),
                    value: m.requests.formatted(.number.grouping(.automatic)),
                    delta: deltaLabel(
                        current: Double(m.requests), previous: previous.map { Double($0.requests) }))
                    .help(Self.requestsHelp)
                Divider().frame(height: 40)
                heroStat(
                    L10n.text("Total cost", zhHans: "总成本"),
                    value: m.costUSD.map { formatCost($0) } ?? "—",
                    tint: Theme.cost,
                    delta: deltaLabel(
                        current: m.costUSD ?? 0, previous: previous.map { $0.costUSD ?? 0 }))
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Theme.radius.container).fill(Theme.surfaceSecondary))
        }
        .padding(Theme.spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }

    /// What one "request" is: the unit differs per source, so the mixed total needs a caveat
    private static var requestsHelp: String {
        L10n.text(
            "Rows in the usage ledger. For Claude, Codex and most agents one row is one API call; Grok records one row per whole turn, so a total across sources mixes both.",
            zhHans: "用量账本的行数：Claude、Codex 等多数来源一行即一次 API 调用；Grok 一行是一整轮对话，跨来源合计时两种粒度会混在一起。")
    }

    private func heroStat<Delta: View>(
        _ label: String, value: String, tint: Color = .primary, delta: Delta
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.font.themedMono(18, .semibold))
                .foregroundStyle(tint)
            delta
        }
    }

    /// "↑12% vs yesterday so far". Neutral color on purpose: more usage is not a failure.
    @ViewBuilder
    private func deltaLabel(current: Double, previous: Double?, showsBaseline: Bool = false) -> some View {
        if let previous {
            let change = UsageComparison.change(current: current, previous: previous)
            HStack(spacing: 3) {
                if let change {
                    Image(systemName: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(Theme.font.themed(8, .semibold))
                    Text(String(format: "%.0f%%", abs(change) * 100))
                        .font(Theme.font.themedMono(9.5, .medium))
                } else {
                    Text(L10n.text("No prior data", zhHans: "无对比数据"))
                        .font(Theme.font.themed(9.5))
                }
                if showsBaseline {
                    Text(comparisonTitle)
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    private var comparisonTitle: String {
        switch period {
        case .today: return L10n.text("vs yesterday so far", zhHans: "对比昨日同时段")
        case .week: return L10n.text("vs last week so far", zhHans: "对比上周同期")
        case .month: return L10n.text("vs last month so far", zhHans: "对比上月同期")
        case .custom: return L10n.text("vs the previous range", zhHans: "对比前一等长区间")
        case .all: return ""
        }
    }

    // MARK: - Tiles

    private var metricGrid: some View {
        let m = metrics
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            metricCard(L10n.text("New input", zhHans: "新增输入"), formatTokens(m.inputTokens), icon: "arrow.down.to.line", tint: .blue)
            metricCard(L10n.text("Output", zhHans: "输出"), formatTokens(m.outputTokens), icon: "arrow.up.to.line", tint: .purple)
            metricCard(L10n.text("Cache write", zhHans: "缓存创建"), formatTokens(m.cacheWriteTokens), icon: "externaldrive.badge.plus", tint: .orange)
            metricCard(L10n.text("Cache read", zhHans: "缓存命中"), formatTokens(m.cacheReadTokens), icon: "sparkles", tint: Theme.brandFg)
            metricCard(
                L10n.text("Tokens per request", zhHans: "单次请求 Tokens"),
                m.tokensPerRequest.map { formatTokens(Int($0.rounded())) } ?? "—",
                icon: "divide", tint: .teal)
                .help(Self.requestsHelp)
            metricCard(
                L10n.text("Cost per request", zhHans: "单次请求成本"),
                m.costPerRequest.map { costLabel($0) } ?? "—",
                icon: "dollarsign.circle", tint: Theme.cost)
                .help(Self.requestsHelp)
        }
    }

    private func metricCard(_ label: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(Theme.font.themed(11))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(Theme.font.themedMono(14, .semibold))
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }

    // MARK: - Turns

    /// Per-turn view: one asked prompt is one turn. Cost and tokens per turn only count the
    /// sources that report prompts, so a source without prompt extraction can't inflate them.
    @ViewBuilder
    private var turnCard: some View {
        let turns = usageService.turnSummary
        let turnSources = Set(turns.bySource.keys)
        let turnMetrics = usageService.metrics(
            of: filteredModelTotals.filter { turnSources.contains($0.source) })
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.text("Turns", zhHans: "轮次"))
                    .font(Theme.font.themed(12, .semibold))
                Spacer()
                Text(L10n.format("%@ asked", zhHans: "共 %@ 轮", turns.turns.formatted(.number.grouping(.automatic))))
                    .font(Theme.font.themedMono(11, .semibold))
                    .foregroundStyle(.secondary)
            }
            if turns.turns > 0 {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                          alignment: .leading, spacing: 8) {
                    turnStat(
                        L10n.text("Cost per turn", zhHans: "每轮成本"),
                        turnMetrics.costUSD.map { costLabel($0 / Double(turns.turns)) } ?? "—",
                        tint: Theme.cost)
                    turnStat(
                        L10n.text("Tokens per turn", zhHans: "每轮 Tokens"),
                        formatTokens(turnMetrics.totalTokens / max(1, turns.turns)))
                    turnStat(
                        L10n.text("Requests per turn", zhHans: "每轮请求"),
                        String(format: "%.1f", Double(turnMetrics.requests) / Double(turns.turns)))
                        .help(Self.requestsHelp)
                    turnStat(
                        L10n.text("Median duration", zhHans: "耗时中位数"),
                        turns.medianDuration.map(formatDuration) ?? "—")
                    turnStat(
                        L10n.text("Duration P90", zhHans: "耗时 P90"),
                        turns.p90Duration.map(formatDuration) ?? "—")
                        .help(L10n.text(
                            "9 in 10 turns finish within this time",
                            zhHans: "九成的轮次在这个时间内结束"))
                    turnStat(
                        L10n.text("Error / rework", zhHans: "出错 / 返工"),
                        [turns.errorRate, turns.reworkRate]
                            .map { $0.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
                            .joined(separator: " / "))
                        .help(L10n.text(
                            "Error: the turn ended in an error. Rework: your next prompt corrected it (\"that's wrong\", \"redo\") or rephrased the same ask while struggling.",
                            zhHans: "出错：这一轮以错误结束。返工：你的下一句是在纠正（“不对”“重来”），或在反复改写同一个问题。"))
                }
                Text(L10n.format(
                    "Counted from your prompts: %@",
                    zhHans: "按你的每次提问统计：%@",
                    AgentSource.allCases.filter { turnSources.contains($0) }
                        .map { "\($0.displayName) \(turns.bySource[$0] ?? 0)" }
                        .joined(separator: " · ")))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L10n.text("No prompts in this range", zhHans: "该时段没有可统计的提问"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.spacing.card)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
    }

    private func turnStat(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.font.themedMono(13, .semibold))
                .foregroundStyle(tint)
        }
    }

    // MARK: - Concentration

    /// How much of the range a handful of sessions account for; usage is usually very skewed, so
    /// this points at the few sessions worth a look
    @ViewBuilder
    private var concentrationCard: some View {
        let m = metrics
        let sessions = usageService.sessionTotals
        let tokenShare = UsageStats.topShare(
            sessions.map { Double($0.tokens) }, top: 10, total: Double(m.totalTokens))
        let costShare = m.costUSD.flatMap {
            UsageStats.topShare(sessions.map { $0.costUSD ?? 0 }, top: 10, total: $0)
        }
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Concentration", zhHans: "集中度"))
                .font(Theme.font.themed(12, .semibold))
            if let tokenShare, sessions.count > 1 {
                Text(L10n.format(
                    "The top %1$@ sessions use %2$@ of tokens",
                    zhHans: "前 %1$@ 个会话用掉了 %2$@ 的 tokens",
                    String(min(10, sessions.count)), String(format: "%.0f%%", tokenShare * 100)))
                    .font(Theme.font.themed(11, .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let costShare {
                    Text(L10n.format("and %@ of cost", zhHans: "以及 %@ 的成本",
                                     String(format: "%.0f%%", costShare * 100)))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                SecondaryButton(
                    title: L10n.text("See the sessions", zhHans: "查看会话排行"),
                    icon: "list.number", classic: .push
                ) { subTab = .sessions }
            } else {
                Text(L10n.text("Not enough sessions in this range", zhHans: "该时段会话太少"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.spacing.card)
        .frame(width: 220, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .dashboardCard()
    }

    // MARK: - Cost structure

    private static let costSegments: [(key: KeyPath<CostBreakdown, Double>, label: String, tint: Color)] = [
        (\.input, L10n.text("New input", zhHans: "新增输入"), .blue),
        (\.output, L10n.text("Output", zhHans: "输出"), .purple),
        (\.cacheWrite, L10n.text("Cache write", zhHans: "缓存创建"), .orange),
        (\.cacheRead, L10n.text("Cache read", zhHans: "缓存命中"), Theme.brand),
        (\.reported, L10n.text("Self-reported", zhHans: "来源自报"), .gray),
    ]

    /// Where the money goes by token type. Cache reads dominate the token count, so the cost split
    /// is what tells you whether output or cache writes are the real bill.
    @ViewBuilder
    private var costStructureCard: some View {
        let split = usageService.costBreakdown(of: filteredModelTotals)
        let total = split.total
        let segments = Self.costSegments.filter { split[keyPath: $0.key] > 0 }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.text("Where the cost goes", zhHans: "成本构成"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if total > 0, metrics.totalTokens > 0 {
                    let readTokenShare = Double(metrics.cacheReadTokens) / Double(metrics.totalTokens)
                    Text(L10n.format(
                        "Cache reads: %1$@ of tokens, %2$@ of cost",
                        zhHans: "缓存命中占 %1$@ 的 tokens，只占 %2$@ 的成本",
                        String(format: "%.0f%%", readTokenShare * 100),
                        String(format: "%.0f%%", split.cacheRead / total * 100)))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                }
            }
            if total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 1) {
                        ForEach(segments, id: \.label) { segment in
                            Rectangle()
                                .fill(segment.tint)
                                .frame(width: max(2, (proxy.size.width - CGFloat(segments.count - 1))
                                    * split[keyPath: segment.key] / total))
                        }
                    }
                    .clipShape(Capsule())
                }
                .frame(height: 8)
                HStack(spacing: 14) {
                    ForEach(segments, id: \.label) { segment in
                        HStack(spacing: 4) {
                            Circle().fill(segment.tint).frame(width: 7, height: 7)
                            Text(segment.label)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                            Text("\(costLabel(split[keyPath: segment.key])) · \(String(format: "%.0f%%", split[keyPath: segment.key] / total * 100))")
                                .font(Theme.font.themedMono(10, .medium))
                        }
                    }
                }
            } else {
                Text(L10n.text("No priced usage in this range", zhHans: "该时段暂无可计价用量"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }

    // MARK: - Cache hit rate

    private var cacheHitCard: some View {
        let m = metrics
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(L10n.text("Cache hit rate", zhHans: "缓存命中率"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .help(L10n.text(
                        "Cache reads ÷ (new input + cache write + cache read). Output is excluded because it is never cached.",
                        zhHans: "缓存命中 ÷（新增输入 + 缓存创建 + 缓存命中）。输出不会被缓存，因此不计入分母。"))
                Spacer()
                if let saved = m.cacheSavingsUSD, saved > 0 {
                    Text(L10n.format("Saved ≈ %@", zhHans: "为你省下 ≈ %@", costLabel(saved)))
                        .font(Theme.font.themedMono(10, .medium))
                        .foregroundStyle(Theme.cost)
                        .help(L10n.text(
                            "What the cache reads would have cost as fresh input, minus what they did cost. Unpriced models and self-reported costs are left out.",
                            zhHans: "这些缓存命中若按新增输入计价要多花的钱（输入价 − 缓存读价）。未定价模型和自报成本的来源不计入。"))
                }
                Text(String(format: "%.1f%%", m.cacheHitRate * 100))
                    .font(Theme.font.themedMono(11, .semibold))
                    .foregroundStyle(Theme.brandFg)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    if m.cacheHitRate > 0 {
                        Capsule()
                            .fill(Theme.barFill(Theme.brand, from: 0.6))
                            .frame(width: max(4, proxy.size.width * m.cacheHitRate))
                    }
                }
            }
            .frame(height: 6)
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
    }

    // MARK: - Sub-tabs

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

    // MARK: - Weekly report

    private var weeklySection: some View {
        // Monday-based, same seven days as the "This week" period above (UsageAggregator pins
        // Monday)
        let range = UsageAggregator.weekRange(offset: weekOffset)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    weekOffset += 1
                    loadWeekly()
                } label: { Image(systemName: "chevron.left").font(Theme.font.themed(10)) }
                .buttonStyle(.borderless)
                Text(weekOffset == 0 ? L10n.text("This week", zhHans: "本周") : (weekOffset == 1 ? L10n.text("Last week", zhHans: "上周") : L10n.format("%@ weeks ago", zhHans: "%@ 周前", "\(weekOffset)")))
                    .font(Theme.font.themed(12, .semibold))
                Text("\(range.start, format: .dateTime.month().day()) – \(range.end.addingTimeInterval(-1), format: .dateTime.month().day())")
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(.secondary)
                Button {
                    weekOffset = max(0, weekOffset - 1)
                    loadWeekly()
                } label: { Image(systemName: "chevron.right").font(Theme.font.themed(10)) }
                .buttonStyle(.borderless)
                .disabled(weekOffset == 0)
                // The report is a whole-week digest with its own "By source" breakdown; say so instead of
                // letting a highlighted source chip imply the numbers below are filtered.
                if sourceFilter != nil {
                    Text(L10n.text("The weekly report counts every source and ignores the source filter", zhHans: "周报按全部来源统计，不受来源筛选影响"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let note = weeklyExportNote {
                    Text(note)
                        .font(Theme.font.themed(9.5))
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
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        .padding(Theme.spacing.card)
        .dashboardCard()
        .onAppear { loadWeekly() }
    }

    @ViewBuilder
    private func weeklyStats(_ report: WeeklyReport) -> some View {
        // Overview row
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
                    .font(Theme.font.themed(10.5, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSessions) { entry in
                    HStack(spacing: 6) {
                        Text(sessionBrowser.sessionsById[entry.sessionId]?.name
                            ?? L10n.format("Session %@", zhHans: "会话 %@", "\(entry.sessionId.prefix(8))"))
                            .font(Theme.font.themed(11))
                            .lineLimit(1)
                        if let project = entry.project {
                            Text(project)
                                .font(Theme.font.themed(9.5))
                                .foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 6)
                        Text(formatTokens(entry.tokens))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.secondary)
                        Text(formatCost(entry.costUSD ?? 0))
                            .font(Theme.font.themedMono(10.5, .medium))
                            .foregroundStyle(Theme.cost)
                    }
                }
            }
        }
        if !report.topSkills.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Top skill calls", zhHans: "技能调用 Top"))
                    .font(Theme.font.themed(10.5, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSkills, id: \.name) { skill in
                    HStack {
                        Text(skill.name)
                            .font(Theme.font.themed(11))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.format("%@ times", zhHans: "%@ 次", "\(skill.count)"))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let prompts = report.promptSection, !prompts.topReused.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text("Most reused prompts", zhHans: "提问复用 Top"))
                    .font(Theme.font.themed(10.5, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(prompts.topReused, id: \.name) { prompt in
                    HStack {
                        Text(prompt.name)
                            .font(Theme.font.themed(11))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(L10n.format("%@ times total", zhHans: "累计 %@ 次", "\(prompt.count)"))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func weeklyStat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(Theme.font.themedMono(12, .semibold))
                .foregroundStyle(color)
        }
    }

    private func weeklyRankColumn(_ title: String, _ entries: [WeeklyReport.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.font.themed(10.5, .semibold))
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("—").font(Theme.font.themed(10.5)).foregroundStyle(.tertiary)
            }
            ForEach(entries) { entry in
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(Theme.font.themed(10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(formatCost(entry.costUSD ?? 0))
                        .font(Theme.font.themedMono(10))
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

    // MARK: - Request log (paged table)

    private var requestLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Table header
            HStack(spacing: 8) {
                Text(L10n.text("Time", zhHans: "时间")).frame(width: 76, alignment: .leading)
                Text(L10n.text("Source", zhHans: "来源")).frame(width: 66, alignment: .leading)
                Text(L10n.text("Model", zhHans: "模型")).frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text(L10n.text("Input", zhHans: "输入")).frame(width: 76, alignment: .trailing)
                Text(L10n.text("Output", zhHans: "输出")).frame(width: 56, alignment: .trailing)
                Text(L10n.text("Cost", zhHans: "成本")).frame(width: 66, alignment: .trailing)
            }
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.records.isEmpty {
                Text(L10n.text("No requests in this range", zhHans: "该时段暂无请求记录"))
                    .font(Theme.font.themed(11))
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
        .dashboardCard()
    }

    private func logRow(_ record: UsageService.RecordDisplay) -> some View {
        HStack(spacing: 8) {
            Text(record.row.ts, format: .dateTime.month(.twoDigits).day(.twoDigits)
                .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            HStack(spacing: 3) {
                SourceBadge(source: record.row.source, size: 9)
                Text(record.row.source.rawValue)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 66, alignment: .leading)
            Text(record.row.model)
                .font(Theme.font.monoSkillName(10, weight: .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                Text(formatTokens(record.row.inputTokens))
                    .font(Theme.font.themedMono(10.5, .medium))
                if record.row.cacheReadTokens > 0 {
                    Text("R\(formatTokens(record.row.cacheReadTokens))")
                        .font(Theme.font.themedMono(8.5))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 76, alignment: .trailing)
            Text(formatTokens(record.row.outputTokens))
                .font(Theme.font.themedMono(10.5))
                .frame(width: 56, alignment: .trailing)
            Text(record.costUSD.map { costLabel($0) } ?? "—")
                .font(Theme.font.themedMono(10.5))
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
            Text(L10n.format("%@ total", zhHans: "共 %@ 条", "\(usageService.recordTotal)"))
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                page = max(1, page - 1)
                reload()
            } label: {
                Image(systemName: "chevron.left").font(Theme.font.themed(9))
            }
            .buttonStyle(.borderless)
            .disabled(page <= 1)
            Text("\(page) / \(totalPages)")
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.secondary)
            Button {
                page = min(totalPages, page + 1)
                reload()
            } label: {
                Image(systemName: "chevron.right").font(Theme.font.themed(9))
            }
            .buttonStyle(.borderless)
            .disabled(page >= totalPages)
            // Jump to page
            Text(L10n.text("Go to", zhHans: "跳至")).font(Theme.font.themed(10)).foregroundStyle(.tertiary)
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .font(Theme.font.themedMono(10))
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

    // MARK: - Model stats

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
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            let filtered = usageService.modelTotals.filter {
                sourceFilter == nil || $0.source == sourceFilter
            }
            if filtered.isEmpty {
                Text(L10n.text("No model usage in this range", zhHans: "该时段暂无模型用量"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(Array(filtered.enumerated()), id: \.offset) { _, totals in
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            SourceBadge(source: totals.source, size: 9)
                            Text(totals.model)
                                .font(Theme.font.monoSkillName(10, weight: .regular))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            // Same-name models get one row per provider (subscription plan vs
                            // pay-as-you-go)
                            if let provider = totals.provider {
                                Text(provider)
                                    .font(Theme.font.themed(9))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                        Text("\(totals.requestCount)")
                            .font(Theme.font.themedMono(10.5))
                            .frame(width: 46, alignment: .trailing)
                        Text(formatTokens(totals.inputTokens))
                            .font(Theme.font.themedMono(10.5))
                            .frame(width: 62, alignment: .trailing)
                        Text(formatTokens(totals.outputTokens))
                            .font(Theme.font.themedMono(10.5))
                            .frame(width: 62, alignment: .trailing)
                        Text(formatTokens(totals.cacheReadTokens + totals.cacheCreationTokens))
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                        Text(usageService.cost(of: totals).map { costLabel($0) } ?? "—")
                            .font(Theme.font.themedMono(10.5))
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
        .dashboardCard()
    }

    // MARK: - Per-session stats

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
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.sessionTotals.isEmpty {
                Text(L10n.text("No session usage in this range", zhHans: "该时段暂无会话用量"))
                    .font(Theme.font.themed(11))
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
        .dashboardCard()
        .onAppear {
            // Session names come from the file index; it may not be built yet the first time the
            // sub-tab opens
            if sessionBrowser.sessionsById.isEmpty {
                sessionBrowser.refresh()
            }
        }
    }

    private func sessionRow(_ line: UsageService.SessionTotal) -> some View {
        let info = sessionBrowser.sessionsById[line.sessionId]
        // Old sessions outside the index window have no name; fall back to a short id and disable
        // jumping
        let canJump = info != nil
        return Button {
            guard canJump else { return }
            NotificationCenter.default.post(
                name: .eurekaRevealSession, object: line.sessionId)
        } label: {
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    SourceBadge(source: line.source, size: 9)
                    Text(info?.name ?? L10n.format("Session %@", zhHans: "会话 %@", "\(line.sessionId.prefix(8))"))
                        .font(Theme.font.themed(10.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                Text(line.project ?? "—")
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 90, alignment: .leading)
                Text("\(line.requests)")
                    .font(Theme.font.themedMono(10.5))
                    .frame(width: 42, alignment: .trailing)
                Text(formatTokens(line.tokens))
                    .font(Theme.font.themedMono(10.5, .medium))
                    .frame(width: 58, alignment: .trailing)
                Text(line.costUSD.map { costLabel($0) } ?? "—")
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(Theme.cost)
                    .frame(width: 62, alignment: .trailing)
                Text(relativeFormatter.localizedString(
                    for: line.lastActiveAt, relativeTo: Date()))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .frame(width: 64, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(Theme.font.themed(8))
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

    // MARK: - Project stats

    private var projectStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usageService.projectTotals.isEmpty {
                Text(L10n.text("No project usage in this range", zhHans: "该时段暂无项目用量"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(usageService.projectTotals) { line in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(Theme.font.themed(9))
                            .foregroundStyle(Theme.brandFg.opacity(0.7))
                        Text(line.name)
                            .font(Theme.font.themed(11))
                            .lineLimit(1)
                        Spacer()
                        Text(L10n.format("%@ req", zhHans: "%@ 次", line.requests.formatted(.number.grouping(.automatic))))
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.tertiary)
                            .frame(width: 70, alignment: .trailing)
                            .help(Self.requestsHelp)
                        Text(formatTokens(line.tokens))
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 62, alignment: .trailing)
                        Text(line.costUSD.map { costLabel($0) } ?? "—")
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(Theme.cost)
                            .frame(width: 66, alignment: .trailing)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, Theme.spacing.row)
                    Divider().opacity(0.4)
                }
            }
        }
        .dashboardCard()
    }

    // MARK: - Footer

    private var footerRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Button(L10n.text("Export the last 30 days as CSV", zhHans: "导出近 30 天 CSV")) { usageService.exportCSV() }
                    .controlSize(.small)
                if let message = usageService.exportMessage {
                    Text(message)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L10n.text("Cost is estimated locally from public LiteLLM / models.dev prices. Subscription plans use the API-equivalent rate, so it can differ from your bill. Hover a cost to see where the price came from. Settings → Advanced → Model prices lists unpriced models and accepts custom prices.", zhHans: "费用为本地估算（LiteLLM / models.dev 公开价格，订阅套餐按 API 等价价折算），与账单可能有出入；悬停费用可看价格来源，设置 → 高级 → 模型价格可查看未定价模型并自定义。"))
                .font(Theme.font.themed(9.5))
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

    /// Readable magnitude next to the exact total: Chinese units (wan = 10^4 / yi = 10^8) in the
    /// Chinese UI, the usual k / M / B in English (a "×100M" unit reads oddly there)
    private func chineseUnit(_ value: Int) -> String {
        if L10n.current == .english { return formatTokens(value) }
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
    /// Usage "by session" ranking → switch to the Sessions tab and select it (carries the session
    /// id). A notification instead of passing navigation through, so the usage panel in Settings
    /// can jump too.
    static let eurekaRevealSession = Notification.Name("eurekaRevealSession")
    /// Cross-page jump: knowledge entry (object = file path String; userInfo["kind"] =
    /// skill/memory/instruction)
    static let eurekaRevealKnowledge = Notification.Name("eurekaRevealKnowledge")
    /// Cross-page jump: plan entry (object = file path String)
    static let eurekaRevealPlan = Notification.Name("eurekaRevealPlan")
    /// Cross-page jump: Prompt library entry (object = entry id String)
    static let eurekaRevealPrompt = Notification.Name("eurekaRevealPrompt")
    /// ⌘K global search palette toggle (posted by MainMenu, received by PopoverRootView)
    static let eurekaToggleCommandPalette = Notification.Name("eurekaToggleCommandPalette")
}
