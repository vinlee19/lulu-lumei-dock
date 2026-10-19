import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// Agent configuration: stat tiles (click to filter by CLI) + card grid + inline detail, same
/// interaction language as the Plans page. Claude/OpenCode/Grok are per-file markdown, editable /
/// toggleable / deletable; Kimi's are built-in and read-only; Codex uses `[profiles.*]` presets in
/// config.toml, added / edited / removed through an inline form.
struct AgentsView: View {
    @ObservedObject var service: AgentConfigService
    @ObservedObject var usageService: UsageService

    /// Inline agent detail (markdown preview / edit; read-only overview for built-in agents)
    @State private var detail: AgentDefinition?
    /// Inline Codex profile form (including create)
    @State private var profileDetail: ProfileEditTarget?
    /// Source filter (nil = all)
    @State private var selectedSource: AgentSource?
    @State private var creatingAgent = false
    @State private var creatingKind: AgentCreateKind = .claude
    @State private var newAgentName = ""
    @State private var deletingAgent: AgentDefinition?
    @State private var deletingProfile: CodexProfile?
    /// Management area layout: list / icon grid (list by default, matching the design mock)
    @State private var layout: KnowledgeLayout = .list

    /// Offscreen rendering / previews only: sets the initial layout (LayoutToggle switches it
    /// during interaction)
    init(service: AgentConfigService, usageService: UsageService,
         initialLayout: KnowledgeLayout = .list) {
        self._service = ObservedObject(wrappedValue: service)
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._layout = State(initialValue: initialLayout)
    }

