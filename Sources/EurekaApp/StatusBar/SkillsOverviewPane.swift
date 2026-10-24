import Charts
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// The Skills module overview: what the right pane shows before a skill is picked. Four blocks,
/// the same shape every knowledge module will use — a row of numbers, one trend chart, the things
/// that need attention (each with a button), and a ranking whose rows open the item.
struct SkillsOverviewPane: View {
    /// Every group (unfiltered), so the numbers describe the whole inventory.
    let groups: [SkillGroup]
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    /// Narrow (single-pane) mode: shows a back button in the header.
    var onBack: (() -> Void)? = nil
    let onSelect: (SkillGroup) -> Void

    @State private var fillNote: String?
    @State private var filling: AgentSource?

    private var hard: Bool { ThemeStyle.current.isHardEdged }
    private static let recentWindow: TimeInterval = 30 * 86_400

    // MARK: - Derived numbers

    private var enabledCount: Int { groups.filter { $0.enabledCount > 0 }.count }
    private var disabledCount: Int { groups.filter(\.isAllDisabled).count }
    private var multiToolCount: Int { groups.filter { $0.sources.count > 1 || $0.copies.count > 1 }.count }
    private var recentlyUsed: [SkillGroup] {
        let cutoff = Date().addingTimeInterval(-Self.recentWindow)
        return groups.filter { $0.usageCount > 0 && ($0.lastUsedAt ?? .distantPast) >= cutoff }
    }
    /// Enabled but never recorded in a call. Sources that do not record skill calls at all are
    /// left out, otherwise every one of their skills would look idle.
    private var neverUsed: [SkillGroup] {
        let recording = Set(usageService.skillStats.map(\.source))
        return groups
            .filter { $0.usageCount == 0 && !$0.isAllDisabled && $0.sources.contains { recording.contains($0) } }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }
    private var sourceCount: Int { Set(groups.flatMap(\.sources)).count }
    private var dailyTotals: [UsageService.SkillDayCount] { usageService.skillDailyTotals }
    private var totalCalls30d: Int { dailyTotals.reduce(0) { $0 + $1.count } }

