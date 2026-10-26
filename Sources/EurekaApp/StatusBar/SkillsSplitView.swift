import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// Skills on the shared shell: a grouped list on the left and the selected skill's
/// detail on the right. Below `splitThreshold` of width the detail is pushed over the
/// list instead (the window's minimum content width is ~675pt).
///
/// One row = one `SkillGroup` (every copy of a skill across tools and projects); the
/// detail pane lists the copies with their own switches.
struct SkillsSplitView: View {
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    var sessionBrowser: SessionBrowserService? = nil
    /// Offscreen renderer only: start with this group selected / the detail pushed.
    var initialSelectionKey: String? = nil
    var initialPushDetail = false

    @State private var selectedKey: String?
    /// When a deep link lands on a specific copy (`focusPath`), the detail shows that
    /// copy's SKILL.md instead of the group's primary.
    @State private var focusedCopyPath: String?
    @State private var selectedSource: AgentSource?
    @State private var detailPushed = false
    @State private var deleting: SkillEntry?
    @State private var seeded = false

    static let listWidth: CGFloat = 396
    // The detail pane needs ~480pt to read comfortably: 396 (list) + 12 (gap) + 480.
    static let splitThreshold: CGFloat = 900

    // MARK: - Derived data

    /// Usage keyed by source + normalized name; duplicate raw names add up.
    private var usage: [String: SkillUsage] {
        var map: [String: SkillUsage] = [:]
        for stat in usageService.skillStats {
            let key = SkillGrouping.usageKey(source: stat.source, name: stat.name)
            var merged = map[key] ?? SkillUsage(count: 0, lastTs: nil)
            merged.count += stat.count
            if let ts = stat.lastTs, merged.lastTs.map({ ts > $0 }) ?? true { merged.lastTs = ts }
            map[key] = merged
        }
        return map
    }

    private var allGroups: [SkillGroup] { SkillGrouping.groups(service.skills, usage: usage) }

    private var groups: [SkillGroup] {
        guard let source = selectedSource else { return allGroups }
        return allGroups.filter { $0.sources.contains(source) }
    }

    private var sections: [SkillSection] { SkillGrouping.sections(groups, now: Date()) }
    private var orderedGroups: [SkillGroup] { sections.flatMap(\.groups) }

    /// nil = the module overview (the default landing); a key = that skill's detail.
    private var selectedGroup: SkillGroup? {
        orderedGroups.first { $0.key == selectedKey }
    }

    /// Sources with at least one copy, most copies first (filter chips).
    private var sourceCounts: [(source: AgentSource, count: Int)] {
        var counts: [AgentSource: Int] = [:]
        for skill in service.skills { counts[skill.source, default: 0] += 1 }
        return AgentSource.allCases
            .compactMap { source in counts[source].map { (source, $0) } }
            .sorted { $0.count != $1.count ? $0.count > $1.count : false }
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.splitThreshold
            Group {
                if wide {
                    HStack(spacing: 12) {
                        listPane.frame(width: Self.listWidth)
                        detailPane(wide: true).frame(maxWidth: .infinity)
                    }
                } else if detailPushed {
                    detailPane(wide: false)
                } else {
                    listPane
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.surfaceSecondary)
        .onAppear {
            service.refresh()
            usageService.loadSkillStats()
            // 30-day ranking feeds the overview's top list.
            let now = Date()
            usageService.loadSkillRanking(
                source: nil, from: Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now, to: now)
            if !seeded {
                seeded = true
                if let key = initialSelectionKey { selectedKey = key }
                detailPushed = initialPushDetail
            }
            consumeFocus()
        }
        .onChange(of: service.focusPath) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
        .confirmationDialog(
            deleting.map {
                L10n.format(
                    "Delete “%@”? The skill folder moves to the Trash and can be restored.",
                    zhHans: "删除「%@」？技能目录会移入废纸篓，可恢复。", $0.name)
            } ?? "",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                if let entry = deleting { service.deleteSkill(entry) }
                deleting = nil
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) { deleting = nil }
        }
    }

    // MARK: - List pane

