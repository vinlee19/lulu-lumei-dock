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

    private enum SubTab: String, CaseIterable {
        case log = "请求日志"
        case models = "模型统计"
        case projects = "项目统计"
        case sessions = "按会话"
        case tools = "技能/插件"
        case weekly = "周报"
    }

    /// 周报周偏移：0 = 本周，1 = 上周…
    @State private var weekOffset = 0
    @State private var weeklyExportNote: String?

    private enum TrendMode: String, CaseIterable {
        case byDate = "按日期"
        case byModel = "按模型"
    }

    private enum TrendMetric: String, CaseIterable {
        case tokens = "Tokens"
        case cost = "成本"
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
                    ProgressView("正在扫描本地会话…")
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
        usageService.loadProjectTotals(from: range.from, to: range.to)
        usageService.loadToolCalls(source: sourceFilter, from: range.from, to: range.to)
        usageService.loadTrend(from: range.from, to: range.to)
        usageService.loadSessionTotals(from: range.from, to: range.to, source: sourceFilter)
        usageService.loadHeatmap(from: range.from, to: range.to, source: sourceFilter)
    }

    // MARK: - 技能/插件统计

    @State private var toolKindFilter: String?  // nil = 全部；skill/mcp/agent/command/tool

    private static let kindLabels: [(key: String, label: String, icon: String, color: Color)] = [
        ("skill", "技能", "wand.and.stars", .purple),
        ("mcp", "MCP 插件", "puzzlepiece.extension.fill", .indigo),
        ("agent", "子代理", "person.2.fill", .teal),
        ("command", "命令", "terminal.fill", .gray),
        ("tool", "工具", "wrench.and.screwdriver.fill", .secondary),
    ]

    private static func kindMeta(_ kind: String) -> (label: String, icon: String, color: Color) {
        if let m = kindLabels.first(where: { $0.key == kind }) {
            return (m.label, m.icon, m.color)
        }
        return (kind, "questionmark", .secondary)
    }

    @ViewBuilder
    private var toolStats: some View {
        let rows = usageService.toolCallTotals
            .filter { toolKindFilter == nil || $0.kind == toolKindFilter }
        let maxCount = rows.map(\.count).max() ?? 1
        VStack(alignment: .leading, spacing: 0) {
            // kind 筛选 chips
            HStack(spacing: 4) {
                kindChip(nil, "全部")
                ForEach(Self.kindLabels, id: \.key) { item in
                    kindChip(item.key, item.label)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()

            if rows.isEmpty {
                Text("该时段暂无技能/插件调用记录")
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
                .foregroundStyle(selected ? Theme.brand : .secondary)
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
                .foregroundStyle(Theme.brand)
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
                Text("趋势")
                    .font(.system(size: 12, weight: .semibold))
                if usageService.trendIsHourly && trendMode == .byDate {
                    Text("小时粒度")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.05)))
                }
                Spacer()
                Picker("", selection: $trendMetric) {
                    ForEach(TrendMetric.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 110)
                .controlSize(.mini)
                Picker("", selection: $trendMode) {
                    ForEach(TrendMode.allCases, id: \.self) { Text($0.rawValue) }
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
            emptyChart("该时段暂无用量")
        } else {
            let sources = orderedSources(points.map(\.source))
            let rangeDays = range.to.timeIntervalSince(range.from) / 86400
            Chart(points) { point in
                BarMark(
                    x: .value("时间", point.bucket, unit: hourly ? .hour : .day),
                    y: .value(
                        trendMetric.rawValue,
                        trendMetric == .tokens ? Double(point.tokens) : point.costUSD))
                .foregroundStyle(by: .value("来源", point.source.displayName))
            }
            .chartForegroundStyleScale(domain: sources.map(\.displayName),
                                       range: sources.map(brandColor))
            .chartXScale(domain: range.from...range.to)  // 固定轴域，防单柱铺满
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
                    AxisMarks(values: .stride(by: .day, count: rangeDays <= 8 ? 1 : 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
            }
            .chartLegend(position: .bottom, spacing: 6)
        }
    }

    @ViewBuilder
    private var byModelChart: some View {
        let models = usageService.modelTotals
            .filter { sourceFilter == nil || $0.source == sourceFilter }
            .map { totals in
                (totals,
                 metricValue: trendMetric == .tokens
                    ? Double(totals.inputTokens + totals.outputTokens
                        + totals.cacheCreationTokens + totals.cacheReadTokens)
                    : (usageService.cost(of: totals) ?? 0))
            }
            .sorted { $0.metricValue > $1.metricValue }
            .prefix(8)
        if models.isEmpty || models.allSatisfy({ $0.metricValue == 0 }) {
            emptyChart(trendMetric == .tokens ? "该时段暂无模型用量" : "该时段暂无可计价用量")
        } else {
            Chart(Array(models.enumerated()), id: \.offset) { _, item in
                BarMark(
                    x: .value(trendMetric.rawValue, item.metricValue),
                    y: .value("模型", item.0.model))
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
                        Text($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
                .controlSize(.small)

                Spacer(minLength: 8)

                // 来源筛选 chips：全部 + 各来源徽标
                // （grok 订阅制无 token/费用账；antigravity 内容为 protobuf 无法取用量，故均不入用量；
                //   kimi 有真实 token 账 → 自动包含）
                sourceChip(nil, label: "全部")
                ForEach(AgentSource.allCases.filter { $0 != .grok && $0 != .antigravity },
                        id: \.self) { source in
                    sourceChip(source, label: source.displayName)
                }
            }
            if period == .custom {
                HStack(spacing: 6) {
                    DatePicker("", selection: $customFrom, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                    Text("至").font(.system(size: 10)).foregroundStyle(.secondary)
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
            .foregroundStyle(selected ? Theme.brand : .secondary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 英雄卡

    private var heroCard: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.brand)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Theme.brandFill(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text("消耗 Tokens（\(period.rawValue)）")
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
                        Text("总请求数")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                        Text("\(totalRequests)")
                            .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    }
                    Divider().frame(height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("总成本")
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
            metricCard("新增输入", totalInput, icon: "arrow.down.to.line", tint: .blue)
            metricCard("输出", totalOutput, icon: "arrow.up.to.line", tint: .purple)
            metricCard("缓存创建", totalCacheWrite, icon: "externaldrive.badge.plus", tint: .orange)
            metricCard("缓存命中", totalCacheRead, icon: "sparkles", tint: Theme.brand)
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
                Text("缓存命中率")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f%%", cacheHitRate * 100))
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.brand)
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
                    title: tab.rawValue, fillWidth: false, isSelected: subTab == tab
                ) {
                    subTab = tab
                }
            }
            Spacer()
        }
    }

    // MARK: - 周报

    /// 周区间：[周一零点, 下周一零点)，weekOffset 往回翻
    private func weekRange(offset: Int) -> (start: Date, end: Date) {
        let calendar = Calendar.current
        let interval = calendar.dateInterval(of: .weekOfYear, for: Date())
            ?? DateInterval(start: Date(), duration: 7 * 86400)
        let start = calendar.date(
            byAdding: .weekOfYear, value: -offset, to: interval.start) ?? interval.start
        let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)
            ?? start.addingTimeInterval(7 * 86400)
        return (start, end)
    }

    private var weeklySection: some View {
        let range = weekRange(offset: weekOffset)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    weekOffset += 1
                    loadWeekly()
                } label: { Image(systemName: "chevron.left").font(.system(size: 10)) }
                .buttonStyle(.borderless)
                Text(weekOffset == 0 ? "本周" : (weekOffset == 1 ? "上周" : "\(weekOffset) 周前"))
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
                Spacer()
                if let note = weeklyExportNote {
                    Text(note)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
                Button("导出 Markdown") { exportWeekly() }
                    .controlSize(.small)
                    .disabled(usageService.weeklyReport?.isEmpty ?? true)
            }

            if let report = usageService.weeklyReport, !report.isEmpty {
                weeklyStats(report)
            } else {
                Text("该周没有活动记录")
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
            weeklyStat("活跃时长", "≈\(report.activeHours) 小时")
            weeklyStat("消耗", formatTokens(report.totalTokens))
            weeklyStat("费用", formatCost(report.totalCostUSD ?? 0), color: Theme.cost)
            let total = report.successCount + report.errorCount + report.interruptedCount
            if total > 0 {
                weeklyStat("任务", "\(total) 个 · 成功 \(report.successCount)")
            }
            if report.lateNightDays > 0 {
                weeklyStat("深夜编码", "\(report.lateNightDays) 天", color: .orange)
            }
            Spacer(minLength: 0)
        }
        Divider()
        HStack(alignment: .top, spacing: 18) {
            weeklyRankColumn("按来源", report.bySource)
            weeklyRankColumn("模型 Top", report.byModel)
            weeklyRankColumn("项目 Top", report.byProject)
        }
        if !report.topSessions.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text("最贵会话")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSessions) { entry in
                    HStack(spacing: 6) {
                        Text(sessionBrowser.sessionsById[entry.sessionId]?.name
                            ?? "会话 \(entry.sessionId.prefix(8))")
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
                Text("技能调用 Top")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                ForEach(report.topSkills, id: \.name) { skill in
                    HStack {
                        Text(skill.name)
                            .font(.system(size: 11))
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text("\(skill.count) 次")
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
        let range = weekRange(offset: weekOffset)
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
            weeklyExportNote = "已导出 \(url.lastPathComponent)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { weeklyExportNote = nil }
        }
    }

    // MARK: - 请求日志（分页表格）

    private var requestLog: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 表头
            HStack(spacing: 8) {
                Text("时间").frame(width: 76, alignment: .leading)
                Text("来源").frame(width: 66, alignment: .leading)
                Text("模型").frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
                Text("输入").frame(width: 76, alignment: .trailing)
                Text("输出").frame(width: 56, alignment: .trailing)
                Text("成本").frame(width: 66, alignment: .trailing)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.records.isEmpty {
                Text("该时段暂无请求记录")
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
            Text("共 \(usageService.recordTotal) 条")
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
            Text("跳至").font(.system(size: 10)).foregroundStyle(.tertiary)
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
                Text("模型").frame(minWidth: 120, maxWidth: .infinity, alignment: .leading)
                Text("请求").frame(width: 46, alignment: .trailing)
                Text("输入").frame(width: 62, alignment: .trailing)
                Text("输出").frame(width: 62, alignment: .trailing)
                Text("缓存").frame(width: 62, alignment: .trailing)
                Text("成本").frame(width: 66, alignment: .trailing)
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
                Text("该时段暂无模型用量")
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
                Text("会话").frame(minWidth: 130, maxWidth: .infinity, alignment: .leading)
                Text("项目").frame(width: 90, alignment: .leading)
                Text("请求").frame(width: 42, alignment: .trailing)
                Text("Tokens").frame(width: 58, alignment: .trailing)
                Text("成本").frame(width: 62, alignment: .trailing)
                Text("最近活跃").frame(width: 64, alignment: .trailing)
                Text("").frame(width: 12)
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            if usageService.sessionTotals.isEmpty {
                Text("该时段暂无会话用量")
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
                    Text(info?.name ?? "会话 \(line.sessionId.prefix(8))")
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
        .help(canJump ? "跳转到会话页签查看详情" : "该会话不在索引窗口内（仅显示用量）")
    }

    // MARK: - 项目统计

    private var projectStats: some View {
        VStack(alignment: .leading, spacing: 0) {
            if usageService.projectTotals.isEmpty {
                Text("该时段暂无项目用量")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ForEach(usageService.projectTotals) { line in
                    HStack {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Theme.brand.opacity(0.7))
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
                Button("导出近 30 天 CSV") { usageService.exportCSV() }
                    .controlSize(.small)
                if let message = usageService.exportMessage {
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Text("费用为本地估算（按公开价目），与账单可能有出入；价格表可在 ~/Library/Application Support/Eureka/pricing.json 覆盖。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    /// 中文单位（万/亿）副标签
    private func chineseUnit(_ value: Int) -> String {
        switch value {
        case ..<10_000: return "\(value)"
        case ..<100_000_000: return String(format: "%.1f 万", Double(value) / 10_000)
        default: return String(format: "%.2f 亿", Double(value) / 100_000_000)
        }
    }
}

extension Notification.Name {
    /// 用量"按会话"排行 → 切到会话页签并选中（携带 session id）。
    /// 用通知而非透传 navigation：设置页里的用量面板也能跳转。
    static let eurekaRevealSession = Notification.Name("eurekaRevealSession")
}