    /// Top 10 of the 30-day ranking, matched back to groups so a row can open the skill. A group
    /// matches only when it holds a copy for the recording tool: the same name installed for
    /// another tool is a different skill (usage is keyed `source:name`, see `SkillGrouping`).
    private var top: [(rank: Int, group: SkillGroup?, stat: ToolCallsRepo.SkillUsageStat)] {
        let byKey = Dictionary(groups.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var seen = Set<String>()
        var rows: [(Int, SkillGroup?, ToolCallsRepo.SkillUsageStat)] = []
        for stat in usageService.skillRanking {
            let key = SkillGrouping.usageKey(source: stat.source, name: stat.name)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            let group = byKey[SkillMemoryIndexer.normalizeSkillName(stat.name)]
                .flatMap { $0.sources.contains(stat.source) ? $0 : nil }
            rows.append((rows.count + 1, group, stat))
            if rows.count == 10 { break }
        }
        return rows.map { (rank: $0.0, group: $0.1, stat: $0.2) }
    }

    // MARK: - Body

    var body: some View {
        KnowledgePane {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    numbers
                    trendSection
                    attentionSection
                    topSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: load)
        .onChange(of: service.lastScanAt) { _, _ in load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(Theme.font.themed(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                                .fill(Theme.surfaceSecondary))
                }
                .buttonStyle(.plain)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.text("Skills overview", zhHans: "技能概览"))
                    .font(Theme.font.themed(17, .semibold))
                Text(L10n.format("%@ skills across %@ tools · %@ calls in the last 30 days",
                                 zhHans: "%@ 个技能，装在 %@ 个工具里 · 近 30 天调用 %@ 次",
                                 String(groups.count), String(sourceCount), String(totalCalls30d)))
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Numbers

    private var numbers: some View {
        HStack(spacing: 10) {
            numberTile(String(groups.count), L10n.text("Skills", zhHans: "技能"))
            numberTile(String(enabledCount), L10n.text("Enabled", zhHans: "已启用"))
            numberTile(String(disabledCount), L10n.text("Disabled", zhHans: "已停用"))
            numberTile(String(multiToolCount), L10n.text("In several tools", zhHans: "装在多个工具"))
            numberTile(String(recentlyUsed.count), L10n.text("Used in 30 days", zhHans: "30 天内用过"))
        }
    }

    private func numberTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.font.statNumber(20))
            Text(label).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.surfaceSecondary))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: hard ? Theme.cardBorderWidth : 0.5))
    }

    // MARK: - Trend

    private var trendSection: some View {
        section(L10n.text("Calls in the last 30 days", zhHans: "近 30 天调用")) {
            if dailyTotals.isEmpty {
                Text(L10n.text("No skill calls recorded in the last 30 days.", zhHans: "近 30 天没有技能调用记录。"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Chart(dailyTotals) { point in
                    BarMark(
                        x: .value(L10n.text("Date", zhHans: "日期"), point.day, unit: .day),
                        y: .value(L10n.text("Calls", zhHans: "次数"), point.count))
                        .foregroundStyle(Theme.brand)
                        .cornerRadius(hard ? 0 : 2)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 96)
                HStack {
                    Text(L10n.text("30 days ago", zhHans: "30 天前"))
                    Spacer()
                    Text(L10n.text("calls per day, all skills", zhHans: "所有技能每天的调用次数"))
                    Spacer()
                    Text(L10n.text("today", zhHans: "今天"))
                }
                .font(Theme.font.themedMono(9.5))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Needs attention

    private var attentionSection: some View {
        let gaps = service.consistencyReport.skillGaps
        let idle = neverUsed
        return section(L10n.text("Needs attention", zhHans: "需要处理")) {
            if gaps.isEmpty && idle.isEmpty {
                HStack(spacing: 7) {
                    Circle().fill(Theme.enabledGreen).frame(width: 8, height: 8)
                    Text(L10n.text("Nothing waiting: every tool has its skills and every enabled skill has been used.",
                                   zhHans: "没有待处理的事：各工具的技能都齐，启用的技能也都用过。"))
                        .font(Theme.font.themed(12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            ForEach(gaps) { gap in
                attentionRow(
                    icon: "exclamationmark.triangle.fill",
                    title: L10n.format("%@ is missing %@ skills the other tools have",
                                       zhHans: "%@ 缺 %@ 个其他工具都有的技能",
                                       gap.source.displayName, String(gap.missing.count)),
                    detail: gap.missing.prefix(4).joined(separator: ", ") + (gap.missing.count > 4 ? " …" : ""),
                    button: filling == gap.source
                        ? L10n.text("Copying…", zhHans: "正在复制…")
                        : L10n.text("Copy them over", zhHans: "补齐")) {
                    fill(gap)
                }
            }
            if !idle.isEmpty {
                attentionRow(
                    icon: "moon.zzz",
                    title: L10n.format("%@ enabled skills have never been called", zhHans: "%@ 个已启用的技能从未被调用",
                                       String(idle.count)),
                    detail: idle.prefix(5).map(\.name).joined(separator: ", ") + (idle.count > 5 ? " …" : ""),
                    button: nil, action: nil)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(idle.prefix(8)) { group in
                        Button { onSelect(group) } label: {
                            HStack(spacing: 5) {
                                SourceBadge(source: group.primary.source, size: 12)
                                Text(group.name).font(Theme.font.themed(11))
                            }
                            .foregroundStyle(.primary)
                            .modifier(PopupButtonChrome(height: 24, horizontalPadding: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let fillNote {
                Text(fillNote).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func attentionRow(icon: String, title: String, detail: String, button: String?,
                              action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Theme.font.themed(12))
                .foregroundStyle(Theme.goldFg)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font.themed(12.5, .medium))
                Text(detail).font(Theme.font.themed(11)).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let button, let action {
                PaneButton(button, small: true, action: action)
                    .disabled(filling != nil)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Top 10

    private var topSection: some View {
        let rows = top
        let peak = max(1, rows.first?.stat.count ?? 1)
        return section(L10n.text("Most used in 30 days", zhHans: "近 30 天最常用")) {
            if rows.isEmpty {
                Text(L10n.text("No calls yet. Tools that do not record skill calls never appear here.",
                               zhHans: "还没有调用记录。不记录技能调用的工具不会出现在这里。"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(rows, id: \.rank) { row in
                Button {
                    if let group = row.group { onSelect(group) }
                } label: {
                    HStack(spacing: 10) {
                        Text(String(row.rank))
                            .font(Theme.font.themedMono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 18, alignment: .trailing)
                        SourceLogoTile(source: row.stat.source, size: 22)
                        Text(row.group?.name ?? row.stat.name)
                            .font(Theme.font.themed(12.5, .medium))
                            .lineLimit(1)
                            .frame(width: 190, alignment: .leading)
                        Capsule().fill(Theme.surfaceTertiary)
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule().fill(Theme.brand)
                                        .frame(width: max(4, geo.size.width * CGFloat(row.stat.count) / CGFloat(peak)))
                                }
                            }
                        Text(L10n.format("%@ times", zhHans: "%@ 次", String(row.stat.count)))
                            .font(Theme.font.themedMono(11.5))
                            .frame(width: 56, alignment: .trailing)
                    }
                    .foregroundStyle(row.group == nil ? Theme.textTertiary : .primary)
                    .frame(height: 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(row.group == nil
                    ? L10n.text("Called, but not in any scanned skills folder (a plugin skill, or removed)",
                                zhHans: "有调用记录，但不在扫描到的技能目录里（插件自带，或已删除）")
                    : L10n.text("Open this skill", zhHans: "打开这个技能"))
            }
        }
    }

    // MARK: - Building blocks

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(title).font(Theme.font.themed(12.5, .semibold)).padding(.top, 4)
            content()
        }
    }

    private func load() {
        let now = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
        usageService.loadSkillDailyTotals(from: from, to: now)
    }

    private func fill(_ gap: ConsistencyChecker.Report.SkillSourceGap) {
        filling = gap.source
        service.propagateAll(names: gap.missing, to: gap.source) { succeeded, failures in
            filling = nil
            fillNote = failures.isEmpty
                ? L10n.format("Copied %@ skills to %@", zhHans: "已把 %@ 个技能复制到 %@",
                              String(succeeded), gap.source.displayName)
                : L10n.format("Copied %@, %@ failed: %@", zhHans: "复制了 %@ 个，%@ 个失败：%@",
                              String(succeeded), String(failures.count), failures.first ?? "")
        }
    }
}
