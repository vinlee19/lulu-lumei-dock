import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// MCP tab: cross-source server management (view / create / install across agents / delete).
///
/// Structure lines up item by item with the other knowledge tabs: header (search + "+" menu +
/// scan status + refresh + layout toggle) → `StatOverviewCard` → `SourceFilterBar` →
/// `KnowledgeRow`/`KnowledgeCard` → slide-in detail / form.
/// One row = one config location (same shape as Skills: a server configured in 2 sources is
/// 2 rows); the detail page aggregates by name and shows a cross-source install matrix.
/// Secrets red line: list / detail only show env/headers **key names**; full values only pass
/// through memory between two local config files during install / propagation (see the
/// MCPService / MCPServerEditor header comments).
struct MCPView: View {
    @ObservedObject var service: MCPService
    /// MCP call stats (kind='mcp' tool_calls aggregated by server; used for idle detection)
    @ObservedObject var usageService: UsageService

    /// Slide-in detail (aggregated by server name)
    @State private var detailName: String?
    /// Slide-in form (create / import pasted JSON)
    @State private var formTarget: MCPFormTarget?
    /// Source filter (nil = all)
    @State private var selectedSource: AgentSource?
    /// List / icon grid
    @State private var layout: KnowledgeLayout = .list
    /// Config location pending delete confirmation
    @State private var deletingEntry: MCPServerEntry?
    /// Same-name server groups the user expanded in list mode (keys are lowercased names)
    @State private var expandedGroups: Set<String> = []

    /// Offscreen render / preview only: initial layout / detail / form (during interaction these
    /// are driven by the user)
    init(service: MCPService, usageService: UsageService,
         initialLayout: KnowledgeLayout = .list,
         initialDetailName: String? = nil, initialFormTarget: MCPFormTarget? = nil) {
        self._service = ObservedObject(wrappedValue: service)
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._layout = State(initialValue: initialLayout)
        self._detailName = State(initialValue: initialDetailName)
        self._formTarget = State(initialValue: initialFormTarget)
    }

    private let gridColumns = KnowledgeGrid.columns

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= SkillsSplitView.splitThreshold
            Group {
                if let target = formTarget {
                    MCPServerFormView(
                        service: service, target: target,
                        onBack: { withAnimation(.easeOut(duration: 0.15)) { formTarget = nil } })
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else if wide {
                    splitLayout
                } else if let name = detailName {
                    detail(name, inSplit: false)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    VStack(spacing: 0) {
                        header(inSplit: false)
                        Divider()
                        content
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear {
            service.refresh()
            usageService.loadMCPStats()
            usageService.loadMCPOverview()
        }
        .themedConfirm(
            deletingEntry.map {
                L10n.format("From %@, remove server “%@”? A .bak.eureka backup is kept before writing.", zhHans: "从 %@ 移除 server「%@」？写前会留 .bak.eureka 备份。", String($0.source.displayName), String($0.name))
            } ?? "",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }),
            confirm: L10n.text("Remove", zhHans: "移除"), destructive: true
        ) {
            if let entry = deletingEntry { service.remove(entry) }
        }
    }

    /// In the split layout the list stays visible, so the pane needs no way back
    private func detail(_ name: String, inSplit: Bool) -> some View {
        MCPDetailView(
            service: service, usage: usageService, serverName: name,
            onBack: inSplit ? nil : { withAnimation(.easeOut(duration: 0.15)) { detailName = nil } },
            onDeleteEntry: { deletingEntry = $0 },
            onEdit: { entry in
                withAnimation(.easeOut(duration: 0.15)) {
                    formTarget = MCPFormTarget(
                        id: "edit:\(entry.id)", mode: .form, editing: entry)
                }
            },
            onEditCredentials: { entry in
                withAnimation(.easeOut(duration: 0.15)) {
                    formTarget = MCPFormTarget(
                        id: "edit:\(entry.id)", mode: .form, editing: entry,
                        expandCredentials: true)
                }
            })
    }

    // MARK: - Wide layout: server list + overview / detail (the Skills shell's shape)

    private var splitLayout: some View {
        VStack(spacing: 0) {
            header(inSplit: true)
            Divider()
            HStack(spacing: 12) {
                KnowledgePane { splitList }
                    .frame(width: SkillsSplitView.listWidth)
                KnowledgePane {
                    if let name = detailName {
                        detail(name, inSplit: true).id(name)
                    } else {
                        MCPOverviewPane(service: service, usageService: usageService) { name in
                            withAnimation(.easeOut(duration: 0.15)) { detailName = name }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .background(Theme.surfaceSecondary)
    }

    private var splitList: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.format("%@ servers · %@ config locations", zhHans: "%@ 个 server · %@ 处配置",
                                 String(dedupedCount), String(totalCount)))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(Theme.textSecondary)
                SourceFilterMenu(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: ToolKind.mcp.icon,
                    totalCount: totalCount,
                    sources: availableSources,
                    count: { count(for: $0) })
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    OverviewListRow(isSelected: detailName == nil) {
                        withAnimation(.easeOut(duration: 0.15)) { detailName = nil }
                    }
                    ForEach(groupedEntries, id: \.key) { group in
                        MCPServerListRow(
                            entries: group.entries, service: service,
                            calls30: usageService.mcpOverview?.serverCalls[group.key] ?? 0,
                            isSelected: detailName?.lowercased() == group.key,
                            onSelect: {
                                withAnimation(.easeOut(duration: 0.15)) { detailName = group.entries[0].name }
                            })
                    }
                    if filteredEntries.isEmpty {
                        emptyState.padding(.top, 30)
                    }
                }
                .padding(6)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                probeBar
                if let error = service.lastError {
                    Text(error)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(Theme.goldFg)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Top bar (byte-for-byte identical to the family)

    /// No page title: the hub's type switcher names the page, and search sits where every hub
    /// page puts it. In the split layout the list has one layout only, so the toggle goes too.
    private func header(inSplit: Bool) -> some View {
        HStack(spacing: 12) {
            SearchField(
                placeholder: L10n.text("Search MCP servers", zhHans: "搜索 MCP server"), text: $service.searchText,
                scanning: service.scanning, resultCount: totalCount,
                maxWidth: KnowledgeHubView.searchWidth)
                .frame(width: KnowledgeHubView.searchWidth)
            Spacer(minLength: 12)
            createButton
            ScanStatusLabel(
                scanning: service.scanning, phase: nil,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: L10n.text("Force rescan of MCP config", zhHans: "强制重扫 MCP 配置")) { service.refresh(force: true) }
            if !inSplit {
                LayoutToggle(layout: $layout)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// The family-standard bare "+" round button: a click goes **straight** to the add page (which
    /// is split into Quick install / Manual / JSON tabs), no secondary menu any more — one hop
    /// fewer, and consistent with the other knowledge tabs.
    private var createButton: some View {
        RoundGlyphButton(icon: "plus", help: L10n.text("Add MCP server", zhHans: "添加 MCP server")) {
            withAnimation(.easeOut(duration: 0.15)) {
                formTarget = MCPFormTarget(id: "new", mode: .quick)
            }
        }
    }

    // MARK: - Data definitions

    private var totalCount: Int { service.servers.count }

    private func count(for source: AgentSource) -> Int {
        service.servers.lazy.filter { $0.source == source }.count
    }

    private var availableSources: [AgentSource] {
        var seen = Set<AgentSource>()
        let distinct = service.servers.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
        return distinct.sorted { count(for: $0) > count(for: $1) }
    }

    private var filteredEntries: [MCPServerEntry] {
        service.servers.filter { selectedSource == nil || $0.source == selectedSource }
    }

    /// List mode folds same-name servers (one MCP configured for several CLIs) into one group;
    /// order follows the first copy of each name. Each copy keeps its own row once expanded.
    private var groupedEntries: [(key: String, entries: [MCPServerEntry])] {
        var groups: [(key: String, entries: [MCPServerEntry])] = []
        var index: [String: Int] = [:]
        for entry in filteredEntries {
            let key = entry.name.lowercased()
            if let at = index[key] {
                groups[at].entries.append(entry)
            } else {
                index[key] = groups.count
                groups.append((key, [entry]))
            }
        }
        return groups
    }

    private func row(for entry: MCPServerEntry) -> some View {
        MCPRow(
            entry: entry, service: service,
            toolInfo: toolInfo(for: entry),
            callStat: callStat(for: entry),
            onOpen: { open(entry) },
            onEdit: { edit(entry) },
            onToggle: { toggle(entry) },
            onDelete: { deletingEntry = entry })
    }

    /// Number of distinct server names after dedup (main number on the stats card)
    private var dedupedCount: Int {
        Set(service.servers.map { $0.name.lowercased() }).count
    }

    /// Capability totals across probed servers (overview card corner note): makes "how many tools
    /// are available globally" visible at a glance
    private var measuredCapabilityNote: String? {
        let names = Set(service.servers.map { $0.name.lowercased() })
        let measured = names.compactMap { service.toolCache[$0] }
        guard !measured.isEmpty else { return nil }
        var parts = [L10n.format("Probed %@ · tools %@", zhHans: "实测 %@ 个 · 工具 %@", String(measured.count), String(measured.reduce(0) { $0 + $1.toolCount }))]
        let prompts = measured.reduce(0) { $0 + ($1.promptCount ?? 0) }
        let resources = measured.reduce(0) { $0 + ($1.resourceCount ?? 0) }
        if prompts > 0 { parts.append(L10n.format("prompts %@", zhHans: "提示词 %@", String(prompts))) }
        if resources > 0 { parts.append(L10n.format("resources %@", zhHans: "资源 %@", String(resources))) }
        return parts.joined(separator: " · ")
    }

    /// Transport distribution (neutral shades: the brand colour is reserved for selection and
    /// primary actions)
    private var transportSegments: [StatOverviewCard.Segment] {
        var counts: [String: Int] = [:]
        for entry in service.servers { counts[entry.transport, default: 0] += 1 }
        let shades: [Double] = [1.0, 0.78, 0.6, 0.45]
        return counts.sorted { $0.value > $1.value }.enumerated().map { index, pair in
            StatOverviewCard.Segment(
                label: pair.key, count: pair.value,
                color: Theme.textSecondary.opacity(shades[min(index, shades.count - 1)]))
        }
    }

    // MARK: - Content area

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StatOverviewCard(
                    value: "\(dedupedCount)", unit: "MCP server",
                    subtitle: L10n.format("%@ configs · %@ sources", zhHans: "%@ 处配置 · %@ 个源", String(totalCount), String(availableSources.count)),
                    distributionTitle: L10n.text("Transport", zhHans: "传输方式"),
                    segments: transportSegments,
                    trailingNote: measuredCapabilityNote)
                SourceFilterMenu(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: ToolKind.mcp.icon,
                    totalCount: totalCount,
                    sources: availableSources,
                    count: { count(for: $0) },
                    singleLine: true)
                probeBar
                if filteredEntries.isEmpty {
                    emptyState.padding(.top, 40)
                } else if layout == .cards {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            MCPCard(
                                entry: entry, service: service,
                                toolInfo: toolInfo(for: entry),
                                callStat: callStat(for: entry),
                                onOpen: { open(entry) },
                                onEdit: { edit(entry) },
                                onToggle: { toggle(entry) },
                                onDelete: { deletingEntry = entry })
                        }
                    }
                } else {
                    let groups = groupedEntries
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
                                if group.entries.count == 1, let entry = group.entries.first {
                                    row(for: entry)
                                } else {
                                    let expanded = expandedGroups.contains(group.key)
                                    let primary = group.entries[0]
                                    KnowledgeGroupRow(
                                        name: primary.name,
                                        subtitle: primary.urlSummary ?? primary.commandSummary,
                                        monogram: true,
                                        chips: Array(Set(group.entries.compactMap(\.projectName))).sorted(),
                                        sources: group.entries.map(\.source),
                                        expanded: expanded,
                                        onToggle: {
                                            if expanded {
                                                expandedGroups.remove(group.key)
                                            } else {
                                                expandedGroups.insert(group.key)
                                            }
                                        },
                                        trailing: {
                                            // Tool cache and call stats are keyed by server name, so
                                            // every copy shares the primary's numbers
                                            MCPStatsTrailing(
                                                toolInfo: toolInfo(for: primary),
                                                callStat: callStat(for: primary),
                                                envKeyCount: 0
                                            ) {
                                                CopiesEnabledLabel(
                                                    enabled: group.entries.filter { $0.enabled != false }.count,
                                                    total: group.entries.count)
                                            }
                                        })
                                    if expanded {
                                        ForEach(group.entries) { entry in
                                            row(for: entry).padding(.leading, 22)
                                        }
                                    }
                                }
                                if index < groups.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 54)
                                }
                            }
                        }
                    }
                }
                if let error = service.lastError {
                    Text(error).font(Theme.font.themed(10)).foregroundStyle(Theme.goldFg)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    private func open(_ entry: MCPServerEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detailName = entry.name }
    }

    /// Batch probe action row: serial, one location at a time, cancellable; stdio deep inspection
    /// only happens on explicit actions like this
    @ViewBuilder
    private var probeBar: some View {
        HStack(spacing: 8) {
            if let progress = service.probeProgress {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L10n.format("Probing %@/%@", zhHans: "检测中 %@/%@", String(progress.done), String(progress.total)))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                Button(L10n.text("Cancel", zhHans: "取消")) { service.cancelProbe() }
                    .font(Theme.font.themed(10))
            } else {
                SecondaryButton(
                    title: selectedSource == nil ? L10n.text("Probe all", zhHans: "检测全部") : L10n.text("Probe this source", zhHans: "检测当前源"),
                    icon: "antenna.radiowaves.left.and.right", classic: .push
                ) {
                    service.probe(filteredEntries)
                }
                .disabled(filteredEntries.isEmpty)
                .help(L10n.format("Probe each config (%@): remote does an MCP handshake; stdio briefly starts the configured command and exits after reading", zhHans: "逐处发起连接检测（%@ 处）：remote 走 MCP 握手；stdio 会短暂启动配置的命令，读完即退出", String(filteredEntries.count)))
            }
            Spacer()
        }
    }