    private var listPane: some View {
        KnowledgePane {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(countLine)
                        .font(Theme.font.themed(11))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    SourceFilterMenu(
                        selected: $selectedSource,
                        allLabel: L10n.text("All", zhHans: "全部"), allIcon: "sparkles",
                        totalCount: service.skills.count,
                        sources: sourceCounts.map(\.source),
                        count: { source in sourceCounts.first { $0.source == source }?.count ?? 0 })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 9)
                Divider()
                if orderedGroups.isEmpty {
                    emptyList
                } else {
                    rows
                }
                Divider()
                HStack(spacing: 8) {
                    ScanStatusLabel(
                        scanning: service.scanning, phase: service.scanPhase,
                        lastScanAt: service.lastScanAt)
                    Spacer(minLength: 0)
                    RefreshButton(help: L10n.text("Rescan", zhHans: "重新扫描")) {
                        service.refresh(force: true)
                        usageService.loadSkillStats()
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
    }

    private var countLine: String {
        if service.isSearching {
            return L10n.format("%@ matches", zhHans: "%@ 个匹配", String(orderedGroups.count))
        }
        let enabled = allGroups.filter { $0.enabledCount > 0 }.count
        let multi = allGroups.filter { $0.copies.count > 1 }.count
        return L10n.format(
            "%@ skills · %@ enabled · %@ installed in several tools",
            zhHans: "%@ 个技能 · %@ 个已启用 · %@ 个装在多个工具里",
            String(allGroups.count), String(enabled), String(multi))
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    OverviewListRow(isSelected: selectedKey == nil) { selectOverview() }
                        .id("__overview__")
                    ForEach(sections) { section in
                        sectionHeader(section)
                        ForEach(section.groups) { group in
                            SkillGroupRow(
                                group: group,
                                isSelected: selectedGroup?.key == group.key,
                                onSelect: { select(group) },
                                onToggle: { copy in service.setSkillEnabled(copy, !copy.enabled) })
                                .id(group.key)
                        }
                    }
                }
                .padding(6)
            }
            .focusable()
            .onMoveCommand(perform: move)
            .onChange(of: selectedKey) { _, key in
                guard let key else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ section: SkillSection) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(sectionTitle(section.kind))
                .font(Theme.font.themed(11, .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text(String(section.groups.count))
                .font(Theme.font.themedMono(10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func sectionTitle(_ kind: SkillSectionKind) -> String {
        switch kind {
        case .frequent: return L10n.text("Frequently used", zhHans: "常用")
        case .enabled: return L10n.text("Enabled", zhHans: "已启用")
        case .disabled: return L10n.text("Disabled", zhHans: "已停用")
        }
    }

    private var emptyList: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "sparkles")
                .font(Theme.font.themed(22))
                .foregroundStyle(Theme.textTertiary)
            Text(service.isSearching
                ? L10n.text("No skill matches the search", zhHans: "没有匹配的技能")
                : L10n.text("No skills found yet", zhHans: "还没有扫描到技能"))
                .font(Theme.font.themed(12))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Detail pane

    @ViewBuilder
    private func detailPane(wide: Bool) -> some View {
        if let group = selectedGroup {
            SkillDetailPane(
                group: group,
                focusedCopyPath: focusedCopyPath,
                service: service, usageService: usageService,
                sessionBrowser: sessionBrowser,
                onBack: wide ? nil : { withAnimation(.easeOut(duration: 0.15)) { detailPushed = false } },
                onDelete: { deleting = $0 })
                .id(group.key + "|" + (focusedCopyPath ?? ""))
        } else {
            SkillsOverviewPane(
                groups: allGroups, service: service, usageService: usageService,
                onBack: wide ? nil : { withAnimation(.easeOut(duration: 0.15)) { detailPushed = false } },
                onSelect: { select($0) })
        }
    }

    // MARK: - Selection

    private func select(_ group: SkillGroup) {
        focusedCopyPath = nil
        withAnimation(.easeOut(duration: 0.15)) {
            selectedKey = group.key
            detailPushed = true
        }
    }

    private func selectOverview() {
        focusedCopyPath = nil
        withAnimation(.easeOut(duration: 0.15)) {
            selectedKey = nil
            detailPushed = true
        }
    }

    /// ↑ / ↓ walk the overview row and then the groups in list order.
    private func move(_ direction: MoveCommandDirection) {
        let list = orderedGroups
        let current = list.firstIndex { $0.key == selectedKey }.map { $0 + 1 } ?? 0
        let next: Int
        switch direction {
        case .up: next = max(0, current - 1)
        case .down: next = min(list.count, current + 1)
        default: return
        }
        focusedCopyPath = nil
        selectedKey = next == 0 ? nil : list[next - 1].key
    }

    /// Deep-link landing (⌘K, "related skill" jumps): select the group that owns the
    /// path and show that copy. Uses the full inventory, not the search-filtered view.
    private func consumeFocus() {
        guard let path = service.focusPath else { return }
        guard let entry = service.knowledgeSnapshot().skills.first(where: { $0.path == path })
        else { return }
        selectedSource = nil
        focusedCopyPath = path
        withAnimation(.easeOut(duration: 0.15)) {
            selectedKey = SkillMemoryIndexer.normalizeSkillName(entry.name)
            detailPushed = true
        }
        service.focusPath = nil
    }
}

// MARK: - Row

struct SkillGroupRow: View {
    let group: SkillGroup
    let isSelected: Bool
    let onSelect: () -> Void
    let onToggle: (SkillEntry) -> Void

    @State private var hovering = false

    private var hard: Bool { ThemeStyle.current.isHardEdged }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(group.name)
                            .font(Theme.font.themed(12.5, .medium))
                            .foregroundStyle(nameColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let project = group.projectName {
                            TagChip(L10n.format("Only %@", zhHans: "仅限 %@", project), neutral: true)
                        }
                    }
                    Text(meta)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(metaColor)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing
            }
            .opacity(group.isAllDisabled ? 0.55 : 1)
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(rowFill))
            .overlay(
                Group {
                    if isSelected, let outline = Theme.controlOutline {
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(outline.color, lineWidth: outline.width)
                    }
                })
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var tile: some View {
        ZStack(alignment: .bottomTrailing) {
            SourceLogoTile(source: group.primary.source, size: 28)
            if group.sources.count > 1 {
                SourceBadge(source: group.sources[1], size: 11)
                    .padding(2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: hard ? 1.5 : 0.5))
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var trailing: some View {
        if group.copies.count == 1 {
            MiniSwitch(isOn: group.primary.enabled) { onToggle(group.primary) }
        } else {
            Text("\(group.enabledCount)/\(group.copies.count)")
                .font(Theme.font.themedMono(11))
                .foregroundStyle(metaColor)
                .help(L10n.format("%@ of %@ copies enabled", zhHans: "%@ 份里 %@ 份已启用",
                                  String(group.copies.count), String(group.enabledCount)))
        }
    }

    private var meta: String {
        var parts: [String] = [toolLabel]
        if group.usageCount > 0 {
            parts.append(L10n.format("used %@ times", zhHans: "用过 %@ 次", String(group.usageCount)))
            if let last = group.lastUsedAt {
                parts.append(relativeFormatter.localizedString(for: last, relativeTo: Date()))
            }
        } else {
            parts.append(L10n.text("not used yet", zhHans: "还没用过"))
        }
        return parts.joined(separator: " · ")
    }

    private var toolLabel: String {
        let first = group.primary.source.displayName
        if group.sources.count > 1 {
        // English counts the others ("+ 3 more"); Chinese counts the total (all N tools).
            return L10n.format("%1$@ + %2$@ more tools", zhHans: "%1$@ 等 %3$@ 个工具",
                               first, String(group.sources.count - 1), String(group.sources.count))
        }
        if group.copies.count > 1 {
            return L10n.format("%2$@ copies in %1$@", zhHans: "%1$@ 里有 %2$@ 份", first, String(group.copies.count))
        }
        return first
    }

    private var rowFill: Color {
        if isSelected { return hard ? Theme.brand : Theme.brandFill(0.14) }
        return hovering ? Color.primary.opacity(0.04) : .clear
    }

    private var nameColor: Color { isSelected && hard ? Theme.onBrand : .primary }
    private var metaColor: Color { isSelected && hard ? Theme.onBrand.opacity(0.75) : Theme.textSecondary }
}

// MARK: - Top-bar actions (New skill ▾ · ⋯)

/// The hub's trailing controls for Skills: a primary "New skill" menu (one entry per
/// tool) with its name prompt, and an overflow menu for rescanning.
struct SkillsToolbarActions: View {
    @ObservedObject var service: SkillMemoryService
    /// Narrow bar: the primary button shows only the plus.
    var compact = false

    @State private var creating: AgentSource?
    @State private var newName = ""
    @State private var showNew = false
    @State private var showMore = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                showNew.toggle()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(Theme.font.themed(11, .bold))
                    if !compact {
                        Text(L10n.text("New skill", zhHans: "新建技能"))
                            .font(Theme.font.themed(12, .medium))
                            .fixedSize()
                    }
                }
                .foregroundStyle(Theme.onBrand)
                .padding(.horizontal, compact ? 8 : 11)
                .frame(height: 28)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                        .fill(Theme.brand)
                        .themeControlShadow())
                .overlay(
                    Group {
                        if let outline = Theme.controlOutline {
                            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                                .strokeBorder(outline.color, lineWidth: outline.width)
                        }
                    })
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
            }
            .buttonStyle(.plain)
            .help(L10n.text("New skill", zhHans: "新建技能"))
            .themedPopup(isPresented: $showNew, alignment: .trailing) {
                PopupList(title: L10n.text("Create a skill for", zhHans: "给哪个工具新建技能")) {
                    ForEach(AgentSource.allCases, id: \.self) { source in
                        PopupRow(source.displayName, leading: { SourceBadge(source: source, size: 14) }) {
                            showNew = false
                            creating = source
                        }
                    }
                }
            }

            Button {
                showMore.toggle()
            } label: {
                Image(systemName: "ellipsis")
                    .font(Theme.font.themed(12, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .modifier(PopupButtonChrome(height: 28, horizontalPadding: 8))
            }
            .buttonStyle(.plain)
            .help(L10n.text("More", zhHans: "更多"))
            .themedPopup(isPresented: $showMore, alignment: .trailing) {
                PopupList {
                    PopupRow(L10n.text("Rescan skills", zhHans: "重新扫描技能"), systemImage: "arrow.clockwise") {
                        showMore = false
                        service.refresh(force: true)
                    }
                }
            }
        }
        .alert(
            L10n.format("New %@ skill", zhHans: "新建 %@ 技能", creating?.displayName ?? ""),
            isPresented: Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
        ) {
            TextField(L10n.text("Name", zhHans: "名称"), text: $newName)
            Button(L10n.text("Create", zhHans: "创建")) {
                if let source = creating, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    service.createSkill(source: source, name: newName)
                }
                newName = ""
                creating = nil
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {
                newName = ""
                creating = nil
            }
        }
    }
}

// MARK: - Overview row (pinned above the sections)

/// First row of the list: the module overview. Selected when nothing else is.
struct OverviewListRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false
    private var hard: Bool { ThemeStyle.current.isHardEdged }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                    .fill(isSelected && !hard ? Theme.brand : Theme.tileBackground)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                            .strokeBorder(Theme.tileBorder, lineWidth: hard ? Theme.cardBorderWidth : 0.5))
                    .overlay(
                        Image(systemName: "chart.bar.xaxis")
                            .font(Theme.font.themed(13, .semibold))
                            .foregroundStyle(isSelected && !hard ? Theme.onBrand : Theme.textSecondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Overview", zhHans: "概览"))
                        .font(Theme.font.themed(12.5, .medium))
                        .foregroundStyle(isSelected && hard ? Theme.onBrand : .primary)
                    Text(L10n.text("Numbers, 30-day trend, what needs attention", zhHans: "数字、30 天趋势、需要处理的事"))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(isSelected && hard ? Theme.onBrand.opacity(0.75) : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(isSelected ? (hard ? Theme.brand : Theme.brandFill(0.14))
                        : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay(
                Group {
                    if isSelected, let outline = Theme.controlOutline {
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(outline.color, lineWidth: outline.width)
                    }
                })
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