    var body: some View {
        Group {
            if let target = profileDetail {
                CodexProfileDetailView(
                    service: service, target: target,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { profileDetail = nil } },
                    onDelete: { deletingProfile = $0 })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let agent = detail {
                AgentDetailView(
                    agent: agent, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deletingAgent = agent })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .onAppear {
            service.refresh()
            usageService.loadAgentStats()
        }
        .alert(createAlertTitle, isPresented: $creatingAgent) {
            TextField(L10n.text("Name", zhHans: "名称"), text: $newAgentName)
            Button(L10n.text("Create", zhHans: "创建")) {
                let name = newAgentName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    switch creatingKind {
                    case .claude: service.createClaudeAgent(name: name)
                    case .opencode: service.createOpencodeAgent(name: name)
                    case .grok: service.createGrokAgent(name: name)
                    case .cursor: service.createCursorAgent(name: name)
                    }
                }
                newAgentName = ""
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) { newAgentName = "" }
        }
        .confirmationDialog(
            deletingAgent.map {
                L10n.format(
                    "Delete agent “%@”? The file moves to the Trash and can be restored.",
                    zhHans: "删除 agent「%@」？文件会移入废纸篓，可恢复。",
                    $0.name)
            } ?? "",
            isPresented: deletingAgentBinding, titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                if let a = deletingAgent { service.deleteAgent(a) }
                detail = nil
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
        .confirmationDialog(
            deletingProfile.map {
                L10n.format(
                    "Delete Codex profile “%@”? This removes that table from config.toml.",
                    zhHans: "删除 Codex profile「%@」？会从 config.toml 移除该段。",
                    $0.name)
            } ?? "",
            isPresented: deletingProfileBinding, titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                if let p = deletingProfile { service.deleteProfile(name: p.name) }
                profileDetail = nil
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    // MARK: - Top bar (title + search + new + refresh + layout toggle)

    private var header: some View {
        HStack(spacing: 12) {
            Text("Agents").font(Theme.font.themed(15, .bold))
            SearchField(
                placeholder: L10n.text("Search subagents", zhHans: "搜索子代理"), text: $service.searchText,
                scanning: service.scanning, resultCount: totalCount)
            Spacer(minLength: 12)
            createMenu
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: L10n.text("Force rescan agents / profiles", zhHans: "强制重扫 agent / profile")) { service.refresh(force: true) }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var createMenu: some View {
        RoundGlyphMenu(icon: "plus", help: L10n.text("New subagent / Codex profile", zhHans: "新建子代理 / Codex profile")) {
            Button("Claude Agent") { startCreate(.claude) }
            Button("OpenCode Agent") { startCreate(.opencode) }
            Button("Grok Agent") { startCreate(.grok) }
            Button("Cursor Agent") { startCreate(.cursor) }
            Button("Codex Profile") {
                profileDetail = ProfileEditTarget(id: "new", profile: CodexProfile(name: ""), isNew: true)
            }
        }
    }

    private var createAlertTitle: String {
        switch creatingKind {
        case .claude: return L10n.text("New Claude Agent", zhHans: "新建 Claude Agent")
        case .opencode: return L10n.text("New OpenCode Agent", zhHans: "新建 OpenCode Agent")
        case .grok: return L10n.text("New Grok Agent", zhHans: "新建 Grok Agent")
        case .cursor: return L10n.text("New Cursor Agent", zhHans: "新建 Cursor Agent")
        }
    }

    private func startCreate(_ kind: AgentCreateKind) {
        newAgentName = ""
        creatingKind = kind
        creatingAgent = true
    }

    // MARK: - Unified entries (agents from every source merged with Codex profiles)

    /// Subagent invocation counts (Claude/Kimi; key = source:lowercased name)
    private var callsByKey: [String: Int] {
        var map: [String: Int] = [:]
        for stat in usageService.agentStats {
            map["\(stat.source.rawValue):\(stat.name.lowercased())"] = stat.count
        }
        return map
    }

    /// All subagents (Claude user/project/plugin/built-in + OpenCode + Grok + Kimi built-in + ZCode
    /// snapshot + Codex profiles)
    private var allItems: [AgentItem] {
        let calls = callsByKey
        func item(_ agent: AgentDefinition) -> AgentItem {
            AgentItem(
                id: agent.path.isEmpty ? "\(agent.source.rawValue):builtin:\(agent.name)" : agent.path,
                source: agent.source, name: agent.name, description: agent.description,
                role: AgentRole.classify(name: agent.name, description: agent.description),
                model: normalizeModelName(agent.model),
                toolCount: agent.tools.count,
                builtin: agent.builtin, enabled: agent.enabled,
                canToggle: !agent.builtin && agent.pluginName == nil && !agent.path.isEmpty,
                calls: calls["\(agent.source.rawValue):\(agent.name.lowercased())"],
                path: agent.path,
                deletable: !agent.path.isEmpty && !agent.builtin && agent.pluginName == nil,
                projectName: agent.scope.projectName, pluginName: agent.pluginName,
                definition: agent, profile: nil)
        }
        var items: [AgentItem] = []
        items += (service.claudeAgents + service.pluginAgents + service.builtinAgents).map(item)
        items += service.opencodeAgents.map(item)
        items += service.grokAgents.map(item)
        items += service.cursorAgents.map(item)
        items += service.kimiBuiltinAgents.map(item)
        items += service.zcodeAgents.map(item)
        items += service.codexProfiles.map { profile in
            AgentItem(
                id: "codex:\(profile.name)", source: .codex, name: profile.name, description: nil,
                role: AgentRole.classify(name: profile.name),
                model: normalizeModelName(profile.model),
                toolCount: nil, builtin: false, enabled: true, canToggle: false,
                calls: nil, path: "", deletable: true,
                projectName: nil, pluginName: nil, definition: nil, profile: profile)
        }
        return items
    }

    private var filteredItems: [AgentItem] {
        allItems
            .filter { selectedSource == nil || $0.source == selectedSource }
            .sorted {
                let lc = $0.calls ?? -1, rc = $1.calls ?? -1
                if lc != rc { return lc > rc }
                return $0.name.lowercased() < $1.name.lowercased()
            }
    }

    private var totalCount: Int { allItems.count }

    private func count(for source: AgentSource) -> Int {
        allItems.lazy.filter { $0.source == source }.count
    }

    private var availableSources: [AgentSource] {
        var seen = Set<AgentSource>()
        let distinct = allItems.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
        return distinct.sorted { count(for: $0) > count(for: $1) }
    }

    /// Model distribution (stat card legend; shades of purple, top 4 + other)
    private var modelSegments: [StatOverviewCard.Segment] {
        var counts: [String: Int] = [:]
        for item in allItems { counts[item.model, default: 0] += 1 }
        let ranked = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let shades: [Double] = [1.0, 0.78, 0.6, 0.45]
        var segments: [StatOverviewCard.Segment] = []
        var other = 0
        for (index, entry) in ranked.enumerated() {
            if index < 4 {
                segments.append(.init(label: entry.key, count: entry.value,
                                      color: Theme.brand.opacity(shades[index])))
            } else {
                other += entry.value
            }
        }
        if other > 0 {
            segments.append(.init(label: L10n.text("Other", zhHans: "其他"), count: other, color: Theme.brand.opacity(0.3)))
        }
        return segments
    }

    // MARK: - Body (stat overview card + source chips + flat list / grid)

    private let gridColumns = KnowledgeGrid.columns

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: "person.2.fill",
                    totalCount: totalCount,
                    sources: availableSources,
                    count: { count(for: $0) })
                if filteredItems.isEmpty {
                    emptyState.padding(.top, 40)
                } else if layout == .cards {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(filteredItems) { item in
                            AgentCard(item: item, service: service,
                                      onOpen: { open(item) }, onToggle: { toggle(item) },
                                      onDelete: { requestDelete(item) })
                        }
                    }
                } else {
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                AgentRow(item: item, service: service,
                                         onOpen: { open(item) }, onToggle: { toggle(item) },
                                         onDelete: { requestDelete(item) })
                                if index < filteredItems.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
                if let error = service.lastError {
                    Text(error).font(Theme.font.themed(10)).foregroundStyle(.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    private var statsCard: some View {
        let enabled = allItems.filter(\.enabled).count
        return StatOverviewCard(
            value: "\(totalCount)", unit: L10n.text("subagents", zhHans: "子代理"),
            subtitle: L10n.format(
                "%1$@ enabled / %2$@ disabled",
                zhHans: "启用 %1$@ / 停用 %2$@",
                String(enabled), String(totalCount - enabled)),
            distributionTitle: L10n.text("Models", zhHans: "模型分布"),
            segments: modelSegments,
            showBar: false)
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.text("Scanning…", zhHans: "正在扫描…")).font(Theme.font.themed(12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                icon: "person.2.fill",
                title: service.isSearching || selectedSource != nil
                    ? L10n.text("No matching subagents", zhHans: "没有匹配的子代理")
                    : L10n.text("No subagents yet", zhHans: "还没有子代理"),
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : L10n.text(
                        "Use + at the top right to create a subagent for each CLI, or a Codex profile",
                        zhHans: "点右上角「＋」新建各 CLI 的子代理或 Codex profile"))
        }
    }

    // MARK: - Action routing

    private func open(_ item: AgentItem) {
        withAnimation(.easeOut(duration: 0.15)) {
            if let profile = item.profile {
                profileDetail = ProfileEditTarget(id: profile.name, profile: profile, isNew: false)
            } else if let definition = item.definition {
                detail = definition
            }
        }
    }

    private func toggle(_ item: AgentItem) {
        guard item.canToggle, let definition = item.definition else { return }
        service.setAgentEnabled(definition, !definition.enabled)
    }

    private func requestDelete(_ item: AgentItem) {
        if let profile = item.profile {
            deletingProfile = profile
        } else if let definition = item.definition {
            deletingAgent = definition
        }
    }

    private var deletingAgentBinding: Binding<Bool> {
        Binding(get: { deletingAgent != nil }, set: { if !$0 { deletingAgent = nil } })
    }
    private var deletingProfileBinding: Binding<Bool> {
        Binding(get: { deletingProfile != nil }, set: { if !$0 { deletingProfile = nil } })
    }
}

// MARK: - Data carriers

enum AgentCreateKind { case claude, opencode, grok, cursor }

struct ProfileEditTarget: Identifiable {
    let id: String
    var profile: CodexProfile
    var isNew: Bool
}

// MARK: - Unified entry + card / list row

/// Unified subagent entry (merges AgentDefinition and CodexProfile so avatar / tags / model render
/// the same way)
private struct AgentItem: Identifiable {
    let id: String
    let source: AgentSource
    let name: String
    let description: String?
    let role: AgentRole
    let model: String
    let toolCount: Int?      // nil = Codex profile; 0 = inherits all tools
    let builtin: Bool
    let enabled: Bool
    let canToggle: Bool
    let calls: Int?          // invocation count (Claude/Kimi have data, others nil)
    let path: String
    let deletable: Bool
    let projectName: String?
    let pluginName: String?
    let definition: AgentDefinition?
    let profile: CodexProfile?

    var toolLabel: String? {
        guard let toolCount else { return nil }
        return toolCount == 0 ? L10n.text("All tools", zhHans: "全部工具") : L10n.format("%@ tools", zhHans: "%@ 工具", String(toolCount))
    }
}

private func agentItemActions(
    _ item: AgentItem, service: AgentConfigService, onDelete: @escaping () -> Void
) -> [CardAction] {
    if item.profile != nil {
        return [CardAction(icon: "trash", destructive: true, help: L10n.text("Remove this table from config.toml", zhHans: "从 config.toml 移除该段")) { onDelete() }]
    }
    var acts: [CardAction] = []
    if !item.path.isEmpty {
        acts.append(CardAction(icon: "pencil", help: L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: item.path) })
        acts.append(CardAction(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: item.path) })
    }
    if item.deletable {
        acts.append(CardAction(icon: "trash", destructive: true, help: L10n.text("Move to Trash (can be restored)", zhHans: "移入废纸篓（可恢复）")) { onDelete() })
    }
    return acts
}

@ViewBuilder
private func agentItemMenu(
    _ item: AgentItem, service: AgentConfigService,
    onOpen: @escaping () -> Void, onToggle: @escaping () -> Void, onDelete: @escaping () -> Void
) -> some View {
    if item.profile != nil {
        Button(L10n.text("Edit", zhHans: "编辑")) { onOpen() }
        Divider()
        Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) { onDelete() }
    } else {
        Button(item.deletable ? L10n.text("View / Edit", zhHans: "查看 / 编辑") : L10n.text("View", zhHans: "查看")) { onOpen() }
        if item.canToggle { Button(item.enabled ? L10n.text("Disable", zhHans: "停用") : L10n.text("Enable", zhHans: "启用")) { onToggle() } }
        if !item.path.isEmpty {
            Button(L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: item.path) }
            Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: item.path) }
        }
        if item.deletable {
            Divider()
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) { onDelete() }
        }
    }
}

