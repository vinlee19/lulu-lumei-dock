import Charts
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// Colors of the operation kinds in the analytics charts. Fixed hues, like the per-vendor brand
/// colors: a kind keeps its color across rows, charts and styles, which is what makes two stacked
/// bars comparable. Not `Theme` tokens.
enum AuditKindPalette {
    /// Chart order: the kinds that make up most of a log first
    static let order: [ToolKind] = [
        .command, .edit, .read, .search, .web, .mcp, .agent, .skill, .other,
    ]

    static func color(_ kind: ToolKind) -> Color {
        switch kind {
        case .command: return Theme.brand
        case .edit: return Theme.gold
        case .read: return .teal
        case .search: return .mint
        case .web: return .blue
        case .mcp: return .purple
        case .agent: return .pink
        case .skill: return .orange
        case .other: return Theme.disabledGray
        }
    }
}

/// The audit page's analytics view: operations grouped by model / source / project / session with
/// their mix of kinds, a daily trend, the rules that fired, and a few rankings.
///
/// Everything here is computed by `AuditService.loadAnalytics` off the main thread; the view only
/// asks again when the dimension or the period changes.
struct AuditAnalyticsView: View {
    enum Period: Hashable {
        case all, last7, last30, last90, custom
    }

    enum SortKey: Hashable {
        case total, riskRate, high, errorRate
    }

    @ObservedObject var service: AuditService
    /// Show the log filtered to one group (the row was clicked)
    let onSelect: (AuditRepo.Dimension, String) -> Void

    @State private var dimension: AuditRepo.Dimension
    @State private var period: Period
    @State private var customRange: UsageRangeSelection = .default
    @State private var showsRangePicker = false
    @State private var showsAllGroups = false
    @State private var sort: SortKey = .total

    /// Rows shown before "show all"
    private static let collapsedGroupCount = 10

    init(
        service: AuditService, initialDimension: AuditRepo.Dimension = .model,
        initialPeriod: Period = .last30,
        onSelect: @escaping (AuditRepo.Dimension, String) -> Void
    ) {
        self._service = ObservedObject(wrappedValue: service)
        self.onSelect = onSelect
        self._dimension = State(initialValue: initialDimension)
        self._period = State(initialValue: initialPeriod)
    }

    private var query: AuditRepo.Query {
        var query = AuditRepo.Query()
        let range: UsageDateRange?
        switch period {
        case .all: range = nil
        case .last7: range = .preset(.last7Days)
        case .last30: range = .preset(.last30Days)
        case .last90: range = .preset(.last90Days)
        case .custom: range = customRange.resolve()
        }
        if let range {
            let interval = range.interval()
            query.from = interval.from
            query.to = interval.to
        }
        return query
    }