    private func toolInfo(for entry: MCPServerEntry) -> MCPToolCacheEntry? {
        service.toolCache[entry.name.lowercased()]
    }

    private func callStat(for entry: MCPServerEntry) -> UsageService.MCPServerCallStat? {
        usageService.mcpServerStats[entry.name.lowercased()]
    }

    private func toggle(_ entry: MCPServerEntry) {
        service.setEnabled(entry, !(entry.enabled ?? true))
    }

    private func edit(_ entry: MCPServerEntry) {
        withAnimation(.easeOut(duration: 0.15)) {
            formTarget = MCPFormTarget(id: "edit:\(entry.id)", mode: .form, editing: entry)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.text("Scanning MCP config…", zhHans: "正在扫描 MCP 配置…")).font(Theme.font.themed(12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            let filtered = service.isSearching || selectedSource != nil
            EmptyStateView(
                icon: ToolKind.mcp.icon,
                title: filtered ? L10n.text("No matching MCP servers", zhHans: "没有匹配的 MCP server") : L10n.text("No MCP servers configured yet", zhHans: "还没有 MCP server 配置"),
                hint: filtered
                    ? nil : L10n.text("Create one, or paste the mcpServers JSON from a README to install it into several CLIs at once", zhHans: "新建一个，或粘贴 README 里的 mcpServers JSON 一键装到多个 CLI"),
                actionTitle: filtered ? nil : L10n.text("New MCP Server", zhHans: "新建 MCP Server"),
                action: filtered ? nil : {
                    withAnimation(.easeOut(duration: 0.15)) {
                        formTarget = MCPFormTarget(id: "new", mode: .quick)
                    }
                })
        }
    }
}

/// Probe snapshot tone → theme color (shared by list status dots and detail chips)
func mcpToneColor(_ tone: String) -> Color {
    switch tone {
    case "ok": return Theme.enabledGreen
    case "warning": return Theme.goldFg
    default: return Theme.failureRed
    }
}

/// NSOpenPanel to pick a project root (fallback repo picker for project-level .mcp.json
/// installs; shared by the form and the detail matrix)
private func mcpPickProjectRoot() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.message = L10n.text("Choose the project root to write .mcp.json into", zhHans: "选择要写入 .mcp.json 的项目根目录")
    return panel.runModal() == .OK ? panel.url?.path : nil
}

/// Snapshot staleness threshold: older than 7 days counts as stale (grey dot in the list +
/// hint in detail suggesting a re-probe)
private let mcpProbeStaleThreshold: TimeInterval = 7 * 86_400

private func mcpSnapshotStale(_ snapshot: MCPProbeSnapshot) -> Bool {
    Date().timeIntervalSince(snapshot.checkedAt) > mcpProbeStaleThreshold
}

/// Capability count summary for overview rows / cards: "30 tools · 5 prompts · 2 resources"
/// (only once probed; zero counts are omitted, taking no space)
func mcpCapabilitySummary(_ info: MCPToolCacheEntry?) -> String? {
    guard let info else { return nil }
    var parts = [L10n.format("%@ tools", zhHans: "%@ 工具", String(info.toolCount))]
    if let prompts = info.promptCount, prompts > 0 { parts.append(L10n.format("%@ prompts", zhHans: "%@ 提示词", String(prompts))) }
    if let resources = info.resourceCount, resources > 0 { parts.append(L10n.format("%@ resources", zhHans: "%@ 资源", String(resources))) }
    return parts.joined(separator: " · ")
}

/// Collapsed description: newlines / runs of whitespace squashed to a single space.
/// `lineLimit` counts rendered lines, and MCP server descriptions commonly carry `\n\n`
/// paragraph breaks — unflattened, the second "line" is an invisible blank line, every tool row
/// grows ~12pt for no reason, text hugs the divider with unexplained space below, and the row
/// rhythm falls apart.
/// (The expanded state still shows the original paragraphs, fully faithful.)
func mcpFlatDescription(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

// MARK: - Capability list row components (themed: brutal = ink lines / hard corners,
// classic = hairlines / rounded corners)

/// Row divider: brutal = **solid 2px ink line** (Neo-Brutalist table rules aren't watered
/// down; a 30%-opacity hairline on the cream background reads as "soft style"); classic /
/// palette themes = 1px hairline.
struct MCPRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(ThemeStyle.current.isHardEdged ? Theme.cardBorder : Theme.hairline)
            .frame(height: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 1)
    }
}