/// Subagent icon card: role avatar + name + role tag / source logo + toggle; description; model ·
/// tool count · invocations
private struct AgentCard: View {
    let item: AgentItem
    let service: AgentConfigService
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeCard(
            enabled: item.enabled, minHeight: 96,
            actions: agentItemActions(item, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    RoleAvatar(role: item.role, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                            .font(Theme.font.monoSkillName(13))
                            .foregroundStyle(item.enabled ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.tail)
                            .help(item.name)
                        HStack(spacing: 5) {
                            RoleTag(role: item.role)
                            SourceBadge(source: item.source, size: 12)
                            AgentScopeChips(item: item)
                        }
                    }
                    Spacer(minLength: 4)
                    AgentEnableControl(item: item, onToggle: onToggle)
                }
                Text(item.description ?? "")
                    .font(Theme.font.themed(11)).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).lineSpacing(1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    ModelChip(model: item.model)
                    if let tools = item.toolLabel {
                        Text(tools).font(Theme.font.themedMono(10)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let calls = item.calls {
                        Text(L10n.format("Called %@ times", zhHans: "调用 %@ 次", String(calls)))
                            .font(Theme.font.themedMono(10)).foregroundStyle(.tertiary)
                    }
                }
            }
        } menu: {
            agentItemMenu(item, service: service, onOpen: onOpen, onToggle: onToggle, onDelete: onDelete)
        }
    }
}