    private var analytics: AuditAnalytics? {
        // A result for another dimension is stale while the new one is being computed
        service.analytics.flatMap { $0.dimension == dimension ? $0 : nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls
                if let analytics, analytics.totals.total > 0 {
                    summary(analytics)
                    groupTable(analytics)
                    trend(analytics)
                    if !analytics.rules.isEmpty { risk(analytics) }
                    rankings(analytics)
                } else if service.analyticsLoading || service.analytics == nil {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else {
                    EmptyStateView(
                        icon: "chart.bar.xaxis",
                        title: L10n.text("No operations in this period", zhHans: "这段时间没有操作记录"),
                        hint: L10n.text("Pick a longer period", zhHans: "换一个更长的时间范围"))
                        .padding(.top, 40)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
        .onAppear { reload() }
        .onChange(of: dimension) { _, _ in
            showsAllGroups = false
            reload()
        }
        .onChange(of: period) { _, _ in reload() }
        .onChange(of: customRange) { _, _ in reload() }
        .onChange(of: service.historyRevision) { _, _ in reload() }
    }

    private func reload() {
        service.loadAnalytics(query: query, dimension: dimension)
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 10) {
            Text(L10n.text("Group by", zhHans: "分组")).font(Theme.font.themed(11)).foregroundStyle(.secondary)
            ThemedSegmentedPicker(
                selection: $dimension, options: AuditRepo.Dimension.allCases,
                label: Self.label(for:), classicWidth: 260)
            Spacer(minLength: 12)
            ThemedSegmentedPicker(
                selection: $period, options: [.last7, .last30, .last90, .all, .custom],
                label: periodLabel, classicWidth: 330)
            if period == .custom {
                SecondaryButton(
                    title: UsageRangeText.button(customRange), icon: "calendar",
                    help: L10n.text("Choose the days", zhHans: "选择日期区间")
                ) { showsRangePicker = true }
                .popover(isPresented: $showsRangePicker, arrowEdge: .bottom) {
                    UsageRangePicker(
                        selection: customRange,
                        onApply: { selection in
                            customRange = selection
                            showsRangePicker = false
                        },
                        onCancel: { showsRangePicker = false })
                }
            }
        }
    }

    static func groupCount(_ count: Int, _ dimension: AuditRepo.Dimension) -> String {
        let number = String(count)
        switch dimension {
        case .model: return L10n.format("%@ models", zhHans: "%@ 个模型", number)
        case .source: return L10n.format("%@ sources", zhHans: "%@ 个来源", number)
        case .project: return L10n.format("%@ projects", zhHans: "%@ 个项目", number)
        case .session: return L10n.format("%@ sessions", zhHans: "%@ 个会话", number)
        }
    }

    static func label(for dimension: AuditRepo.Dimension) -> String {
        switch dimension {
        case .model: return L10n.text("Model", zhHans: "模型")
        case .source: return L10n.text("Source", zhHans: "来源")
        case .project: return L10n.text("Project", zhHans: "项目")
        case .session: return L10n.text("Session", zhHans: "会话")
        }
    }

    private func periodLabel(_ period: Period) -> String {
        switch period {
        case .all: return L10n.text("All time", zhHans: "全部")
        case .last7: return L10n.text("7 days", zhHans: "近 7 天")
        case .last30: return L10n.text("30 days", zhHans: "近 30 天")
        case .last90: return L10n.text("90 days", zhHans: "近 90 天")
        case .custom: return L10n.text("Custom", zhHans: "自定义")
        }
    }

    // MARK: - Summary

    private func summary(_ analytics: AuditAnalytics) -> some View {
        let totals = analytics.totals
        return KnowledgeListContainer {
            HStack(spacing: 0) {
                summaryTile(
                    Self.number(totals.total), L10n.text("operations", zhHans: "次操作"),
                    Self.groupCount(analytics.groups.count, dimension))
                Divider().frame(height: 34)
                summaryTile(
                    Self.number(totals.risk), L10n.text("rule hits", zhHans: "次规则命中"),
                    L10n.format("%@ of operations", zhHans: "占操作的 %@", Self.percent(totals.riskRate)))
                Divider().frame(height: 34)
                summaryTile(
                    Self.number(totals.high), L10n.text("high risk or above", zhHans: "次高危及以上"),
                    nil, tint: totals.high > 0 ? Theme.failureRed : nil)
                Divider().frame(height: 34)
                summaryTile(
                    Self.number(totals.errors), L10n.text("failed", zhHans: "次失败"),
                    totals.errors > 0 ? Self.percent(totals.errorRate) : nil)
            }
            .padding(.vertical, 12)
        }
    }

    private func summaryTile(
        _ value: String, _ unit: String, _ note: String?, tint: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(Theme.font.statNumber(22))
                    .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.primary))
                Text(unit).font(Theme.font.themed(11.5, .medium)).foregroundStyle(.secondary)
            }
            Text(note ?? " ")
                .font(Theme.font.themedMono(10))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.spacing.card)
    }

    // MARK: - Group table

    private func sorted(_ groups: [AuditAnalytics.Group]) -> [AuditAnalytics.Group] {
        switch sort {
        case .total: return groups
        case .riskRate: return groups.sorted { ($0.riskRate, $0.total) > ($1.riskRate, $1.total) }
        case .high: return groups.sorted { ($0.high, $0.total) > ($1.high, $1.total) }
        case .errorRate: return groups.sorted { ($0.errorRate, $0.total) > ($1.errorRate, $1.total) }
        }
    }

    private func groupTable(_ analytics: AuditAnalytics) -> some View {
        let all = sorted(analytics.groups)
        let shown = showsAllGroups ? all : Array(all.prefix(Self.collapsedGroupCount))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text(L10n.format("Operations by %@", zhHans: "按%@看操作构成", Self.label(for: dimension).lowercased()))
                    .font(Theme.font.themed(13, .semibold))
                Spacer(minLength: 8)
                legend(kinds: presentKinds(analytics.totals))
            }
            KnowledgeListContainer {
                VStack(spacing: 0) {
                    tableHeader
                    ForEach(shown) { group in
                        Divider().opacity(0.4)
                        groupRow(group)
                    }
                    if all.count > Self.collapsedGroupCount {
                        Divider().opacity(0.4)
                        Button {
                            showsAllGroups.toggle()
                        } label: {
                            Text(showsAllGroups
                                 ? L10n.text("Show fewer", zhHans: "收起")
                                 : L10n.format("Show all %@", zhHans: "显示全部 %@ 个", String(all.count)))
                                .font(Theme.font.themed(10.5, .medium))
                                .foregroundStyle(Theme.brandFg)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if dimension == .model {
                Text(L10n.text("An operation is attributed to the model call just before it in the same session. When parallel subagents use another model, a few land on the wrong one.", zhHans: "操作按同一会话里紧挨着它的那次模型调用归属。并行子代理用了别的模型时，少量操作会归到另一个模型上。"))
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private enum Column {
        static let total: CGFloat = 86
        static let rate: CGFloat = 58
        static let count: CGFloat = 50
        static let name: CGFloat = 190
    }

    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text(Self.label(for: dimension))
                .frame(width: Column.name, alignment: .leading)
            sortHeader(L10n.text("Operations", zhHans: "操作数"), .total, width: Column.total)
            Text(L10n.text("Mix", zhHans: "构成")).frame(maxWidth: .infinity, alignment: .leading)
            sortHeader(L10n.text("Risk rate", zhHans: "风险率"), .riskRate, width: Column.rate)
            sortHeader(L10n.text("High+", zhHans: "高危+"), .high, width: Column.count)
            sortHeader(L10n.text("Failed", zhHans: "失败率"), .errorRate, width: Column.rate)
        }
        .font(Theme.font.themed(10, .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func sortHeader(_ title: String, _ key: SortKey, width: CGFloat) -> some View {
        Button { sort = key } label: {
            HStack(spacing: 2) {
                Text(title)
                if sort == key {
                    Image(systemName: "chevron.down").font(Theme.font.themed(7, .bold))
                }
            }
            .foregroundStyle(sort == key ? AnyShapeStyle(Theme.brandFg) : AnyShapeStyle(.secondary))
            .frame(width: width, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.format("Sort by %@", zhHans: "按%@排序", title))
    }

    private func groupRow(_ group: AuditAnalytics.Group) -> some View {
        Button { onSelect(dimension, group.key) } label: {
            HStack(spacing: 12) {
                groupName(group)
                    .frame(width: Column.name, alignment: .leading)
                Text(Self.number(group.total))
                    .font(Theme.font.themedMono(11, .medium))
                    .frame(width: Column.total, alignment: .trailing)
                mixBar(group)
                Text(group.risk > 0 ? Self.percent(group.riskRate) : "—")
                    .frame(width: Column.rate, alignment: .trailing)
                Text(group.high > 0 ? Self.number(group.high) : "—")
                    .foregroundStyle(group.high > 0 ? AnyShapeStyle(Theme.failureRed) : AnyShapeStyle(.tertiary))
                    .frame(width: Column.count, alignment: .trailing)
                Text(group.errors > 0 ? Self.percent(group.errorRate) : "—")
                    .frame(width: Column.rate, alignment: .trailing)
            }
            .font(Theme.font.themedMono(10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.text("Show these operations in the log", zhHans: "在流水里查看这些操作"))
    }

    @ViewBuilder
    private func groupName(_ group: AuditAnalytics.Group) -> some View {
        switch dimension {
        case .source:
            if let source = AgentSource(rawValue: group.key) {
                HStack(spacing: 6) {
                    SourceBadge(source: source, size: 12)
                    Text(source.displayName)
                }
                .font(Theme.font.themed(11.5, .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            } else {
                nameText(group.key)
            }
        default:
            nameText(Self.displayName(group.key, dimension: dimension))
                .help(group.key)
        }
    }

    private func nameText(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(11.5, .medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    static func displayName(_ key: String, dimension: AuditRepo.Dimension) -> String {
        switch dimension {
        case .model:
            return key.isEmpty ? L10n.text("Unattributed", zhHans: "未归属") : key
        case .source:
            return AgentSource(rawValue: key)?.displayName ?? key
        case .project:
            guard !key.isEmpty else { return L10n.text("No directory", zhHans: "无工作目录") }
            let name = URL(fileURLWithPath: key).lastPathComponent
            return name.isEmpty ? key : name
        case .session:
            return "#" + key.prefix(8)
        }
    }

    private func presentKinds(_ group: AuditAnalytics.Group) -> [ToolKind] {
        AuditKindPalette.order.filter { (group.byKind[$0] ?? 0) > 0 }
    }

    /// Share of each kind as one bar; hovering lists the numbers
    private func mixBar(_ group: AuditAnalytics.Group) -> some View {
        let kinds = presentKinds(group)
        let total = max(1, group.total)
        return GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(kinds, id: \.self) { kind in
                    Rectangle()
                        .fill(AuditKindPalette.color(kind))
                        .frame(width: geometry.size.width * CGFloat(group.byKind[kind] ?? 0) / CGFloat(total))
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .frame(maxWidth: .infinity)
        .help(kinds.map { kind in
            let count = group.byKind[kind] ?? 0
            return "\(kind.label) \(Self.percent(Double(count) / Double(total))) (\(Self.number(count)))"
        }.joined(separator: " · "))
    }

    private func legend(kinds: [ToolKind]) -> some View {
        HStack(spacing: 9) {
            ForEach(kinds, id: \.self) { kind in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(AuditKindPalette.color(kind))
                        .frame(width: 8, height: 8)
                    Text(kind.label).font(Theme.font.themed(10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Trend

    private func trend(_ analytics: AuditAnalytics) -> some View {
        let kinds = presentKinds(analytics.totals)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Per day", zhHans: "按天")).font(Theme.font.themed(13, .semibold))
            KnowledgeListContainer {
                VStack(alignment: .leading, spacing: 10) {
                    Chart {
                        ForEach(analytics.days) { day in
                            ForEach(kinds, id: \.self) { kind in
                                BarMark(
                                    x: .value("Day", day.date, unit: .day),
                                    y: .value("Operations", day.byKind[kind] ?? 0))
                                    .foregroundStyle(by: .value("Kind", kind.label))
                            }
                        }
                    }
                    .chartForegroundStyleScale(
                        domain: kinds.map(\.label), range: kinds.map(AuditKindPalette.color))
                    .chartLegend(.hidden)
                    .frame(height: 150)
                    if analytics.totals.risk > 0 {
                        Text(L10n.text("Rule hits", zhHans: "规则命中"))
                            .font(Theme.font.themed(10, .medium))
                            .foregroundStyle(.secondary)
                        Chart(analytics.days) { day in
                            BarMark(
                                x: .value("Day", day.date, unit: .day),
                                y: .value("Hits", day.risk))
                                .foregroundStyle(Theme.failureRed.opacity(0.8))
                        }
                        .frame(height: 56)
                    }
                }
                .padding(Theme.spacing.card)
            }
        }
    }

    // MARK: - Risk

    private func risk(_ analytics: AuditAnalytics) -> some View {
        let rules = RiskRuleEngine.current
        let top = analytics.rules.first?.count ?? 1
        let categories = RiskRule.Category.allCases.filter {
            (analytics.totals.riskByCategory[$0] ?? 0) > 0
        }
        let risky = analytics.groups.filter { $0.risk > 0 }.prefix(6)
        return VStack(alignment: .leading, spacing: 8) {
            Text(L10n.text("Rules that fired", zhHans: "命中的规则")).font(Theme.font.themed(13, .semibold))
            KnowledgeListContainer {
                VStack(spacing: 0) {
                    ForEach(Array(analytics.rules.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { Divider().opacity(0.4) }
                        let rule = rules.rule(id: entry.label)
                        rankedRow(
                            title: rule?.title.text ?? entry.label, count: entry.count, top: top,
                            tint: rule.map { Theme.riskColor($0.level) } ?? Theme.disabledGray,
                            tag: rule?.level.label, barWidth: 160)
                    }
                }
            }
            if !categories.isEmpty, !risky.isEmpty {
                Text(L10n.format("Rule hits by %@ and kind of rule", zhHans: "各%@命中的规则类别", Self.label(for: dimension).lowercased()))
                    .font(Theme.font.themed(13, .semibold))
                    .padding(.top, 6)
                KnowledgeListContainer {
                    categoryMatrix(groups: Array(risky), categories: categories)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Which group trips which kind of rule: one row per group, one column per rule category
    private func categoryMatrix(
        groups: [AuditAnalytics.Group], categories: [RiskRule.Category]
    ) -> some View {
        let peak = max(1, groups.flatMap { group in categories.map { group.riskByCategory[$0] ?? 0 } }.max() ?? 1)
        return Grid(alignment: .center, horizontalSpacing: 6, verticalSpacing: 6) {
            GridRow {
                Text(Self.label(for: dimension))
                    .frame(width: 170, alignment: .leading)
                    .gridColumnAlignment(.leading)
                ForEach(categories, id: \.self) { category in
                    Text(category.label)
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .font(Theme.font.themed(9.5, .medium))
            .foregroundStyle(.secondary)
            ForEach(groups) { group in
                GridRow {
                    Text(Self.displayName(group.key, dimension: dimension))
                        .font(Theme.font.themed(10.5, .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 170, alignment: .leading)
                    ForEach(categories, id: \.self) { category in
                        let count = group.riskByCategory[category] ?? 0
                        Text(count > 0 ? Self.number(count) : "·")
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(count > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Theme.failureRed.opacity(
                                        count > 0 ? 0.08 + 0.30 * Double(count) / Double(peak) : 0)))
                    }
                }
            }
        }
        .padding(12)
    }

    // MARK: - Rankings

    private func rankings(_ analytics: AuditAnalytics) -> some View {
        let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
            rankingCard(
                L10n.text("Most run commands", zhHans: "最常执行的命令"), analytics.commands,
                note: analytics.commandsParsed >= AuditAnalyticsBuilder.parsedCommandLimit
                    ? L10n.format("From the latest %@ commands", zhHans: "取最近 %@ 条命令", Self.number(analytics.commandsParsed))
                    : nil)
            rankingCard(L10n.text("Most called MCP tools", zhHans: "调用最多的 MCP 工具"), analytics.mcpTools)
            rankingCard(L10n.text("Most contacted hosts", zhHans: "访问最多的域名"), analytics.domains)
            rankingCard(L10n.text("Most edited directories", zhHans: "改动最多的目录"), analytics.directories)
        }
    }

    private func rankingCard(
        _ title: String, _ entries: [AuditAnalytics.Ranked], note: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title).font(Theme.font.themed(13, .semibold))
                if let note {
                    Text(note).font(Theme.font.caption).foregroundStyle(.tertiary)
                }
            }
            KnowledgeListContainer {
                if entries.isEmpty {
                    Text(L10n.text("Nothing in this period", zhHans: "这段时间没有"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().opacity(0.4) }
                            rankedRow(
                                title: entry.label, count: entry.count,
                                top: entries.first?.count ?? 1, tint: Theme.brand, mono: true)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// One ranked line: label, a bar relative to the first entry, and the count
    private func rankedRow(
        title: String, count: Int, top: Int, tint: Color, tag: String? = nil, mono: Bool = false,
        barWidth: CGFloat = 70
    ) -> some View {
        HStack(spacing: 8) {
            if let tag { TagChip(tag, tint: tint) }
            Text(title)
                .font(mono ? Theme.font.themedMono(10.5) : Theme.font.themed(11))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
            Spacer(minLength: 8)
            Capsule()
                .fill(tint.opacity(0.75))
                .frame(width: max(3, barWidth * CGFloat(count) / CGFloat(max(1, top))), height: 5)
                .frame(width: barWidth, alignment: .trailing)
            Text(Self.number(count))
                .font(Theme.font.themedMono(10.5, .medium))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Formatting

    static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }

    /// One decimal below 10%, none above
    static func percent(_ ratio: Double) -> String {
        let value = ratio * 100
        if value > 0, value < 0.05 { return "<0.1%" }
        return value > 0 && value < 10 ? String(format: "%.1f%%", value) : String(format: "%.0f%%", value)
    }
}