/// The capability list's **table well**: the outer frame + row rules together make a complete
/// table border (brutal = square corners + 2px ink edge; classic = radius 8 + hairline, a
/// macOS grouped table).
/// The background uses surfaceSecondary so the table sits one level "sunk" into the card.
struct MCPListWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let radius: CGFloat = ThemeStyle.current.isHardEdged ? 0 : 8
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.surfaceSecondary))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged ? Theme.cardBorder : Theme.hairline,
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// Tool row (Claude Desktop style): monospaced name + annotation chips, description as the
/// subtitle; the whole row tints lightly on hover, and a click expands the full text and the
/// parameter list (required ones marked *).
/// Row rhythm: brutal uses `Theme.spacing.row` (9pt) vertical padding — 2pt ink table rules
/// need enough breathing room to read as Neo-Brutalist "cells"; classic keeps the original
/// compact 7pt grouped-table look.
struct MCPToolRowView: View {
    let tool: MCPToolSummary
    var access = MCPToolAccess()
    let expanded: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        let params = tool.params ?? []
        let details = tool.paramDetails ?? []
        let expandable = !params.isEmpty || (tool.description?.count ?? 0) > 120
            || !access.rules.isEmpty
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(Theme.font.code(11, .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let title = tool.title, !title.isEmpty, title != tool.name {
                    Text(title)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if tool.readOnly == true { TagChip(L10n.text("Read-only", zhHans: "只读"), neutral: true) }
                if tool.destructive == true { TagChip(L10n.text("Destructive", zhHans: "破坏性"), tint: mcpToneColor("bad")) }
                if tool.hasOutputSchema == true { TagChip(L10n.text("Structured output", zhHans: "结构化输出"), neutral: true) }
                ForEach(access.chips, id: \.self) { TagChip($0, neutral: true) }
                Spacer(minLength: 0)
                if expandable {
                    Image(systemName: "chevron.down")
                        .font(Theme.font.themed(8, .semibold))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if let desc = tool.description, !desc.isEmpty {
                Text(expanded ? desc : mcpFlatDescription(desc))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: expanded)
            }
            if expanded, !details.isEmpty {
                // Name, type and description per parameter (probed with a current build)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.text("Parameters", zhHans: "参数"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    ForEach(details, id: \.name) { param in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(param.name + (param.required ? "*" : ""))
                                .font(Theme.font.code(10, .medium))
                                .foregroundStyle(.primary)
                            if let type = param.type {
                                Text(type)
                                    .font(Theme.font.code(9.5))
                                    .foregroundStyle(.tertiary)
                            }
                            if let description = param.description {
                                Text(mcpFlatDescription(description))
                                    .font(Theme.font.themed(10))
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Text(L10n.text("* required", zhHans: "* 必填"))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 2)
            } else if expanded, !params.isEmpty {
                // Cache written before parameter details were kept: names only
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("Parameters", zhHans: "参数"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(params, id: \.self) { TagChip($0, neutral: true) }
                    }
                    Text(L10n.text("* required", zhHans: "* 必填"))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
            }
            if expanded, !access.rules.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.text("Agent settings that apply", zhHans: "生效的 agent 设置"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    ForEach(access.rules, id: \.self) { rule in
                        Text(rule)
                            .font(Theme.font.code(9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, ThemeStyle.current.isHardEdged ? 10 : 8)
        .padding(.vertical, ThemeStyle.current.isHardEdged ? Theme.spacing.row : 7)
        .background(
            RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 6)
                .fill(hovering ? Theme.brandFill(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            onToggle()
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: expanded)
    }
}

/// What Claude Code and Codex are configured to do with one tool, ready for display. Each side is
/// nil when the server is not configured in that agent. Read-only: mirrors the agents' own
/// settings (`MCPToolPermissionIndex`).
struct MCPToolAccess {
    var claude: MCPToolPermissionIndex.ClaudeAccess?
    var codex: MCPToolPermissionIndex.CodexAccess?

    /// Claude Code runs it without asking
    var isAllowed: Bool { claude?.everywhere == .allowed }
    /// Some agent blocks it, hides it, or asks every time
    var isRestricted: Bool {
        claude?.everywhere == .denied || claude?.everywhere == .ask || codex?.exposed == false
    }

    /// Short labels for the collapsed row. Nothing for the default behaviour, so a row without
    /// chips means "no rule" and the list stays quiet.
    var chips: [String] {
        var chips: [String] = []
        switch claude?.everywhere {
        case .allowed: chips.append(L10n.text("Claude: allowed", zhHans: "Claude 已允许"))
        case .ask: chips.append(L10n.text("Claude: asks", zhHans: "Claude 每次询问"))
        case .denied: chips.append(L10n.text("Claude: denied", zhHans: "Claude 已禁止"))
        case nil: break
        }
        if let codex {
            if !codex.exposed {
                chips.append(L10n.text("Codex: off", zhHans: "Codex 未启用"))
            } else if let mode = codex.approvalMode {
                // Shown as written in config.toml: the docs do not define every value
                chips.append(L10n.format("Codex approval: %@", zhHans: "Codex 审批：%@", mode))
            }
        }
        return chips
    }

    /// One line per matching Claude rule: decision, the rule as written, and where it lives
    var rules: [String] {
        (claude?.rules ?? []).map { rule in
            let decision: String
            switch rule.decision {
            case .allowed: decision = "allow"
            case .ask: decision = "ask"
            case .denied: decision = "deny"
            }
            let home = NSHomeDirectory()
            let path = rule.path.hasPrefix(home) ? "~" + rule.path.dropFirst(home.count) : rule.path
            let scope = rule.projectName.map {
                L10n.format(" (only in %@)", zhHans: "（仅 %@）", $0)
            } ?? ""
            return "\(decision)  \(rule.pattern)  ·  \(path)\(scope)"
        }
    }
}

/// Prompt / resource row: monospaced name + description subtitle, light tint on hover (no
/// expand semantics).
/// The description is flattened the same way (see `mcpFlatDescription`'s comment); row spacing
/// steps up under brutal.
struct MCPNamedRowView: View {
    let item: MCPNamedSummary

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(Theme.font.themed(11, .medium))
                .foregroundStyle(.primary)
            if let desc = item.description, !desc.isEmpty {
                Text(mcpFlatDescription(desc))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, ThemeStyle.current.isHardEdged ? 10 : 8)
        .padding(.vertical, ThemeStyle.current.isHardEdged ? 8 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 6)
                .fill(hovering ? Theme.brandFill(0.05) : Color.clear))
        .onHover { hovering = $0 }
    }
}

/// Capability group tabs (tools / prompts / resources): same selected / hover / stroke spec as
/// SourceFilterChip (selected = solid brand fill with white text + brutal ink edge and hard
/// shadow; unselected = grey fill with thin edge, light tint on hover)
struct MCPCapabilitySegment: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label)
                    .font(Theme.font.themed(10.5, isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(Theme.font.themedMono(10, .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(hovering ? Theme.brandFill(0.06) : Theme.surfaceSecondary))
                    // Hard shadows may only be painted on pure shape layers: on a composited view
                    // containing text, the glyphs leave ghosts at the offset
                    .themeControlShadow(active: isSelected))
            .overlay(
                Capsule().strokeBorder(
                    ThemeStyle.current.isHardEdged
                        ? Theme.cardBorder
                        : (isSelected ? Color.clear : Theme.cardBorder),
                    lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Icon tile (TileSpec template, following PlanIconTile / AuditView.kindTile)

struct MCPIconTile: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(Theme.tileBackground)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        Theme.tileBorder,
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
            .overlay(
                Image(systemName: ToolKind.mcp.icon)
                    .font(Theme.font.themed(size * 0.42, .medium))
                    .foregroundStyle(Theme.textSecondary))
    }
}

// MARK: - Actions and menus shared by row / card

private func mcpEntryActions(
    _ entry: MCPServerEntry, service: MCPService,
    onEdit: @escaping () -> Void, onDelete: @escaping () -> Void
) -> [CardAction] {
    [
        // Pencil = in-app edit form (the external editor entry is in the context menu — popping
        // open the whole config file directly is too intimidating)
        CardAction(icon: "square.and.pencil", help: L10n.text("Edit this definition", zhHans: "编辑该处定义")) {
            onEdit()
        },
        CardAction(icon: "folder", help: L10n.text("Show the config file in Finder", zhHans: "在 Finder 中显示配置文件")) {
            service.reveal(path: entry.configPath)
        },
        CardAction(icon: "trash", destructive: true, help: L10n.text("Remove from this config (backup before writing)", zhHans: "从该配置移除（写前留备份）")) {
            onDelete()
        },
    ]
}

@ViewBuilder
private func mcpEntryMenu(
    _ entry: MCPServerEntry, service: MCPService,
    onOpen: @escaping () -> Void, onEdit: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(L10n.text("View details / install into another agent", zhHans: "查看详情 / 安装到其他 agent")) { onOpen() }
    Button(L10n.text("Edit this definition", zhHans: "编辑该处定义")) { onEdit() }
    Button(L10n.text("Open the config file in the default editor", zhHans: "用默认编辑器打开配置文件")) { service.openInEditor(path: entry.configPath) }
    Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: entry.configPath) }
    Divider()
    Button(L10n.text("Remove from this config", zhHans: "从该配置移除"), role: .destructive) { onDelete() }
}

// MARK: - List row

private struct MCPRow: View {
    let entry: MCPServerEntry
    let service: MCPService
    let toolInfo: MCPToolCacheEntry?
    let callStat: UsageService.MCPServerCallStat?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeRow(
            enabled: entry.enabled != false,
            actions: mcpEntryActions(entry, service: service, onEdit: onEdit, onDelete: onDelete),
            onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                MonogramTile(name: entry.name, source: entry.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // Health dot from the last probe (persisted snapshot; hidden when there is
                        // none) — one glance at the list shows the global state; older than 7 days
                        // it turns grey (stale, the result may no longer hold)
                        if let snapshot = service.probeSnapshots[entry.id] {
                            let stale = mcpSnapshotStale(snapshot)
                            Circle()
                                .fill(stale
                                    ? Color.secondary.opacity(0.45)
                                    : mcpToneColor(snapshot.tone))
                                .frame(width: 6, height: 6)
                                .help(stale
                                    ? L10n.format("Last probe: %@ (over 7 days ago — probe again)", zhHans: "上次检测：%@（已超过 7 天，建议重新检测）", String(snapshot.displayLabel))
                                    : L10n.format("Last probe: %@", zhHans: "上次检测：%@", String(snapshot.displayLabel)))
                        }
                        Text(entry.name)
                            .font(Theme.font.themed(13, .medium))
                            .foregroundStyle(entry.enabled != false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .layoutPriority(1)
                        TagChip(entry.transport, neutral: true)
                        if let project = entry.projectName {
                            TagChip(project, neutral: true)
                        }
                        if entry.enabled == false {
                            TagChip(L10n.text("Disabled", zhHans: "已停用"), neutral: true)
                        }
                    }
                    // What the server says it is, when known; its command line otherwise
                    if let summary = toolInfo?.instructionsHeadline ?? toolInfo?.serverTitle
                        ?? entry.commandSummary ?? entry.urlSummary {
                        Text(summary)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            MCPStatsTrailing(toolInfo: toolInfo, callStat: callStat, envKeyCount: entry.envKeys.count) {
                if MCPService.supportsEnableToggle(entry.source) {
                    MiniSwitch(isOn: entry.enabled ?? true) { onToggle() }
                }
            }
        } menu: {
            mcpEntryMenu(entry, service: service, onOpen: onOpen, onEdit: onEdit,
                         onDelete: onDelete)
        }
    }
}

/// Fixed-width trailing columns shared by single and folded MCP rows — capabilities, calls (or
/// the env key count when nothing has been probed or called), control — so the switches line up
/// down the list.
private struct MCPStatsTrailing<Control: View>: View {
    let toolInfo: MCPToolCacheEntry?
    let callStat: UsageService.MCPServerCallStat?
    let envKeyCount: Int
    @ViewBuilder var control: () -> Control

    private var usageText: String {
        if let callStat, callStat.calls > 0 {
            return L10n.format("%@ calls", zhHans: "%@ 次调用", String(callStat.calls))
        }
        if toolInfo == nil, envKeyCount > 0 {
            return L10n.format("%@ secret keys", zhHans: "%@ 个密钥键", String(envKeyCount))
        }
        return ""
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(mcpCapabilitySummary(toolInfo) ?? "")
                .font(Theme.font.themedMono(10.5)).foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 112, alignment: .trailing)
            Text(usageText)
                .font(Theme.font.themedMono(11, .semibold))
                .foregroundStyle(callStat.map { $0.calls > 0 } == true ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .frame(width: 84, alignment: .trailing)
            control()
                .frame(width: 52, alignment: .trailing)
        }
    }
}

// MARK: - Grid card

private struct MCPCard: View {
    let entry: MCPServerEntry
    let service: MCPService
    let toolInfo: MCPToolCacheEntry?
    let callStat: UsageService.MCPServerCallStat?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeCard(
            enabled: entry.enabled != false, minHeight: 92,
            actions: mcpEntryActions(entry, service: service, onEdit: onEdit, onDelete: onDelete),
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    MonogramTile(name: entry.name, source: entry.source, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(Theme.font.themed(13, .semibold))
                            .foregroundStyle(entry.enabled != false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 5) {
                            TagChip(entry.transport, neutral: true)
                            if entry.enabled == false {
                                TagChip(L10n.text("Disabled", zhHans: "已停用"), neutral: true)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if MCPService.supportsEnableToggle(entry.source) {
                        MiniSwitch(isOn: entry.enabled ?? true) { onToggle() }
                    }
                }
                Text(entry.commandSummary ?? entry.urlSummary ?? "")
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .lineSpacing(1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let project = entry.projectName {
                        TagChip(project, neutral: true)
                    }
                    Spacer(minLength: 0)
                    if let summary = mcpCapabilitySummary(toolInfo) {
                        Text(summary)
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let callStat, callStat.calls > 0 {
                        Text(L10n.format("%@ calls", zhHans: "%@ 次调用", String(callStat.calls)))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } menu: {
            mcpEntryMenu(entry, service: service, onOpen: onOpen, onEdit: onEdit,
                         onDelete: onDelete)
        }
    }
}

// MARK: - Slide-in detail (aggregated by name: definition + cross-source matrix + each config
// location)

private struct MCPDetailView: View {
    @ObservedObject var service: MCPService
    @ObservedObject var usage: UsageService
    let serverName: String
    /// nil in the split layout, where the list is still on screen
    let onBack: (() -> Void)?
    let onDeleteEntry: (MCPServerEntry) -> Void
    let onEdit: (MCPServerEntry) -> Void
    /// "Edit headers / environment variables" entry: opens the edit form with the matching
    /// disclosure section forced open
    let onEditCredentials: (MCPServerEntry) -> Void

    /// Cross-source install target pending confirmation
    @State private var installTarget: AgentSource?
    /// Project-level install sheet (repo picker)
    @State private var projectSheet = false
    @State private var projectRootPath = ""
    @State private var projectCursorToo = false
    /// Install result feedback (shown briefly below the matrix)
    @State private var installNote: String?
    /// Feedback for copy-as-JSON
    @State private var copyNote: String?
    /// Pre-registered client_id draft (advanced disclosure section)
    @State private var clientIDDraft = ""
    @State private var clientIDExpanded = false
    /// Capability card: current group (tools / prompts / resources), search text, expanded tool
    @State private var capabilityTab = "tools"
    @State private var capabilitySearch = ""
    @State private var expandedTools: Set<String> = []
    /// Call activity (daily over the last 30 days + top tools; loaded async in onAppear)
    @State private var activity: UsageService.MCPServerActivity?
    /// Idle cleanup (remove from every source) confirmation and feedback
    @State private var removeAllConfirm = false
    @State private var removeAllNote: String?
    @State private var showMore = false
    @State private var introExpanded = false
    /// nil = follow the default (folded while the server is healthy)
    @State private var connectionExpanded: Bool?
    /// Tool list filter by what the agents allow: all / allowed / restricted
    @State private var permissionFilter = "all"

    /// Live entries: the service rescans after delete / install, and this refreshes along with it
    private var entries: [MCPServerEntry] { service.entries(named: serverName) }
    private var primary: MCPServerEntry? { entries.first }

    private var key: String { serverName.lowercased() }
    private var cache: MCPToolCacheEntry? { service.toolCache[key] }
    private var probing: Bool { service.isProbing(name: serverName) }
    /// First config location Eureka may rewrite (local-scope ones are read-only)
    private var editable: MCPServerEntry? { entries.first { !MCPService.isReadOnly($0) } }
    private var hard: Bool { ThemeStyle.current.isHardEdged }
    /// Most recent probe result across this server's config locations
    private var latestSnapshot: (entry: MCPServerEntry, snapshot: MCPProbeSnapshot)? {
        entries
            .compactMap { entry in service.probeSnapshots[entry.id].map { (entry, $0) } }
            .max { $0.1.checkedAt < $1.1.checkedAt }
            .map { (entry: $0.0, snapshot: $0.1) }
    }

    /// One pane, sections separated by a rule and a title (the Skills detail shape): what the
    /// server is and offers comes first, then how it is connected, used and installed.
    var body: some View {
        Group {
            if entries.isEmpty {
                EmptyStateView(
                    icon: ToolKind.mcp.icon, title: L10n.text("This server is no longer in any config", zhHans: "该 server 已不在任何配置中"),
                    hint: nil, actionTitle: onBack == nil ? nil : L10n.text("Back", zhHans: "返回"),
                    action: onBack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        statusLine
                        actions
                        introSection
                        toolsSection
                        connectionSection
                        activitySection
                        placementSection
                        definitionSection
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    loadActivity()
                    service.probeIfNeeded(name: serverName)
                }
            }
        }
    }

    private func loadActivity() {
        usage.loadMCPServerActivity(server: serverName) { activity = $0 }
    }

    // MARK: Header / status / actions

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
                .help(L10n.text("Back to the list", zhHans: "返回清单"))
            }
            MCPIconTile(size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(serverName)
                    .font(Theme.font.themed(17, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(scopeLine)
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
    }

    /// "Display name · transport · which agents have it"
    private var scopeLine: String {
        var parts: [String] = []
        if let title = cache?.serverTitle ?? cache?.serverName, title.lowercased() != key {
            parts.append(title)
        }
        if let transport = primary?.transport { parts.append(transport) }
        var seen = Set<AgentSource>()
        let sources = entries.compactMap { seen.insert($0.source).inserted ? $0.source.displayName : nil }
        parts.append(sources.joined(separator: L10n.text(", ", zhHans: "、")))
        return parts.joined(separator: " · ")
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            if probing {
                ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 10, height: 10)
                Text(L10n.text("Reading what this server offers…", zhHans: "正在读取这个 server 提供的内容…"))
            } else if let latest = latestSnapshot {
                Circle().fill(mcpToneColor(latest.snapshot.tone)).frame(width: 7, height: 7)
                Text([
                    latest.snapshot.displayLabel,
                    latest.snapshot.detail,
                    relativeFormatter.localizedString(for: latest.snapshot.checkedAt, relativeTo: Date())
                        + (mcpSnapshotStale(latest.snapshot) ? L10n.text(" · expired", zhHans: " · 已过期") : ""),
                ].compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Circle().fill(Theme.disabledGray).frame(width: 7, height: 7)
                Text(L10n.text("Not checked yet", zhHans: "尚未检测"))
            }
        }
        .font(Theme.font.themed(11.5))
        .foregroundStyle(Theme.textSecondary)
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: 10, lineSpacing: 10) {
                PaneButton(
                    probing ? L10n.text("Checking…", zhHans: "检测中…") : L10n.text("Check again", zhHans: "重新检测"),
                    icon: "waveform.path.ecg", kind: .primary
                ) { service.probe(entries) }
                    .disabled(probing)
                    .help(primary?.transport == "stdio"
                        ? L10n.text("Briefly starts the configured command to read its tools, then exits", zhHans: "会短暂启动配置的命令读取工具清单，读完即退出")
                        : L10n.text("Asks the server for its description and tool list", zhHans: "向 server 读取介绍与工具清单"))
                if let editable {
                    PaneButton(L10n.text("Edit", zhHans: "编辑"), icon: "pencil") { onEdit(editable) }
                }
                moreMenu
            }
            if let note = copyNote ?? removeAllNote ?? installNote {
                Text(note).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .themedConfirm(
            L10n.format("Remove “%@” from every config?", zhHans: "从所有配置移除「%@」？", String(serverName)),
            isPresented: $removeAllConfirm,
            message: L10n.format("Will remove from:\n%@", zhHans: "将从以下位置移除：\n%@", String(removable.map(\.configPath).joined(separator: "\n"))),
            confirm: L10n.format("Remove (%@ places, backup each before writing)", zhHans: "移除（%@ 处，写前各留备份）", String(removable.count)),
            destructive: true
        ) { runRemoveEverywhere() }
    }

    private var removable: [MCPServerEntry] { entries.filter { !MCPService.isReadOnly($0) } }

    private var moreMenu: some View {
        Button {
            showMore.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis").font(Theme.font.themed(12, .semibold))
                Text(L10n.text("More", zhHans: "更多")).font(Theme.font.themed(12.5))
            }
            .foregroundStyle(.primary)
            .modifier(PopupButtonChrome(height: 30, horizontalPadding: 13))
        }
        .buttonStyle(.plain)
        .themedPopup(isPresented: $showMore) {
            PopupList {
                if let primary {
                    PopupRow(L10n.text("Copy as mcpServers JSON", zhHans: "复制为 mcpServers JSON"), systemImage: "doc.on.doc") {
                        showMore = false
                        service.copyDefinitionJSON(primary) { ok in
                            copyNote = ok ? L10n.text("Copied (secret values left blank)", zhHans: "已复制（密钥值以空串占位）") : L10n.text("Copy failed", zhHans: "复制失败")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copyNote = nil }
                        }
                    }
                    PopupRow(L10n.text("Show config in Finder", zhHans: "在 Finder 中显示配置"), systemImage: "folder") {
                        showMore = false
                        service.reveal(path: primary.configPath)
                    }
                }
                if !removable.isEmpty {
                    Divider().padding(.vertical, 3)
                    PopupRow(L10n.text("Remove from all sources…", zhHans: "从所有源移除…"), systemImage: "trash", destructive: true) {
                        showMore = false
                        removeAllConfirm = true
                    }
                }
            }
        }
    }

    // MARK: What it provides (the server's own instructions; a tool overview when it sent none)

    private var introSection: some View {
        section(L10n.text("What it provides", zhHans: "它提供什么")) {
            if let text = cache?.instructions, !text.isEmpty {
                let long = text.count > 700 || text.split(whereSeparator: \.isNewline).count > 12
                ZStack(alignment: .bottom) {
                    MarkdownRichText(text: text)
                        .frame(maxWidth: 680, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: introExpanded || !long ? nil : 190, alignment: .top)
                        .clipped()
                    if long && !introExpanded {
                        if hard {
                            Rectangle().fill(Theme.hairline).frame(height: 2)
                        } else {
                            LinearGradient(
                                colors: [Theme.surface.opacity(0), Theme.surface],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 48)
                                .allowsHitTesting(false)
                        }
                    }
                }
                HStack(spacing: 8) {
                    if long {
                        PaneButton(introExpanded
                            ? L10n.text("Collapse", zhHans: "收起")
                            : L10n.text("Show all", zhHans: "展开全文"), small: true) {
                            withAnimation(.easeOut(duration: 0.15)) { introExpanded.toggle() }
                        }
                    }
                    Text(L10n.text("Written by the server itself — the same instructions every agent reads when it connects.", zhHans: "由 server 自己提供——各 agent 连接它时读到的也是这段说明。"))
                        .font(Theme.font.themed(11))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            } else if let cache {
                Text(overview(of: cache))
                    .font(Theme.font.themed(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: 620, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("This server sent no description of its own, so this is put together from its tool list.", zhHans: "这个 server 没有自带文字介绍，以上根据它的工具清单整理。"))
                    .font(Theme.font.themed(11))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(probing
                    ? L10n.text("Reading the server’s description…", zhHans: "正在读取 server 的介绍…")
                    : L10n.text("Nothing read from this server yet. Its description shows here after a successful check.", zhHans: "还没有从这个 server 读到内容，检测成功后介绍会显示在这里。"))
                    .font(Theme.font.themed(12.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// Fallback introduction built from what the probe measured: counts and the first few tools
    private func overview(of cache: MCPToolCacheEntry) -> String {
        var counts = [L10n.format("%@ tools", zhHans: "%@ 个工具", String(cache.toolCount))]
        if let prompts = cache.promptCount, prompts > 0 {
            counts.append(L10n.format("%@ prompts", zhHans: "%@ 个提示词", String(prompts)))
        }
        if let resources = cache.resourceCount, resources > 0 {
            counts.append(L10n.format("%@ resources", zhHans: "%@ 个资源", String(resources)))
        }
        let name = cache.serverTitle ?? cache.serverName ?? serverName
        var text = L10n.format("%1$@ provides %2$@.", zhHans: "%1$@ 提供 %2$@。",
                               name, counts.joined(separator: L10n.text(", ", zhHans: "、")))
        let tools = (cache.tools ?? []).prefix(3)
        if !tools.isEmpty {
            let lines = tools.map { tool -> String in
                let label = tool.title ?? tool.name
                guard let description = tool.description, !description.isEmpty else { return label }
                let first = mcpFlatDescription(description)
                    .split(whereSeparator: { ".。\n".contains($0) }).first.map(String.init) ?? ""
                return first.isEmpty ? label : "\(label) — \(first)"
            }
            text += "\n" + lines.map { "• \($0)" }.joined(separator: "\n")
            if cache.toolCount > tools.count {
                text += "\n" + L10n.format("…and %@ more below.", zhHans: "……另有 %@ 个见下方。",
                                           String(cache.toolCount - tools.count))
            }
        }
        return text
    }

    // MARK: Definition

    @ViewBuilder
    private var definitionSection: some View {
        if let primary {
            section(L10n.text("Definition", zhHans: "定义")) {
                VStack(alignment: .leading, spacing: 6) {
                    if let command = primary.commandSummary {
                        labeledMono(L10n.text("Command", zhHans: "命令"), command)
                    }
                    if let url = primary.urlSummary {
                        labeledMono(L10n.text("URL", zhHans: "地址"), url)
                    }
                    if let version = cache?.serverVersion {
                        labeledMono(L10n.text("Version", zhHans: "版本"), version)
                    }
                    if let proto = cache?.protocolVersion {
                        labeledMono(L10n.text("Protocol", zhHans: "协议"), proto)
                    }
                    if !primary.envKeys.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            fieldLabel(L10n.text("Secret keys", zhHans: "密钥键"))
                            FlowLayout(spacing: 5, lineSpacing: 5) {
                                ForEach(primary.envKeys, id: \.self) { TagChip($0, neutral: true) }
                            }
                            Text(L10n.text("(values are not read or shown)", zhHans: "（值不读取、不显示）"))
                                .font(Theme.font.themed(9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    // MARK: Building blocks

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(spacing: 8) {
                Text(title).font(Theme.font.themed(12.5, .semibold))
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.top, 4)
            content()
        }
    }

    private func labeledMono(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            fieldLabel(label)
            Text(value)
                .font(Theme.font.code(11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(10))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .leading)
    }

    // MARK: Connection and authorization (v2.6: state shown directly, actions laid out — nothing
    // hidden in menus, no guessing for the user)

    /// Folded while every checked location is healthy: nothing to do there, and the tools above
    /// are what the page is for
    private var connectionNeedsAttention: Bool {
        guard let latest = latestSnapshot else { return true }
        return latest.snapshot.tone != "ok" || cache?.toolsError != nil
    }

    private var connectionHints: [String] {
        var seen = Set<String>()
        return entries.compactMap { service.probeSnapshots[$0.id]?.hint }
            .filter { seen.insert($0).inserted }
    }

    private var connectionSection: some View {
        let expanded = connectionExpanded ?? connectionNeedsAttention
        return section(L10n.text("Connection and auth", zhHans: "连接与授权"), trailing: {
            PaneButton(expanded ? L10n.text("Hide", zhHans: "收起") : L10n.text("Show", zhHans: "展开"), small: true) {
                withAnimation(.easeOut(duration: 0.15)) { connectionExpanded = !expanded }
            }
        }) {
            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    // (1) Last probe of each config location (persisted snapshot)
                    ForEach(entries) { entry in
                        probeStatusRow(entry)
                    }
                    // The same guidance usually applies to every location: say it once
                    ForEach(connectionHints, id: \.self) { hint in
                        Text(hint)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(Theme.goldFg)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // (2) Auth flow, routed by the detected auth method: only OAuth gets browser
                    //     authorization, header secrets get "Edit headers", stdio gets "Edit
                    //     environment variables"
                    MCPRowDivider()
                    authRouteSection
                    // (3) CLI-side authorization (one row per configured source)
                    cliAuthRows
                    Text(L10n.text("Check and auth requests go only to the address this server itself advertises.", zhHans: "检测与授权请求只发往该 server 自己披露的地址。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
            } else {
                Text(L10n.text("Connected, nothing to do here.", zhHans: "连接正常，这里没有需要处理的事。"))
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func probeStatusRow(_ entry: MCPServerEntry) -> some View {
        HStack(spacing: 8) {
            SourceBadge(source: entry.source, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.source.displayName)
                    .font(Theme.font.themed(11, .medium))
                // Tells apart two locations of the same agent (global vs one project)
                Text(scopeLabel(entry))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
            if service.probeResults[entry.id] == .checking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(L10n.text("Probing…", zhHans: "检测中…")).font(Theme.font.themed(10.5)).foregroundStyle(.secondary)
            } else if let snapshot = service.probeSnapshots[entry.id] {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TagChip(snapshot.displayLabel, tint: mcpToneColor(snapshot.tone))
                        if let detail = snapshot.detail {
                            Text(detail)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(relativeFormatter.localizedString(
                            for: snapshot.checkedAt, relativeTo: Date())
                            + (mcpSnapshotStale(snapshot) ? L10n.text(" · expired", zhHans: " · 已过期") : ""))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                Text(L10n.text("Not probed yet", zhHans: "尚未检测")).font(Theme.font.themed(10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// Auth routing (v2.7): config shape + persisted snapshot signals, zero network, zero guessing.
    /// envKeys at the index layer is the union of env/headers key names — read as headers for
    /// remote, as environment variables for stdio.
    private var authRoute: MCPAuthRoute {
        guard let primary else { return .unknown }
        let schemes = entries.compactMap { service.probeSnapshots[$0.id]?.authScheme }
        let scheme = schemes.contains("oauth") ? "oauth"
            : (schemes.contains("header-or-key") ? "header-or-key" : schemes.first)
        let isStdio = primary.transport == "stdio"
        return MCPAuthRouter.route(
            transport: primary.transport,
            headerKeys: isStdio ? [] : primary.envKeys,
            envKeys: isStdio ? primary.envKeys : [],
            snapshotScheme: scheme,
            hasToken: service.hasToken(for: primary))
    }

    /// Auth flow: five-way split (OAuth browser / header secret / environment variables / no auth /
    /// pending probe)
    @ViewBuilder
    private var authRouteSection: some View {
        if let primary {
            switch authRoute {
            case .oauthBrowser:
                eurekaTokenRow(prominent: true)
                clientIDDisclosure
            case .staticHeader(let keys):
                authInfoRow(
                    icon: "key.horizontal",
                    title: keys.isEmpty
                        ? L10n.text("Auth: header secret (not set yet)", zhHans: "鉴权方式：请求头密钥（待填入）")
                        : L10n.format("Auth: header secret (%@)", zhHans: "鉴权方式：请求头密钥（%@）", String(keys.joined(separator: ", "))),
                    body: keys.isEmpty
                        ? L10n.text("The last probe returned 401 and published no OAuth metadata — this server uses an API key. Enter it under Headers in the edit form.", zhHans: "上次检测返回 401 且未公布 OAuth 元数据——该 server 走 API key 鉴权，在编辑表单的「请求头」里填入密钥即可。")
                        : L10n.text("This server authenticates with a static header secret and has no OAuth redirect. When the secret expires, update it in the edit form.", zhHans: "该 server 用静态请求头密钥鉴权，无 OAuth 跳转；密钥过期时在编辑表单里更新值。"),
                    buttonTitle: L10n.text("Edit headers", zhHans: "编辑请求头"), prominent: true
                ) { onEditCredentials(primary) }
            case .envKeys(let keys):
                authInfoRow(
                    icon: "key.horizontal",
                    title: L10n.format("Auth: environment variables (%@)", zhHans: "鉴权方式：环境变量（%@）", String(keys.joined(separator: ", "))),
                    body: L10n.text("A stdio server takes credentials from environment variables, per the MCP spec, with no browser auth. When a secret expires, update it under Environment in the edit form.", zhHans: "stdio server 的凭证按 MCP 规范取自环境变量，无浏览器授权；密钥过期时在编辑表单的「环境变量」里更新值。"),
                    buttonTitle: L10n.text("Edit environment", zhHans: "编辑环境变量"), prominent: false
                ) { onEditCredentials(primary) }
            case .open:
                authInfoRow(
                    icon: "lock.open",
                    title: L10n.text("No auth required", zhHans: "无需鉴权"),
                    body: primary.transport == "stdio"
                        ? L10n.text("This stdio server has no secrets configured.", zhHans: "该 stdio server 未配置任何密钥。")
                        : L10n.text("The last probe connected without credentials. No auth is required.", zhHans: "上次检测未携带凭证即连通，无需授权。"),
                    buttonTitle: nil, prominent: false, action: nil)
            case .unknown:
                authInfoRow(
                    icon: "questionmark.circle",
                    title: L10n.text("Auth method not probed yet", zhHans: "鉴权方式待检测"),
                    body: L10n.text("Choose “Probe again” to detect it: a 401 that publishes OAuth metadata means browser auth; otherwise it’s an API key (edit headers).", zhHans: "点「重新检测」自动识别：401 公布 OAuth 元数据 → 浏览器授权；未公布 → API key（编辑请求头）。"),
                    buttonTitle: nil, prominent: false, action: nil)
                eurekaTokenRow(prominent: false)
            }
        }
    }

    /// Auth explanation row: icon + title + body text + optional action button (body is visible,
    /// not a tooltip)
    private func authInfoRow(
        icon: String, title: String, body bodyText: String,
        buttonTitle: String?, prominent: Bool, action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Theme.font.themed(11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font.themed(11.5, .medium))
                Text(bodyText)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let buttonTitle, let action {
                if prominent {
                    PrimaryButton(title: buttonTitle, action: action)
                } else {
                    SecondaryButton(title: buttonTitle, classic: .push, action: action)
                }
            }
        }
    }

    /// Eureka token row: status dot + body text + visible buttons (authorize / revoke); OAuth
    /// progress shown in place.
    /// prominent = false is for the "pending probe" route — authorization still works but is
    /// demoted to a secondary action.
    @ViewBuilder
    private func eurekaTokenRow(prominent: Bool) -> some View {
        if let primary {
            let holding = service.hasToken(for: primary)
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(holding ? Theme.enabledGreen : Theme.disabledGray)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding ? L10n.text("Eureka token: held", zhHans: "Eureka 令牌：已持有") : L10n.text("Eureka token: not held", zhHans: "Eureka 令牌：未持有"))
                        .font(Theme.font.themed(11.5, .medium))
                    Text(L10n.text("The token is only for probing and the tool list in this app. Each CLI authorizes its own connection.", zhHans: "令牌只用于本应用的检测与工具清单；CLI 的连接授权在各 CLI 内完成。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    if let note = entries.compactMap({ service.oauthNotes[$0.id] }).last {
                        Text(note)
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if holding {
                    Button(L10n.text("Revoke", zhHans: "撤销")) { service.revokeToken(for: primary) }
                        .controlSize(.small)
                } else if prominent {
                    PrimaryButton(title: L10n.text("Authorize in browser", zhHans: "在浏览器中授权")) { service.authorizeInBrowser(primary) }
                } else {
                    SecondaryButton(title: L10n.text("Authorize in browser", zhHans: "在浏览器中授权"), classic: .push) {
                        service.authorizeInBrowser(primary)
                    }
                }
            }
        }
    }

    /// Advanced: pre-registered client_id (the spec's way out when the AS doesn't support dynamic
    /// registration; client_id isn't a secret)
    @ViewBuilder
    private var clientIDDisclosure: some View {
        if let primary {
            let saved = service.preRegisteredClientID(for: primary)
            DisclosureGroup(isExpanded: $clientIDExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField(L10n.text("client_id issued by the authorization server", zhHans: "授权服务器分发的 client_id"), text: $clientIDDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.themed(10.5, .regular))
                        Button(L10n.text("Save", zhHans: "保存")) {
                            service.setPreRegisteredClientID(clientIDDraft, for: primary)
                        }
                        .controlSize(.small)
                        .disabled(clientIDDraft.trimmingCharacters(in: .whitespaces) == saved)
                    }
                    Text(L10n.text("Use this when the authorization server does not support dynamic client registration (DCR): register a public client in its console", zhHans: "授权服务器不支持动态注册（DCR）时使用：在其控制台注册一个公共客户端")
                        + L10n.text(" (callback URL http://127.0.0.1/callback; OAuth 2.1 allows any port on loopback),", zhHans: "（回调地址 http://127.0.0.1/callback，回环地址按 OAuth 2.1 允许任意端口），")
                        + L10n.text(" paste the client_id here. Saving an empty value clears it.", zhHans: "把 client_id 填在这里；留空保存即清除。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(L10n.format("Advanced: pre-registered client_id%@", zhHans: "高级：预注册 client_id%@", String(saved.isEmpty ? "" : L10n.text(" (set)", zhHans: "（已设置）"))))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
            .onAppear { clientIDDraft = saved }
        }
    }

    /// CLI-side authorization (one row per configured source; codex runs the auth command
    /// directly, the rest open CLI guidance)
    @ViewBuilder
    private var cliAuthRows: some View {
        let rows = cliAuthActionRows()
        if !rows.isEmpty {
            MCPRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("CLI authorization", zhHans: "CLI 侧授权"))
                    .font(Theme.font.themed(10, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        SourceBadge(source: row.0.source, size: 14)
                        Text(row.1.label)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if row.1.isDirect {
                            Button(L10n.text("Copy command", zhHans: "复制命令")) { service.copyToPasteboard(row.1.command) }
                                .buttonStyle(.borderless)
                                .font(Theme.font.themed(10.5))
                        }
                        Button(row.1.isDirect ? L10n.text("Open Terminal", zhHans: "去终端") : L10n.text("Open", zhHans: "打开")) {
                            service.openInTerminal(command: row.1.command)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func cliAuthActionRows() -> [(MCPServerEntry, MCPService.AuthAction)] {
        var seen = Set<AgentSource>()
        var rows: [(MCPServerEntry, MCPService.AuthAction)] = []
        for entry in entries where seen.insert(entry.source).inserted {
            if let action = MCPService.authActions(for: entry).first {
                rows.append((entry, action))
            }
        }
        return rows
    }

    // MARK: Capabilities (tools / prompts / resources; what an MCP server provides is its core,
    // so this section is always present — no guessing for the user)

    private var toolsSection: some View {
        let stat = usage.mcpServerStats[key]
        return section(L10n.text("Tools", zhHans: "工具"), trailing: {
            if let cache, !probing {
                Text(L10n.format("Read %@", zhHans: "读取于 %@", String(relativeFormatter.localizedString(for: cache.measuredAt, relativeTo: Date()))))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
        }) {
            if let cache {
                if let error = cache.toolsError {
                    notice(
                        icon: "exclamationmark.triangle",
                        title: L10n.text("Connected, but the tool list could not be read", zhHans: "已连接，但没能读取工具列表"),
                        detail: cache.toolCount > 0
                            ? L10n.format("%@ — showing the list from the last successful read.", zhHans: "%@——下面是上次成功读到的清单。", error)
                            : error,
                        diagnostics: diagnostics)
                }
                if probing { probingNotice }
                capabilityBody(cache: cache, stat: stat)
            } else if probing {
                probingNotice
            } else if let latest = latestSnapshot, latest.snapshot.tone != "ok" {
                failureNotice(latest.snapshot)
            } else {
                HStack(spacing: 10) {
                    Text(entries.contains(where: service.trustsForAutoProbe)
                        ? L10n.text("The tool list has not been read yet.", zhHans: "还没有读取工具清单。")
                        : L10n.text("This server comes from a file in the repository, so it is not read until you ask: reading it starts the command or contacts the URL that file names.", zhHans: "这个 server 来自仓库里的配置文件，所以不会自动读取：读取会启动该文件指定的命令或访问它指定的地址。"))
                        .font(Theme.font.themed(12))
                        .foregroundStyle(Theme.textSecondary)
                    PaneButton(L10n.text("Read it now", zhHans: "现在读取"), small: true) { service.probe(entries) }
                }
            }
        }
    }

    /// stderr of the last failed stdio launch, if any location has one
    private var diagnostics: String? {
        entries.compactMap { service.probeDiagnostics[$0.id] }.first
    }

    private var probingNotice: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small).scaleEffect(0.7)
            Text(primary?.transport == "stdio"
                ? L10n.text("Reading the tool list — the configured command is started briefly and exits once read.", zhHans: "正在读取工具清单——会短暂启动配置的命令，读完即退出。")
                : L10n.text("Reading the tool list from the server…", zhHans: "正在向 server 读取工具清单…"))
                .font(Theme.font.themed(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    /// Why there is no tool list, with the next step right here instead of a section away
    @ViewBuilder
    private func failureNotice(_ snapshot: MCPProbeSnapshot) -> some View {
        notice(
            icon: snapshot.tone == "warning" ? "lock" : "exclamationmark.triangle",
            title: L10n.format("No tool list: %@", zhHans: "没有读到工具清单：%@", snapshot.displayLabel),
            detail: [snapshot.detail, snapshot.hint].compactMap { $0 }.joined(separator: "\n"),
            diagnostics: diagnostics)
        FlowLayout(spacing: 10, lineSpacing: 8) {
            if let primary, authRoute == .oauthBrowser, !service.hasToken(for: primary) {
                PaneButton(L10n.text("Authorize in browser", zhHans: "在浏览器中授权"), kind: .primary, small: true) {
                    service.authorizeInBrowser(primary)
                }
            } else if let editable, case .staticHeader = authRoute {
                PaneButton(L10n.text("Edit headers", zhHans: "编辑请求头"), kind: .primary, small: true) {
                    onEditCredentials(editable)
                }
            }
            PaneButton(L10n.text("Try again", zhHans: "重试"), small: true) { service.probe(entries) }
        }
    }

    private func notice(
        icon: String, title: String, detail: String, diagnostics: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(Theme.font.themed(12))
                .foregroundStyle(Theme.goldFg)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(Theme.font.themed(12, .medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(Theme.font.themed(11))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if let diagnostics {
                    Text(L10n.text("Last output of the command:", zhHans: "命令最后的输出："))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(Theme.textTertiary)
                    Text(diagnostics)
                        .font(Theme.font.code(10.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                                .fill(Theme.surfaceSecondary))
                }
            }
        }
    }

    // MARK: What the agents allow (read-only, from each agent's own config)

    private var hasClaude: Bool { entries.contains { $0.source == .claude } }
    private var hasCodex: Bool { entries.contains { $0.source == .codex } }

    private func access(for tool: String) -> MCPToolAccess {
        MCPToolAccess(
            claude: hasClaude
                ? service.toolPermissions.claudeAccess(server: serverName, tool: tool) : nil,
            codex: hasCodex
                ? service.toolPermissions.codexAccess(server: serverName, tool: tool) : nil)
    }

    private func passesPermissionFilter(_ tool: MCPToolSummary) -> Bool {
        switch permissionFilter {
        case "allowed": return access(for: tool.name).isAllowed
        case "restricted": return access(for: tool.name).isRestricted
        default: return true
        }
    }

    private func matchesSearch(_ tool: MCPToolSummary, _ query: String) -> Bool {
        query.isEmpty
            || tool.name.lowercased().contains(query)
            || (tool.title ?? "").lowercased().contains(query)
            || (tool.description ?? "").lowercased().contains(query)
    }

    @ViewBuilder
    private func capabilityBody(
        cache: MCPToolCacheEntry, stat: UsageService.MCPServerCallStat?
    ) -> some View {
        // Overview chips: cost and usage (counts live in the group tabs, not duplicated)
        HStack(spacing: 6) {
            if cache.schemaTokens > 0 {
                TagChip(L10n.format("~%@ tokens per turn", zhHans: "每轮 ~%@ tokens", String(formatTokens(cache.schemaTokens))), neutral: true)
                    .help(L10n.text("Roughly what this server’s tool definitions add to every turn’s context", zhHans: "这个 server 的工具定义每轮大约占用的上下文"))
            }
            if let stat, stat.calls > 0 {
                TagChip(L10n.format("Total calls %@", zhHans: "累计调用 %@ 次", String(stat.calls)), neutral: true)
            }
        }
        // Group tabs (only groups with data are shown; tools is always present)
        HStack(spacing: 6) {
            capabilitySegment("tools", L10n.text("Tools", zhHans: "工具"), count: cache.toolCount)
            if let count = cache.promptCount {
                capabilitySegment("prompts", L10n.text("Prompts", zhHans: "提示词"), count: count)
            }
            if let count = cache.resourceCount {
                capabilitySegment("resources", L10n.text("Resources", zhHans: "资源"), count: count)
            }
            Spacer(minLength: 0)
        }
        let tools = cache.tools ?? []
        let allowedCount = tools.filter { access(for: $0.name).isAllowed }.count
        let restrictedCount = tools.filter { access(for: $0.name).isRestricted }.count
        if capabilityTab == "tools", allowedCount + restrictedCount > 0 {
            HStack(spacing: 6) {
                Text(L10n.text("Agent settings", zhHans: "agent 设置"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.textTertiary)
                MCPCapabilitySegment(
                    label: L10n.text("All", zhHans: "全部"), count: tools.count,
                    isSelected: permissionFilter == "all") { permissionFilter = "all" }
                if allowedCount > 0 {
                    MCPCapabilitySegment(
                        label: L10n.text("Allowed", zhHans: "已允许"), count: allowedCount,
                        isSelected: permissionFilter == "allowed") { permissionFilter = "allowed" }
                }
                if restrictedCount > 0 {
                    MCPCapabilitySegment(
                        label: L10n.text("Restricted", zhHans: "受限"), count: restrictedCount,
                        isSelected: permissionFilter == "restricted") { permissionFilter = "restricted" }
                }
                Spacer(minLength: 0)
            }
        }
        let activeCount = capabilityTab == "prompts"
            ? (cache.prompts?.count ?? 0)
            : capabilityTab == "resources" ? (cache.resources?.count ?? 0) : cache.toolCount
        if activeCount > 10 {
            SearchField(
                placeholder: L10n.text("Search name or description…", zhHans: "搜索名称或描述…"), text: $capabilitySearch,
                resultCount: capabilitySearch.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : filteredCount(cache: cache),
                maxWidth: 380)
        }
        capabilityList(cache: cache)
        if capabilityTab == "tools", hasClaude || hasCodex, !tools.isEmpty {
            Text(permissionFootnote)
                .font(Theme.font.themed(10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let hint = idleHint(cache: cache, stat: stat) {
            HStack(spacing: 10) {
                Text(hint)
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.goldFg)
                if !removable.isEmpty {
                    PaneButton(L10n.text("Remove from all sources…", zhHans: "从所有源移除…"), kind: .quiet, small: true) {
                        removeAllConfirm = true
                    }
                }
            }
        }
    }

    /// Explains the unmarked case so a missing chip is not read as "blocked"
    private var permissionFootnote: String {
        var parts: [String] = []
        if hasClaude {
            parts.append(L10n.text("Claude Code asks before the first use of a tool unless a permission rule says otherwise.", zhHans: "没有标注的工具，Claude Code 会在首次使用前询问。"))
        }
        if hasCodex {
            parts.append(L10n.text("Codex exposes every tool unless its config lists enabled or disabled tools.", zhHans: "Codex 默认启用全部工具，除非配置里写了启用或停用列表。"))
        }
        parts.append(L10n.text("Read from each agent’s own settings; nothing is changed here.", zhHans: "以上读自各 agent 自己的设置，这里不做修改。"))
        return parts.joined(separator: " ")
    }

    private func capabilitySegment(_ id: String, _ label: String, count: Int) -> some View {
        MCPCapabilitySegment(label: label, count: count, isSelected: capabilityTab == id) {
            capabilityTab = id
            capabilitySearch = ""
            permissionFilter = "all"
        }
    }

    /// Hit count for the current group under the search text (for the count capsule on the right
    /// of the SearchField)
    private func filteredCount(cache: MCPToolCacheEntry) -> Int {
        let query = capabilitySearch.trimmingCharacters(in: .whitespaces).lowercased()
        switch capabilityTab {
        case "prompts":
            return (cache.prompts ?? []).filter { matches($0, query) }.count
        case "resources":
            return (cache.resources ?? []).filter { matches($0, query) }.count
        default:
            return (cache.tools ?? [])
                .filter { matchesSearch($0, query) && passesPermissionFilter($0) }.count
        }
    }

    private func matches(_ item: MCPNamedSummary, _ query: String) -> Bool {
        query.isEmpty || item.name.lowercased().contains(query)
            || (item.description ?? "").lowercased().contains(query)
    }

    @ViewBuilder
    private func capabilityList(cache: MCPToolCacheEntry) -> some View {
        let query = capabilitySearch.trimmingCharacters(in: .whitespaces).lowercased()
        switch capabilityTab {
        case "prompts":
            namedList(cache.prompts ?? [], query: query, empty: L10n.text("This server provides no prompts", zhHans: "该 server 未提供提示词"))
        case "resources":
            namedList(cache.resources ?? [], query: query, empty: L10n.text("This server provides no resources", zhHans: "该 server 未提供资源"))
        default:
            if let tools = cache.tools, !tools.isEmpty {
                let filtered = tools.filter {
                    matchesSearch($0, query) && passesPermissionFilter($0)
                }
                if filtered.isEmpty {
                    Text(query.isEmpty
                        ? L10n.text("No tools in this group", zhHans: "这一组里没有工具")
                        : L10n.format("No tools match “%@”", zhHans: "没有匹配「%@」的工具", String(capabilitySearch)))
                        .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
                } else {
                    // Table well: outer frame + solid row rules (brutal = 2px ink), one cell per
                    // tool
                    MCPListWell {
                        ForEach(Array(filtered.enumerated()), id: \.element.name) { index, tool in
                            if index > 0 { MCPRowDivider() }
                            MCPToolRowView(
                                tool: tool,
                                access: access(for: tool.name),
                                expanded: expandedTools.contains(tool.name)
                            ) {
                                if expandedTools.contains(tool.name) {
                                    expandedTools.remove(tool.name)
                                } else {
                                    expandedTools.insert(tool.name)
                                }
                            }
                        }
                    }
                }
            } else if !cache.toolNames.isEmpty {
                // Old caches only have names (one re-probe upgrades them to full details)
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(cache.toolNames, id: \.self) { name in
                        Text(name)
                            .font(Theme.font.themed(9.5, .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.surfaceSecondary))
                    }
                }
            } else {
                Text(L10n.text("This server exposes no tools", zhHans: "该 server 未暴露任何工具"))
                    .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func namedList(
        _ items: [MCPNamedSummary], query: String, empty: String
    ) -> some View {
        let filtered = items.filter { matches($0, query) }
        if filtered.isEmpty {
            Text(items.isEmpty ? empty : L10n.format("No items match “%@”", zhHans: "没有匹配「%@」的条目", String(capabilitySearch)))
                .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
        } else {
            MCPListWell {
                ForEach(Array(filtered.enumerated()), id: \.element.name) { index, item in
                    if index > 0 { MCPRowDivider() }
                    MCPNamedRowView(item: item)
                }
            }
        }
    }

    /// Idle hint: paying the per-turn schema tax but not called in 30 days → suggest disabling /
    /// removing
    private func idleHint(
        cache: MCPToolCacheEntry?, stat: UsageService.MCPServerCallStat?
    ) -> String? {
        guard let cache, cache.schemaTokens > 0 else { return nil }
        let thirtyDaysAgo = Date().timeIntervalSince1970 - 30 * 86_400
        let idle = (stat?.calls ?? 0) == 0 || (stat?.lastTs ?? 0) < thirtyDaysAgo
        guard idle else { return nil }
        return L10n.format("No calls in 30 days, but ~%@ tokens are spent every turn — consider disabling or removing it", zhHans: "30 天内没有调用记录，却每轮消耗 ~%@ tokens —— 建议停用或移除", String(formatTokens(cache.schemaTokens)))
    }

    private func runRemoveEverywhere() {
        removeAllNote = L10n.text("Removing…", zhHans: "正在移除…")
        service.removeEverywhere(named: serverName) { results in
            let failures = results.sorted(by: { $0.key < $1.key })
                .compactMap { label, error in error.map { L10n.format("%@: %@", zhHans: "%@：%@", String(label), String($0)) } }
            removeAllNote = failures.isEmpty
                ? L10n.format("Removed from %@ places", zhHans: "已从 %@ 处移除", String(results.count))
                : L10n.text("Partial failure — ", zhHans: "部分失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { removeAllNote = nil }
        }
    }

    // MARK: Call activity (usage drill-down: daily over the last 30 days + top tools)

    /// Total over the last 30-day window (series is already zero-filled, so just sum it)
    private var recentCalls: Int {
        activity?.series.reduce(0) { $0 + $1.count } ?? 0
    }

    private var activitySection: some View {
        section(L10n.text("Usage", zhHans: "使用情况")) {
            if let stat = usage.mcpServerStats[key], stat.calls > 0 {
                Text(L10n.format("Last 30 days %@ · total %@ · latest %@", zhHans: "近 30 天 %@ 次 · 累计 %@ 次 · 最近 %@", String(recentCalls), String(stat.calls), String(relativeFormatter.localizedString(for: Date(timeIntervalSince1970: stat.lastTs), relativeTo: Date()))))
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(L10n.text("No calls recorded yet.", zhHans: "还没有调用记录。"))
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
            }
            if let activity, activity.series.contains(where: { $0.count > 0 }) {
                activityBars(activity)
                if !activity.topTools.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(activity.topTools, id: \.name) { tool in
                            TagChip("\(tool.name) · \(tool.count)", neutral: true)
                        }
                    }
                }
            }
        }
    }

    /// 30 mini bars (zero draws a grey baseline; days with calls scale to the peak)
    private func activityBars(_ activity: UsageService.MCPServerActivity) -> some View {
        let peak = max(activity.series.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(activity.series.enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 1)
                    .fill(point.count > 0
                        ? Theme.brand.opacity(0.45 + 0.55 * Double(point.count) / Double(peak))
                        : Color.secondary.opacity(0.15))
                    .frame(height: point.count > 0
                        ? max(4, 30.0 * Double(point.count) / Double(peak))
                        : 2)
            }
        }
        .frame(height: 30, alignment: .bottom)
        .help(L10n.format("Calls per day over 30 days (peak %@/day)", zhHans: "近 30 天逐日调用（最高 %@ 次/天）", String(peak)))
    }

    // MARK: Cross-source matrix (following the SkillDetailView.matrixSection template)

    /// Where the server is configured, then where else it could go (the two used to be separate
    /// cards that listed the same sources twice)
    private var placementSection: some View {
        let configuredSources = Set(entries.map(\.source))
        return section(L10n.text("Installed in", zhHans: "安装位置"), trailing: {
            Text(L10n.format("%@ places", zhHans: "%@ 处", String(entries.count)))
                .font(Theme.font.themed(10.5))
                .foregroundStyle(Theme.textTertiary)
        }) {
            KnowledgeListContainer {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        occurrenceRow(entry)
                        if index < entries.count - 1 {
                            Divider().opacity(0.4).padding(.leading, 44)
                        }
                    }
                }
            }
            if primary?.scope != .local || entries.count > 1 {
                Text(L10n.text("Copy to another agent", zhHans: "复制到其他 agent"))
                    .font(Theme.font.themed(11, .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
                HStack(alignment: .top, spacing: 8) {
                    ForEach(AgentSource.allCases, id: \.self) { source in
                        matrixTile(source, configured: configuredSources.contains(source))
                    }
                    projectMatrixTile
                }
            }
        }
        .sheet(isPresented: $projectSheet) { projectInstallSheet }
        .themedConfirm(
            L10n.format("Install into %@?", zhHans: "安装到 %@？", String(installTarget?.displayName ?? "")),
            isPresented: Binding(
                get: { installTarget != nil },
                set: { if !$0 { installTarget = nil } }),
            message: installTarget.flatMap { MCPService.writableTarget(for: $0) }.map { writable in
                L10n.format("The server definition (including secret values, copied only between files on this Mac) will be written to\n%@\nA .bak.eureka backup is kept first.", zhHans: "将把 server 定义（含密钥值，仅本机文件间复制）写入\n%@\n写前会留 .bak.eureka 备份。", String(writable.configURL.path))
            },
            confirm: L10n.text("Write this agent’s MCP config", zhHans: "写入该 agent 的 MCP 配置")
        ) { runInstall() }
    }

    @ViewBuilder
    private func matrixTile(_ source: AgentSource, configured: Bool) -> some View {
        let blockReason = configured
            ? nil
            : MCPService.installBlockReason(transport: primary?.transport ?? "stdio", to: source)
        let installable = !configured && blockReason == nil
        VStack(spacing: 4) {
            SourceBadge(source: source, size: 22)
                .opacity(configured ? 1 : (installable ? 0.6 : 0.28))
            Text(source.displayName)
                .font(Theme.font.themed(9))
                .foregroundStyle(configured ? .secondary : .tertiary)
            if configured {
                Text(L10n.text("Configured", zhHans: "已配置"))
                    .font(Theme.font.themed(8, .medium))
                    .foregroundStyle(Theme.textSecondary)
            } else if installable {
                Text(L10n.text("Install", zhHans: "安装"))
                    .font(Theme.font.themed(8, .semibold))
                    .foregroundStyle(Theme.brandFg)
            } else {
                Text(L10n.text("Not writable", zhHans: "不可写"))
                    .font(Theme.font.themed(8, .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(configured ? Theme.brandFill(0.08) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    configured ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                    lineWidth: configured ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture {
            guard installable else { return }
            installTarget = source
        }
        .help(configured
            ? L10n.format("%@ already has this server", zhHans: "%@ 已配置该 server", String(source.displayName))
            : (blockReason ?? L10n.format("Write this server into %@’s MCP config", zhHans: "把该 server 写入 %@ 的 MCP 配置", String(source.displayName))))
    }

    private func runInstall() {
        guard let installTo = installTarget, let primary else { return }
        installTarget = nil
        let targetName = installTo.displayName
        installNote = L10n.format("Installing into %@…", zhHans: "正在安装到 %@…", String(targetName))
        service.propagate(primary, to: [installTo]) { results in
            if let failure = results[installTo] ?? nil {
                installNote = L10n.format("Install into %@ failed: %@", zhHans: "安装到 %@ 失败：%@", String(targetName), String(failure))
            } else {
                installNote = L10n.format("Installed into %@ (backup kept before writing)", zhHans: "已安装到 %@（写前留有备份）", String(targetName))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { installNote = nil }
        }
    }

    /// Project-level tile: belongs to no single agent (claude's .mcp.json is MCP's official project
    /// standard, cursor has an equivalent convention); it can be installed into another repo even
    /// when already configured, so it's always clickable
    private var projectMatrixTile: some View {
        let projectConfigured = entries.contains { $0.projectName != nil }
        return VStack(spacing: 4) {
            Image(systemName: projectConfigured ? "folder.fill.badge.checkmark" : "folder.badge.plus")
                .font(Theme.font.themed(12))
                .foregroundStyle(projectConfigured ? .secondary : Theme.brandFg.opacity(0.8))
            Text(L10n.text("Project", zhHans: "项目级"))
                .font(Theme.font.themed(9))
                .foregroundStyle(.secondary)
            Text(projectConfigured ? L10n.text("Configured", zhHans: "已配置") : L10n.text("Install", zhHans: "安装"))
                .font(Theme.font.themed(8, projectConfigured ? .medium : .semibold))
                .foregroundStyle(projectConfigured ? Theme.textSecondary : Theme.brandFg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(projectConfigured ? Theme.brandFill(0.08) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    projectConfigured ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                    lineWidth: projectConfigured ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture { projectSheet = true }
        .help(projectConfigured
            ? L10n.text("Already in some repos; open to install into another project", zhHans: "已装到某些 repo；点开可再装到其它项目")
            : L10n.text("Write this server into the selected repo’s .mcp.json (shared with the project)", zhHans: "把该 server 写入所选 repo 的 .mcp.json（随项目共享）"))
    }

    /// Repo picker sheet: recent projects (roots found by the scan) + browse fallback
    private var projectInstallSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("Install “%@” into a project", zhHans: "安装「%@」到项目", String(serverName)))
                .font(Theme.font.themed(13, .semibold))
            HStack(spacing: 6) {
                MenuButton(
                    title: projectRootPath.isEmpty
                        ? L10n.text("Choose a project", zhHans: "选择项目") : String(projectRootPath.split(separator: "/").last ?? ""),
                    icon: "folder"
                ) {
                    ForEach(service.repoRoots, id: \.root) { candidate in
                        Button(candidate.name.isEmpty
                            ? candidate.root.lastPathComponent
                            : L10n.format("%@ (%@)", zhHans: "%@（%@）", String(candidate.name), String(candidate.root.lastPathComponent))) {
                            projectRootPath = candidate.root.path
                        }
                    }
                }
                Button(L10n.text("Browse…", zhHans: "浏览…")) {
                    if let picked = mcpPickProjectRoot() { projectRootPath = picked }
                }
                .font(Theme.font.themed(11))
                Spacer()
            }
            if !projectRootPath.isEmpty {
                Text("\(projectRootPath)/.mcp.json")
                    .font(Theme.font.themed(9, .regular))
                    .foregroundStyle(.tertiary)
            }
            Toggle(isOn: $projectCursorToo) {
                Text(L10n.text("Also write Cursor’s project config (.cursor/mcp.json)", zhHans: "同时写 cursor 的项目配置（.cursor/mcp.json）"))
                    .font(Theme.font.themed(11))
            }
            .toggleStyle(.checkbox)
            HStack {
                Button(L10n.text("Cancel", zhHans: "取消")) { projectSheet = false }
                    .font(Theme.font.themed(11))
                Spacer()
                PrimaryButton(title: L10n.text("Write .mcp.json", zhHans: "写入 .mcp.json")) {
                    runProjectInstall()
                }
                .disabled(projectRootPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func runProjectInstall() {
        guard let primary else { return }
        projectSheet = false
        var sources: [AgentSource] = [.claude]
        if projectCursorToo { sources.append(.cursor) }
        let root = URL(fileURLWithPath:
            projectRootPath.trimmingCharacters(in: .whitespaces))
        installNote = L10n.text("Installing at project level…", zhHans: "正在安装到项目级…")
        service.propagateToProject(primary, sources: sources, projectRoot: root) { results in
            let failures = results.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .compactMap { source, error in
                    error.map { L10n.format("Project %@: %@", zhHans: "项目级 %@：%@", String(source.displayName), String($0)) }
                }
            installNote = failures.isEmpty
                ? L10n.text("Installed into the project (backup kept before writing)", zhHans: "已安装到项目（写前留有备份）")
                : L10n.text("Install failed — ", zhHans: "安装失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { installNote = nil }
        }
    }

    // MARK: Config locations

    private func occurrenceRow(_ entry: MCPServerEntry) -> some View {
        let readOnly = MCPService.isReadOnly(entry)
        return HStack(spacing: 10) {
            SourceLogoTile(source: entry.source, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.source.displayName)
                        .font(Theme.font.themed(12, .medium))
                    TagChip(scopeLabel(entry), neutral: true)
                    if entry.enabled == false {
                        TagChip(L10n.text("Disabled", zhHans: "已停用"), neutral: true)
                    }
                    if let approval = approvalLabel(entry) {
                        TagChip(approval, neutral: true)
                    }
                    probeChip(for: entry)
                }
                Text(readOnly
                    ? L10n.format("%@ · managed with `claude mcp`", zhHans: "%@ · 用 `claude mcp` 管理", abbreviateHome(entry.configPath))
                    : abbreviateHome(entry.configPath))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            if !readOnly {
                CardActionButton(icon: "square.and.pencil", help: L10n.text("Edit this definition", zhHans: "编辑该处定义")) {
                    onEdit(entry)
                }
            }
            CardActionButton(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) {
                service.reveal(path: entry.configPath)
            }
            if !readOnly {
                CardActionButton(icon: "trash", color: Theme.failureRed,
                                 help: L10n.text("Remove from this config (backup before writing)", zhHans: "从该配置移除（写前留备份）")) {
                    onDeleteEntry(entry)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { if !readOnly { onEdit(entry) } }
        .help(readOnly
            ? L10n.text("Stored in Claude Code’s per-project settings; change it with `claude mcp`", zhHans: "保存在 Claude Code 的按项目设置里，用 `claude mcp` 修改")
            : L10n.text("Click to edit this definition", zhHans: "点击编辑该处定义"))
    }

    private func scopeLabel(_ entry: MCPServerEntry) -> String {
        switch entry.scope {
        case .global: return L10n.text("Global", zhHans: "全局")
        case .project: return L10n.format("Project · %@", zhHans: "项目 · %@", entry.projectName ?? "")
        case .local: return L10n.format("Local · %@", zhHans: "本地 · %@", entry.projectName ?? "")
        }
    }

    /// Claude Code asks once before using a server from a repo's `.mcp.json`
    private func approvalLabel(_ entry: MCPServerEntry) -> String? {
        guard entry.source == .claude, entry.scope == .project else { return nil }
        let root = URL(fileURLWithPath: entry.configPath).deletingLastPathComponent().path
        switch service.toolPermissions.claudeProjectServerApproval(server: entry.name, projectPath: root) {
        case .approved: return L10n.text("Approved in Claude", zhHans: "Claude 已批准")
        case .rejected: return L10n.text("Rejected in Claude", zhHans: "Claude 已拒绝")
        case .unanswered: return L10n.text("Claude will ask", zhHans: "Claude 待批准")
        }
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Status chip: probing → spinner; otherwise shows the **persisted snapshot** (survives
    /// restarts, shown directly since v2.6); older than 7 days adds a "stale" hint (the relative
    /// time already reads "N days ago")
    @ViewBuilder
    private func probeChip(for entry: MCPServerEntry) -> some View {
        if service.probeResults[entry.id] == .checking {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else if let snapshot = service.probeSnapshots[entry.id] {
            TagChip(snapshot.displayLabel, tint: mcpToneColor(snapshot.tone))
            Text(relativeFormatter.localizedString(for: snapshot.checkedAt, relativeTo: Date())
                + (mcpSnapshotStale(snapshot) ? L10n.text(" · expired", zhHans: " · 已过期") : ""))
                .font(Theme.font.themed(9))
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(10, .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - Slide-in form (create / import pasted JSON)

struct MCPFormTarget: Identifiable {
    enum Mode { case quick, form, paste }
    let id: String
    var mode: Mode
    /// Non-nil = editing an existing config location (name and write location locked, fields
    /// prefilled with current values)
    var editing: MCPServerEntry? = nil
    /// true = entered from "Edit headers / environment variables": the matching disclosure section
    /// is forced open (even with no keys yet)
    var expandCredentials: Bool = false
}

private struct MCPServerFormView: View {
    @ObservedObject var service: MCPService
    let target: MCPFormTarget
    let onBack: () -> Void

    private struct KVRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    @State private var mode: MCPFormTarget.Mode = .form
    @State private var loaded = false

    // Form mode
    @State private var name = ""
    @State private var isRemote = false
    @State private var command = ""
    @State private var argsText = ""
    @State private var urlText = ""
    @State private var timeoutText = ""
    @State private var envRows: [KVRow] = []
    @State private var headerRows: [KVRow] = []
    @State private var envExpanded = false
    @State private var headersExpanded = false

    // Quick install: one input box handles command / URL / JSON (auto-detected, name derived
    // automatically)
    @State private var quickText = ""

    // JSON mode (two-way synced with the form: values are carried over when switching tabs)
    @State private var pasteText = ""

    // Shared
    @State private var selectedTargets: Set<AgentSource> = []
    // Project-level install (create mode): pick a repo + conventions (claude .mcp.json required,
    // cursor optional)
    @State private var projectInstall = false
    @State private var projectRootPath = ""
    @State private var projectCursorToo = false
    @State private var resultNote: String?
    @State private var submitting = false

    /// Edit mode: name and write location locked, fields prefilled with current values
    private var isEditing: Bool { target.editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isEditing
                        ? L10n.text("Saving rewrites this config in place, keeps fields this form doesn’t model, and backs up first.", zhHans: "修改后保存：原位改写该处配置，未建模字段保留，写前留备份。")
                        : (mode == .quick
                            ? L10n.text("Paste a command, URL, or JSON. It’s recognized and installed into the selected agents.", zhHans: "粘贴命令、URL 或 JSON，自动识别并安装到所选 agent。")
                            : (mode == .form
                                ? L10n.text("Set the name, command/URL, environment, and headers yourself.", zhHans: "手动配置名称、命令/URL、环境变量与请求头。")
                                : L10n.text("Paste or edit mcpServers JSON. Every server in it is written to the selected targets.", zhHans: "粘贴或编辑 mcpServers JSON；多个 server 会全部写入所选目标。"))))
                        .font(Theme.font.themed(11))
                        .foregroundStyle(.secondary)
                    card
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surfaceSecondary)
        }
        .onAppear { hydrate() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(Theme.font.themed(10, .semibold))
                    Text(L10n.text("Back", zhHans: "返回")).font(Theme.font.themed(11))
                }
            }
            .buttonStyle(.borderless)
            MCPIconTile(size: 22)
            Text(isEditing
                ? L10n.format("Edit %@", zhHans: "编辑 %@", String(target.editing?.name ?? ""))
                : L10n.text("New MCP Server", zhHans: "新建 MCP Server"))
                .font(Theme.font.themed(13, .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // The three tabs interoperate (modeled on ZCode): Quick install / Manual / JSON, values
            // carried over on switch; edit mode has no "Quick install" (the definition already
            // exists)
            CapsuleTabTray {
                if !isEditing {
                    CapsuleTabButton(
                        title: L10n.text("Quick install", zhHans: "快速安装"), fillWidth: false, isSelected: mode == .quick
                    ) {
                        switchMode(.quick)
                    }
                }
                CapsuleTabButton(title: L10n.text("Manual setup", zhHans: "手动配置"), fillWidth: false, isSelected: mode == .form) {
                    switchMode(.form)
                }
                CapsuleTabButton(title: "JSON", fillWidth: false, isSelected: mode == .paste) {
                    switchMode(.paste)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Cards (ZCode style: label on top, example placeholders, optional fields folded)

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Quick install has no name input (the name is derived; switch to "Manual" to rename)
            if mode != .quick {
                fieldColumn(L10n.text("Name", zhHans: "名称")) {
                    TextField("my-mcp-server", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font.themed(12, .regular))
                        .disabled(isEditing)  // rename = delete + create (same rule as Codex profiles)
                        .frame(maxWidth: 320)
                }
            }
            if let entry = target.editing { lockedLocationRow(entry) }

            if mode == .quick {
                quickFields
            } else if mode == .form {
                formFields
            } else {
                jsonEditor
            }

            if !isEditing { targetsBlock }

            if let note = resultNote {
                Text(note).font(Theme.font.themed(10.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                PrimaryButton(title: isEditing ? L10n.text("Save changes", zhHans: "保存修改") : L10n.text("Add", zhHans: "添加")) { submit() }
                    .disabled(!canSubmit || submitting)
                Button(L10n.text("Cancel", zhHans: "取消"), action: onBack)
                    .buttonStyle(.borderless)
                Spacer(minLength: 12)
                Text(footerHint)
                    .font(Theme.font.themed(9, .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface)
                .themeCardShadow())
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
    }

    /// Field column with the label on top (ZCode style)
    private func fieldColumn<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.font.themed(11, .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func lockedLocationRow(_ entry: MCPServerEntry) -> some View {
        fieldColumn(L10n.text("Write location (locked)", zhHans: "写入位置（锁定）")) {
            HStack(spacing: 8) {
                SourceLogoTile(source: entry.source, size: 20)
                Text(entry.source.displayName).font(Theme.font.themed(12, .medium))
                TagChip(entry.projectName ?? L10n.text("Global", zhHans: "全局"), neutral: entry.projectName == nil)
                Text(entry.configPath)
                    .font(Theme.font.themed(9, .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var formFields: some View {
        fieldColumn(L10n.text("Type", zhHans: "类型")) {
            Picker("", selection: $isRemote) {
                Text(L10n.text("stdio (local command)", zhHans: "stdio（本地命令）")).tag(false)
                Text(L10n.text("Remote (HTTP/SSE)", zhHans: "远程（HTTP/SSE）")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        if isRemote {
            fieldColumn("URL") {
                TextField("https://mcp.example.com/mcp", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.themed(12, .regular))
            }
            fieldColumn(L10n.text("Timeout ms (optional)", zhHans: "超时时间 MS（可选）")) {
                TextField("30000", text: $timeoutText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.themed(12, .regular))
                    .frame(maxWidth: 200)
            }
            kvDisclosure(L10n.text("Headers (optional)", zhHans: "请求头（可选）"), rows: $headerRows, expanded: $headersExpanded,
                         keyPlaceholder: "Authorization", valuePlaceholder: "Bearer …",
                         addLabel: L10n.text("Add header", zhHans: "添加请求头"))
        } else {
            fieldColumn(L10n.text("Command", zhHans: "命令")) {
                TextField("npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.themed(12, .regular))
                    .frame(maxWidth: 320)
            }
            fieldColumn(L10n.text("Arguments (space-separated)", zhHans: "参数（空格分隔）")) {
                TextField("-y @modelcontextprotocol/server-memory", text: $argsText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.themed(12, .regular))
            }
            kvDisclosure(L10n.text("Environment (optional)", zhHans: "环境变量（可选）"), rows: $envRows, expanded: $envExpanded,
                         keyPlaceholder: "API_KEY", valuePlaceholder: L10n.text("Value (written only to the target config; Eureka does not keep it)", zhHans: "值（只写入目标配置，Eureka 不保存）"),
                         addLabel: L10n.text("Add variable", zhHans: "添加环境变量"))
        }
    }

    private func kvDisclosure(
        _ title: String, rows: Binding<[KVRow]>, expanded: Binding<Bool>,
        keyPlaceholder: String, valuePlaceholder: String, addLabel: String
    ) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { $row in
                    HStack(spacing: 8) {
                        TextField(keyPlaceholder, text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.themed(11.5, .regular))
                            .frame(width: 220)
                        TextField(valuePlaceholder, text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.themed(11.5, .regular))
                        Button {
                            rows.wrappedValue.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle").font(Theme.font.themed(12))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Delete this row", zhHans: "删除该行"))
                    }
                }
                Button {
                    rows.wrappedValue.append(KVRow())
                    expanded.wrappedValue = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(Theme.font.themed(11))
                        Text(addLabel).font(Theme.font.themed(11))
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.font.themed(11, .medium)).foregroundStyle(.secondary)
                if !rows.wrappedValue.isEmpty {
                    Text("\(rows.wrappedValue.count)")
                        .font(Theme.font.themedMono(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Quick install (one box handles command / URL / JSON)

    private var parsedQuick: [MCPServerDefinition] {
        MCPServerEditor.parseQuickInput(quickText)
    }

    @ViewBuilder
    private var quickFields: some View {
        fieldColumn(L10n.text("Command, URL, or JSON", zhHans: "命令、URL 或 JSON")) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $quickText)
                    .font(Theme.font.themed(12, .regular))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if quickText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: "npx -y chrome-devtools-mcp@latest")
                        Text(verbatim: L10n.text("or https://example.com/mcp", zhHans: "或 https://example.com/mcp"))
                        Text(verbatim: L10n.text("or a whole {\"mcpServers\": …} JSON", zhHans: "或整段 {\"mcpServers\": …} JSON"))
                    }
                    .font(Theme.font.themed(12, .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surfaceSecondary))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        let defs = parsedQuick
        Text(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("Paste a command, URL, or JSON to install. For a custom name, environment, or headers, switch to Manual setup.", zhHans: "粘贴命令、URL 或 JSON 即可安装；需要自定义名称、环境变量或请求头时，切到「手动配置」。")
            : (defs.isEmpty
                ? L10n.text("No server parsed — check that the input is complete", zhHans: "没有解析出 server —— 检查输入是否完整")
                : (defs.count == 1
                    ? L10n.format("Will install as “%@” (%@) — the name is derived automatically. Switch to Manual setup to change it.", zhHans: "将安装为「%@」（%@）—— 名称自动派生，可切到「手动配置」调整", String(defs[0].name), String(defs[0].transport == .remote ? L10n.text("remote", zhHans: "远程") : "stdio"))
                    : L10n.format("Parsed %@ servers: %@", zhHans: "解析出 %@ 个 server：%@", String(defs.count), String(defs.map(\.name).joined(separator: L10n.text(", ", zhHans: "、")))))))
            .font(Theme.font.themed(9.5))
            .foregroundStyle(defs.isEmpty && !quickText.isEmpty
                ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        HStack(spacing: 6) {
            TagChip(L10n.text("Transport detected automatically", zhHans: "自动识别传输方式"), neutral: true)
            TagChip(L10n.text("Name derived automatically", zhHans: "名称自动派生"), neutral: true)
            TagChip(L10n.text("Backup before writing", zhHans: "写前自动备份"), neutral: true)
        }
    }

    // MARK: - JSON mode (synced with the form)

    @ViewBuilder
    private var jsonEditor: some View {
        fieldColumn(L10n.text("JSON (a whole mcpServers object is fine; every server is written to the selected targets)", zhHans: "JSON（支持整段 mcpServers 对象；多个 server 会全部写入所选目标）")) {
            TextEditor(text: $pasteText)
                .font(Theme.font.themed(11.5, .regular))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .fill(Theme.surfaceSecondary))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        let defs = parsedDefinitions
        Text(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("Example: {\"mcpServers\": {\"context7\": {\"command\": \"npx\", \"args\": [\"-y\", \"@upstash/context7-mcp\"]}}}", zhHans: "示例：{\"mcpServers\": {\"context7\": {\"command\": \"npx\", \"args\": [\"-y\", \"@upstash/context7-mcp\"]}}}")
            : (defs.isEmpty
                ? L10n.text("No servers parsed — check that the JSON is complete", zhHans: "没有解析出任何 server —— 检查 JSON 是否完整")
                : L10n.format("Parsed %@ servers: %@", zhHans: "解析出 %@ 个 server：%@", String(defs.count), String(defs.map(\.name).joined(separator: L10n.text(", ", zhHans: "、"))))))
            .font(Theme.font.themed(9.5))
            .foregroundStyle(defs.isEmpty && !pasteText.isEmpty
                ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
    }

    /// Tab interop: values are carried over when switching Quick install / Manual / JSON
    /// (with multiple servers the form shows only the first; submitting from the original tab still
    /// writes all of them)
    private func switchMode(_ new: MCPFormTarget.Mode) {
        guard new != mode else { return }
        switch new {
        case .paste:
            let trimmedQuick = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .quick, trimmedQuick.hasPrefix("{") {
                pasteText = trimmedQuick  // the quick box already holds JSON; carry it over as-is (multiple servers aren't lost)
            } else {
                if mode == .quick, let first = parsedQuick.first {
                    populate(from: first, keepName: false)
                }
                pasteText = renderCurrentJSON()
            }
        case .form:
            let defs = mode == .quick ? parsedQuick : parsedDefinitions
            if let first = defs.first {
                populate(from: first, keepName: isEditing)
                if defs.count > 1 {
                    resultNote = L10n.format("Parsed %@ servers. The form shows only the first; submit from the original tab to write all of them.", zhHans: "解析出 %@ 个 server，表单只显示第一个；回原页签提交可全部写入", String(defs.count))
                }
            } else if mode == .paste,
                      !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultNote = L10n.text("JSON did not parse into a server; the form was left unchanged", zhHans: "JSON 未解析出 server，保留原表单内容")
            }
        case .quick:
            break  // the quick input box keeps the user's original text
        }
        mode = new
    }

    private func renderCurrentJSON() -> String {
        let definition = formDefinition()
        let hasBody = definition.command != nil || definition.url != nil
        guard hasBody || !definition.name.isEmpty else {
            return """
            {
              "mcpServers": {
                "my-mcp-server": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-memory"]
                }
              }
            }
            """
        }
        let key = definition.name.isEmpty ? "my-mcp-server" : definition.name
        let object: [String: Any] = [
            "mcpServers": [key: MCPServerEditor.encode(definition, style: .typed)]
        ]
        return (try? MCPServerEditor.serialize(object)) ?? "{}"
    }

    private func populate(from definition: MCPServerDefinition, keepName: Bool) {
        if !keepName { name = definition.name }
        isRemote = definition.transport == .remote
        command = definition.command ?? ""
        argsText = definition.args.joined(separator: " ")
        urlText = definition.url ?? ""
        timeoutText = definition.timeout.map(String.init) ?? ""
        envRows = definition.env.keys.sorted().map {
            KVRow(key: $0, value: definition.env[$0] ?? "")
        }
        headerRows = definition.headers.keys.sorted().map {
            KVRow(key: $0, value: definition.headers[$0] ?? "")
        }
        envExpanded = !envRows.isEmpty
        headersExpanded = !headerRows.isEmpty
    }

    private func hydrate() {
        guard !loaded else { return }
        loaded = true
        mode = target.mode
        guard let entry = target.editing else { return }
        name = entry.name
        // Prefill current values (including env/headers): editing must show the values — this
        // doesn't widen exposure (the detail page already has "Open config file in default editor",
        // which shows the whole file in plain text); values are still never persisted to the DB,
        // logged, or uploaded.
        service.definition(of: entry) { definition in
            guard let definition else {
                resultNote = L10n.text("Couldn’t read the existing definition", zhHans: "读取现有定义失败")
                return
            }
            populate(from: definition, keepName: true)
            if target.expandCredentials {
                if isRemote { headersExpanded = true } else { envExpanded = true }
            }
        }
    }

    // MARK: - Scope / targets

    private var availableTargets: [AgentSource] { MCPService.writableSources }

    private var targetsBlock: some View {
        fieldColumn(L10n.text("Install into (select one or more)", zhHans: "安装到（可多选）")) {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(availableTargets, id: \.self) { source in
                        targetChip(source)
                    }
                    projectChip
                }
                if projectInstall { projectPicker }
                if !selectedTargets.isEmpty {
                    Text(selectedTargets
                        .compactMap { MCPService.writableTarget(for: $0)?.configURL.path }
                        .sorted()
                        .joined(separator: "\n"))
                        .font(Theme.font.themed(9, .regular))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Project-level install toggle (a .mcp.json shared with the repo, MCP's official project
    /// standard)
    private var projectChip: some View {
        Button { projectInstall.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.plus")
                    .font(Theme.font.themed(10))
                Text(L10n.text("Project (.mcp.json)", zhHans: "项目级（.mcp.json）"))
                    .font(Theme.font.themed(11, projectInstall ? .semibold : .regular))
                if projectInstall {
                    Image(systemName: "checkmark").font(Theme.font.themed(8, .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(projectInstall ? Theme.brandFill(0.14) : Theme.surface))
            .overlay(Capsule().strokeBorder(
                projectInstall ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                lineWidth: projectInstall ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .help(L10n.text("Writes .mcp.json at the repo root and shares it with the project (the Claude convention). Cursor’s project config can be written too.", zhHans: "写入仓库根的 .mcp.json，随项目共享（claude 约定）；可一并写 cursor 的项目配置"))
    }

    /// Repo picker: recent projects (roots found by the scan) + browse fallback; cursor project
    /// config is optional
    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                MenuButton(
                    title: projectRootPath.isEmpty
                        ? L10n.text("Choose a project", zhHans: "选择项目") : String(projectRootPath.split(separator: "/").last ?? ""),
                    icon: "folder"
                ) {
                    ForEach(service.repoRoots, id: \.root) { candidate in
                        Button(candidate.name.isEmpty
                            ? candidate.root.lastPathComponent
                            : L10n.format("%@ (%@)", zhHans: "%@（%@）", String(candidate.name), String(candidate.root.lastPathComponent))) {
                            projectRootPath = candidate.root.path
                        }
                    }
                }
                Button(L10n.text("Browse…", zhHans: "浏览…")) { browseProjectRoot() }
                    .font(Theme.font.themed(11))
                Spacer()
            }
            if !projectRootPath.isEmpty {
                Text("""
                \(projectRootPath)/.mcp.json\(projectCursorToo
                    ? "\n\(projectRootPath)/.cursor/mcp.json" : "")
                """)
                    .font(Theme.font.themed(9, .regular))
                    .foregroundStyle(.tertiary)
            }
            Toggle(isOn: $projectCursorToo) {
                Text(L10n.text("Also write Cursor’s project config (.cursor/mcp.json)", zhHans: "同时写 cursor 的项目配置（.cursor/mcp.json）"))
                    .font(Theme.font.themed(11))
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radius.container).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.container)
            .strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }

    private func browseProjectRoot() {
        if let picked = mcpPickProjectRoot() { projectRootPath = picked }
    }

    private func targetChip(_ source: AgentSource) -> some View {
        let isSelected = selectedTargets.contains(source)
        return Button {
            if isSelected {
                selectedTargets.remove(source)
            } else {
                selectedTargets.insert(source)
            }
        } label: {
            HStack(spacing: 5) {
                SourceBadge(source: source, size: 12)
                Text(source.displayName)
                    .font(Theme.font.themed(11, isSelected ? .semibold : .regular))
                if isSelected {
                    Image(systemName: "checkmark").font(Theme.font.themed(8, .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Theme.brandFill(0.14) : Theme.surface))
            .overlay(Capsule().strokeBorder(
                isSelected ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                lineWidth: isSelected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Submit

    private var footerHint: String {
        if let entry = target.editing {
            return L10n.format("Rewrite in place %@", zhHans: "原位改写 %@", String(entry.configPath))
        }
        let globalCount = selectedTargets.count
        if validProjectInstall {
            return globalCount == 0
                ? L10n.text("Write project .mcp.json (backup before writing)", zhHans: "写入项目级 .mcp.json（写前留备份）")
                : L10n.format("Write global config for %@ agents plus project .mcp.json (backup each before writing)", zhHans: "写入 %@ 个 agent 的全局配置 + 项目级 .mcp.json（写前各留备份）", String(globalCount))
        }
        if selectedTargets.isEmpty { return L10n.text("Select at least one target agent", zhHans: "选择至少一个目标 agent") }
        return L10n.format("Write global config for %@ agents (backup each before writing)", zhHans: "写入 %@ 个 agent 的全局配置（写前各留备份）", String(globalCount))
    }

    /// Project-level install is valid = toggle on + non-empty repo root path
    private var validProjectInstall: Bool {
        projectInstall && !projectRootPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool {
        if mode == .quick {
            return !parsedQuick.isEmpty && hasAnyTarget
        }
        if mode == .paste {
            guard !parsedDefinitions.isEmpty else { return false }
            return isEditing || hasAnyTarget
        }
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasBody = isRemote
            ? !urlText.trimmingCharacters(in: .whitespaces).isEmpty
            : !command.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return hasName && hasBody }
        return hasName && hasBody && hasAnyTarget
    }

    private var hasAnyTarget: Bool { !selectedTargets.isEmpty || validProjectInstall }

    private var parsedDefinitions: [MCPServerDefinition] {
        MCPServerEditor.parsePasted(pasteText)
    }

    private func formDefinition() -> MCPServerDefinition {
        func pairs(_ rows: [KVRow]) -> [String: String] {
            var result: [String: String] = [:]
            for row in rows where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
                result[row.key.trimmingCharacters(in: .whitespaces)] = row.value
            }
            return result
        }
        let args = argsText.split(separator: " ").map(String.init)
        return MCPServerDefinition(
            name: name.trimmingCharacters(in: .whitespaces),
            transport: isRemote ? .remote : .stdio,
            command: isRemote ? nil : command.trimmingCharacters(in: .whitespaces),
            args: isRemote ? [] : args,
            env: isRemote ? [:] : pairs(envRows),
            url: isRemote ? urlText.trimmingCharacters(in: .whitespaces) : nil,
            headers: isRemote ? pairs(headerRows) : [:],
            timeout: isRemote
                ? Int(timeoutText.trimmingCharacters(in: .whitespaces))
                : nil)
    }

    private func submit() {
        submitting = true
        resultNote = L10n.text("Writing…", zhHans: "正在写入…")
        // Edit: rewrite the entry in place in its config (JSON mode too — takes the first server
        // and forces the name back to the original)
        if let entry = target.editing {
            var definition = mode == .form
                ? formDefinition()
                : (parsedDefinitions.first ?? formDefinition())
            definition.name = entry.name
            service.update(entry, definition: definition) { failure in
                submitting = false
                if let failure {
                    resultNote = L10n.format("Save failed: %@", zhHans: "保存失败：%@", String(failure))
                } else {
                    onBack()
                }
            }
            return
        }
        let definitions: [MCPServerDefinition]
        switch mode {
        case .form: definitions = [formDefinition()]
        case .quick: definitions = parsedQuick
        case .paste: definitions = parsedDefinitions
        }
        guard !definitions.isEmpty else {
            submitting = false
            return
        }
        // Global targets + project-level targets proceed in parallel, results aggregated together
        // (project-level entries get their own prefix so they aren't confused with same-named
        // sources)
        var projectSources: [AgentSource] = [.claude]
        if projectCursorToo { projectSources.append(.cursor) }
        let useProject = validProjectInstall
        let projectRoot = URL(fileURLWithPath:
            projectRootPath.trimmingCharacters(in: .whitespaces))
        service.addAll(definitions: definitions, to: Array(selectedTargets)) { global in
            guard useProject else {
                reportInstallResults(global: global, project: nil)
                return
            }
            service.installToProject(
                definitions: definitions, sources: projectSources, projectRoot: projectRoot
            ) { project in
                reportInstallResults(global: global, project: project)
            }
        }
    }

    private func reportInstallResults(
        global: [AgentSource: String?], project: [AgentSource: String?]?
    ) {
        submitting = false
        var failures: [String] = []
        for (source, error) in global.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let error { failures.append(L10n.format("%@: %@", zhHans: "%@：%@", String(source.displayName), String(error))) }
        }
        if let project {
            for (source, error) in project.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let error { failures.append(L10n.format("Project %@: %@", zhHans: "项目级 %@：%@", String(source.displayName), String(error))) }
            }
        }
        if failures.isEmpty {
            onBack()
        } else {
            resultNote = L10n.text("Partial failure — ", zhHans: "部分失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
        }
    }
}