/// Subagent list row: role avatar + name / role tag / built-in badge + description + model ·
/// invocations + toggle
private struct AgentRow: View {
    let item: AgentItem
    let service: AgentConfigService
    let onOpen: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeRow(
            enabled: item.enabled,
            actions: agentItemActions(item, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                RoleAvatar(role: item.role, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .foregroundStyle(item.enabled ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.tail)
                        SourceBadge(source: item.source, size: 12)
                        RoleTag(role: item.role)
                        AgentScopeChips(item: item)
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(Theme.font.themed(10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
        } menu: {
            agentItemMenu(item, service: service, onOpen: onOpen, onToggle: onToggle, onDelete: onDelete)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 12) {
            Text(item.model).font(Theme.font.themed(11)).foregroundStyle(.secondary)
            if let calls = item.calls {
                Text(L10n.format("Called %@ times", zhHans: "调用 %@ 次", String(calls)))
                    .font(Theme.font.themedMono(10.5)).foregroundStyle(.tertiary)
            }
            AgentEnableControl(item: item, onToggle: onToggle)
        }
    }
}

/// Where an agent comes from beyond its CLI: built-in, a plugin, or a project. Same-name agents
/// from different places stay separate rows, and these chips are what tells them apart.
private struct AgentScopeChips: View {
    let item: AgentItem

    var body: some View {
        if item.builtin { TagChip(L10n.text("Built-in", zhHans: "内置"), neutral: true) }
        if let plugin = item.pluginName {
            TagChip(L10n.format("Plugin · %@", zhHans: "插件 · %@", plugin), neutral: true)
        }
        if let project = item.projectName { TagChip(project) }
    }
}

/// The enable switch only where enabling can actually change; built-in, plugin-provided and
/// file-less entries show a read-only label instead of a switch that would do nothing.
private struct AgentEnableControl: View {
    let item: AgentItem
    let onToggle: () -> Void

    var body: some View {
        if item.canToggle {
            MiniSwitch(isOn: item.enabled) { onToggle() }
        } else {
            TagChip(L10n.text("Read-only", zhHans: "只读"), neutral: true)
                .help(readOnlyReason)
        }
    }

    private var readOnlyReason: String {
        if item.builtin {
            return L10n.text("Built into the CLI; it cannot be turned off here", zhHans: "CLI 内置，不能在这里停用")
        }
        if item.pluginName != nil {
            return L10n.text("Provided by a plugin; manage it with the plugin", zhHans: "由插件提供，请在插件里管理")
        }
        return L10n.text("No definition file to change", zhHans: "没有可修改的定义文件")
    }
}

// MARK: - Inline agent detail (markdown preview / edit; read-only overview for built-ins)

private struct AgentDetailView: View {
    let agent: AgentDefinition
    let service: AgentConfigService
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?

    init(
        agent: AgentDefinition, service: AgentConfigService,
        onBack: @escaping () -> Void, onDelete: @escaping () -> Void
    ) {
        self.agent = agent
        self.service = service
        self.onBack = onBack
        self.onDelete = onDelete
        // Load in init to avoid a blank first frame (agent definitions are all small files)
        _text = State(initialValue: agent.path.isEmpty
            ? "" : (service.readContent(path: agent.path) ?? ""))
    }

    private var hasFile: Bool { !agent.path.isEmpty }
    /// Plugin files are managed by Claude Code → read-only preview; user-created ones are editable
    private var editable: Bool { hasFile && !agent.builtin && agent.pluginName == nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !hasFile {
                builtinOverview
            } else if editing {
                TextEditor(text: $text)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
                    .padding(8)
            } else {
                MarkdownDocumentCard(text: text)
            }
            if hasFile {
                Divider()
                footer
            }
        }
    }

    /// Built-in agent (no file on disk): description + config overview
    private var builtinOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let desc = agent.description, !desc.isEmpty {
                    Text(desc)
                        .font(Theme.font.themed(12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if let model = agent.model { infoBadge("model: \(model)") }
                    infoBadge(agent.tools.isEmpty ? L10n.text("All tools", zhHans: "全部工具") : L10n.format("%@ tools", zhHans: "%@ 个工具", String(agent.tools.count)))
                    infoBadge(L10n.text("Built-in (may change across versions)", zhHans: "内置（随版本可能变化）"))
                }
            }
            .padding(Theme.spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoBadge(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.brandFill(0.08), in: Capsule())
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
            SourceBadge(source: agent.source, size: 12)
            Text(agent.name)
                .font(Theme.font.themed(13, .semibold))
                .lineLimit(1)
            if let project = agent.scope.projectName {
                TagChip(project)
            }
            Spacer(minLength: 8)
            if editable {
                CapsuleTabTray {
                    CapsuleTabButton(title: L10n.text("Preview", zhHans: "预览"), fillWidth: false, isSelected: !editing) { editing = false }
                    CapsuleTabButton(title: L10n.text("Edit", zhHans: "编辑"), fillWidth: false, isSelected: editing) { editing = true }
                }
            }
            if hasFile {
                Button { service.openInEditor(path: agent.path) } label: {
                    Image(systemName: "square.and.pencil").font(Theme.font.themed(11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Open in default editor", zhHans: "用默认编辑器打开"))
                Button { service.reveal(path: agent.path) } label: {
                    Image(systemName: "folder").font(Theme.font.themed(11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"))
            }
            if editable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(Theme.font.themed(11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Move to Trash (can be restored)", zhHans: "移入废纸篓（可恢复）"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(editable ? agent.path : L10n.format("Managed by Claude Code (read-only) · %@", zhHans: "由 Claude Code 管理（只读） · %@", agent.path))
                .font(Theme.font.monoSkillName(9, weight: .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note = saveNote {
                Text(note)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.secondary)
            }
            if editing {
                PrimaryButton(title: L10n.text("Save", zhHans: "保存"), shortcut: KeyboardShortcut("s", modifiers: .command)) {
                    service.save(path: agent.path, content: text) { ok in
                        saveNote = ok ? L10n.text("Saved (a backup was kept before writing)", zhHans: "已保存（写前留有备份）") : L10n.text("Couldn't save", zhHans: "保存失败")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Inline Codex profile form

private struct CodexProfileDetailView: View {
    let service: AgentConfigService
    let target: ProfileEditTarget
    let onBack: () -> Void
    let onDelete: (CodexProfile) -> Void

    @State private var name = ""
    @State private var model = ""
    @State private var reasoning = ""
    @State private var personality = ""
    @State private var approval = ""
    @State private var loaded = false

    private let reasoningOptions = ["", "minimal", "low", "medium", "high", "xhigh"]
    private let approvalOptions = ["", "untrusted", "on-failure", "on-request", "never"]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            Form {
                TextField(L10n.text("Name", zhHans: "名称"), text: $name)
                    .disabled(!target.isNew)  // name = section name; renaming = creating anew, so lock it
                TextField(L10n.text("model (e.g. gpt-5.5)", zhHans: "model（如 gpt-5.5）"), text: $model)
                Picker("reasoning effort", selection: $reasoning) {
                    ForEach(reasoningOptions, id: \.self) { Text($0.isEmpty ? L10n.text("(Not set)", zhHans: "（不设置）") : $0) }
                }
                TextField(L10n.text("personality (e.g. pragmatic)", zhHans: "personality（如 pragmatic）"), text: $personality)
                Picker("approval policy", selection: $approval) {
                    ForEach(approvalOptions, id: \.self) { Text($0.isEmpty ? L10n.text("(Not set)", zhHans: "（不设置）") : $0) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text(L10n.format("Writes the [profiles.%@] table in ~/.codex/config.toml", zhHans: "写入 ~/.codex/config.toml 的 [profiles.%@] 段", name.isEmpty ? "…" : name))
                    .font(Theme.font.monoSkillName(9, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                PrimaryButton(title: L10n.text("Save", zhHans: "保存")) {
                    service.saveProfile(CodexProfile(
                        name: name.trimmingCharacters(in: .whitespaces),
                        model: nilIfEmpty(model),
                        reasoningEffort: nilIfEmpty(reasoning),
                        personality: nilIfEmpty(personality),
                        approvalPolicy: nilIfEmpty(approval)))
                    onBack()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            name = target.profile.name
            model = target.profile.model ?? ""
            reasoning = target.profile.reasoningEffort ?? ""
            personality = target.profile.personality ?? ""
            approval = target.profile.approvalPolicy ?? ""
        }
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
            SourceBadge(source: .codex, size: 12)
            Text(target.isNew ? L10n.text("New Codex Profile", zhHans: "新建 Codex Profile") : target.profile.name)
                .font(Theme.font.themed(13, .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !target.isNew {
                Button(role: .destructive) { onDelete(target.profile) } label: {
                    Image(systemName: "trash").font(Theme.font.themed(11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Remove this table from config.toml", zhHans: "从 config.toml 移除该段"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
