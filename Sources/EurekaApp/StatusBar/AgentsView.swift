import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// Agent 配置：统计瓦片（点击按 CLI 筛选）+ 卡片网格 + 内嵌详情，与「计划」页同一套交互语言。
/// Claude/OpenCode/Grok 逐文件 markdown，可编辑/启停/删除；Kimi 为内置只读；
/// Codex 是 config.toml 的 `[profiles.*]` 预设，内嵌表单增删改。
struct AgentsView: View {
    @ObservedObject var service: AgentConfigService
    @ObservedObject var usageService: UsageService

    /// 内嵌 agent 详情（markdown 预览/编辑；内置 agent 只读概览）
    @State private var detail: AgentDefinition?
    /// 内嵌 Codex profile 表单（含新建）
    @State private var profileDetail: ProfileEditTarget?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    @State private var creatingAgent = false
    @State private var creatingKind: AgentCreateKind = .claude
    @State private var newAgentName = ""
    @State private var deletingAgent: AgentDefinition?
    @State private var deletingProfile: CodexProfile?
    /// 管理区布局：列表 / 图标网格（默认列表，对齐设计稿）
    @State private var layout: KnowledgeLayout = .list

    /// 离屏渲染/预览专用：指定初始布局（交互时由 LayoutToggle 切换）
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
            TextField("名称", text: $newAgentName)
            Button("创建") {
                let name = newAgentName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    switch creatingKind {
                    case .claude: service.createClaudeAgent(name: name)
                    case .opencode: service.createOpencodeAgent(name: name)
                    case .grok: service.createGrokAgent(name: name)
                    }
                }
                newAgentName = ""
            }
            Button("取消", role: .cancel) { newAgentName = "" }
        }
        .confirmationDialog(
            deletingAgent.map { "删除 agent「\($0.name)」？文件会移入废纸篓，可恢复。" } ?? "",
            isPresented: deletingAgentBinding, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let a = deletingAgent { service.deleteAgent(a) }
                detail = nil
            }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            deletingProfile.map { "删除 Codex profile「\($0.name)」？会从 config.toml 移除该段。" } ?? "",
            isPresented: deletingProfileBinding, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let p = deletingProfile { service.deleteProfile(name: p.name) }
                profileDetail = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏（标题 + 搜索 + 新建 + 刷新 + 布局切换）

    private var header: some View {
        HStack(spacing: 12) {
            Text("Agents").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: "搜索子代理", text: $service.searchText,
                scanning: service.scanning, resultCount: totalCount)
            Spacer(minLength: 12)
            createMenu
            RefreshButton(help: "刷新 agent / profile") { service.refresh() }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var createMenu: some View {
        Menu {
            Button("Claude Agent") { startCreate(.claude) }
            Button("OpenCode Agent") { startCreate(.opencode) }
            Button("Grok Agent") { startCreate(.grok) }
            Button("Codex Profile") {
                profileDetail = ProfileEditTarget(id: "new", profile: CodexProfile(name: ""), isNew: true)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.brandFill(0.10)))
                .overlay(Circle().strokeBorder(Theme.brand.opacity(0.35), lineWidth: 0.8))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("新建子代理 / Codex profile")
    }

    private var createAlertTitle: String {
        switch creatingKind {
        case .claude: return "新建 Claude Agent"
        case .opencode: return "新建 OpenCode Agent"
        case .grok: return "新建 Grok Agent"
        }
    }

    private func startCreate(_ kind: AgentCreateKind) {
        newAgentName = ""
        creatingKind = kind
        creatingAgent = true
    }

    // MARK: - 统一条目（合并各来源 agent + Codex profile）

    /// 子代理调用次数映射（Claude/Kimi；键 = 来源:小写名）
    private var callsByKey: [String: Int] {
        var map: [String: Int] = [:]
        for stat in usageService.agentStats {
            map["\(stat.source.rawValue):\(stat.name.lowercased())"] = stat.count
        }
        return map
    }

    /// 全部子代理（Claude 用户/项目/插件/内置 + OpenCode + Grok + Kimi 内置 + Codex profile）
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
        items += service.kimiBuiltinAgents.map(item)
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

    /// 模型分布（统计卡图例；紫色系深浅区分，取前 4 + 其他）
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
            segments.append(.init(label: "其他", count: other, color: Theme.brand.opacity(0.3)))
        }
        return segments
    }

    // MARK: - 主体（统计概览卡 + 来源 chips + 扁平列表/网格）

    private let gridColumns = [GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14)]

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: "全部", allIcon: "person.2.fill",
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
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    private var statsCard: some View {
        let enabled = allItems.filter(\.enabled).count
        return StatOverviewCard(
            value: "\(totalCount)", unit: "子代理",
            subtitle: "启用 \(enabled) / 停用 \(totalCount - enabled)",
            distributionTitle: "模型分布",
            segments: modelSegments,
            showBar: false)
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 8) {
                ProgressView()
                Text("正在扫描…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                icon: "person.2.fill",
                title: service.isSearching || selectedSource != nil ? "没有匹配的子代理" : "还没有子代理",
                hint: service.isSearching || selectedSource != nil
                    ? nil : "点右上角「＋」新建各 CLI 的子代理或 Codex profile")
        }
    }

    // MARK: - 动作路由

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

// MARK: - 数据载体

enum AgentCreateKind { case claude, opencode, grok }

struct ProfileEditTarget: Identifiable {
    let id: String
    var profile: CodexProfile
    var isNew: Bool
}

// MARK: - 统一条目 + 卡片 / 列表行

/// 统一子代理条目（合并 AgentDefinition 与 CodexProfile，供角色头像/标签/模型统一渲染）
private struct AgentItem: Identifiable {
    let id: String
    let source: AgentSource
    let name: String
    let description: String?
    let role: AgentRole
    let model: String
    let toolCount: Int?      // nil = Codex profile；0 = 继承全部工具
    let builtin: Bool
    let enabled: Bool
    let canToggle: Bool
    let calls: Int?          // 调用次数（Claude/Kimi 有数据，其余 nil）
    let path: String
    let deletable: Bool
    let projectName: String?
    let pluginName: String?
    let definition: AgentDefinition?
    let profile: CodexProfile?

    var toolLabel: String? {
        guard let toolCount else { return nil }
        return toolCount == 0 ? "全部工具" : "\(toolCount) 工具"
    }
}

private func agentItemActions(
    _ item: AgentItem, service: AgentConfigService, onDelete: @escaping () -> Void
) -> [CardAction] {
    if item.profile != nil {
        return [CardAction(icon: "trash", destructive: true, help: "从 config.toml 移除该段") { onDelete() }]
    }
    var acts: [CardAction] = []
    if !item.path.isEmpty {
        acts.append(CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: item.path) })
        acts.append(CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: item.path) })
    }
    if item.deletable {
        acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
    }
    return acts
}

@ViewBuilder
private func agentItemMenu(
    _ item: AgentItem, service: AgentConfigService,
    onOpen: @escaping () -> Void, onToggle: @escaping () -> Void, onDelete: @escaping () -> Void
) -> some View {
    if item.profile != nil {
        Button("编辑") { onOpen() }
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    } else {
        Button(item.deletable ? "查看 / 编辑" : "查看") { onOpen() }
        if item.canToggle { Button(item.enabled ? "停用" : "启用") { onToggle() } }
        if !item.path.isEmpty {
            Button("用默认编辑器打开") { service.openInEditor(path: item.path) }
            Button("在 Finder 中显示") { service.reveal(path: item.path) }
        }
        if item.deletable {
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

/// 子代理图标卡：角色头像 + 名 + 角色标签/来源 logo + 开关；描述；模型 · 工具数 · 调用次数
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
                            .lineLimit(1).truncationMode(.middle)
                        HStack(spacing: 5) {
                            RoleTag(role: item.role)
                            SourceBadge(source: item.source, size: 12)
                            if item.builtin { TagChip("内置", neutral: true) }
                        }
                    }
                    Spacer(minLength: 4)
                    MiniSwitch(isOn: item.enabled) { onToggle() }
                }
                Text(item.description ?? "")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).lineSpacing(1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    ModelChip(model: item.model)
                    if let tools = item.toolLabel {
                        Text(tools).font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    if let calls = item.calls {
                        Text("调用 \(calls) 次")
                            .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
            }
        } menu: {
            agentItemMenu(item, service: service, onOpen: onOpen, onToggle: onToggle, onDelete: onDelete)
        }
    }
}

/// 子代理列表行：角色头像 + 名/角色标签/内置标 + 描述 + 模型 · 调用次数 + 开关
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
                            .lineLimit(1).truncationMode(.middle)
                        RoleTag(role: item.role)
                        if item.builtin { TagChip("内置", neutral: true) }
                    }
                    if let desc = item.description, !desc.isEmpty {
                        Text(desc).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
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
            Text(item.model).font(.system(size: 11)).foregroundStyle(.secondary)
            if let calls = item.calls {
                Text("调用 \(calls) 次")
                    .font(.system(size: 10.5).monospacedDigit()).foregroundStyle(.tertiary)
            }
            MiniSwitch(isOn: item.enabled) { onToggle() }
        }
    }
}

// MARK: - agent 内嵌详情（markdown 预览/编辑；内置只读概览）

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
        // init 即加载：避免首帧空白（agent 定义均为小文件）
        _text = State(initialValue: agent.path.isEmpty
            ? "" : (service.readContent(path: agent.path) ?? ""))
    }

    private var hasFile: Bool { !agent.path.isEmpty }
    /// 插件文件由 Claude Code 管理 → 只读预览；用户自建可编辑
    private var editable: Bool { hasFile && !agent.builtin && agent.pluginName == nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !hasFile {
                builtinOverview
            } else if editing {
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
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

    /// 内置 agent（无磁盘文件）：描述 + 配置概览
    private var builtinOverview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let desc = agent.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if let model = agent.model { infoBadge("model: \(model)") }
                    infoBadge(agent.tools.isEmpty ? "全部工具" : "\(agent.tools.count) 个工具")
                    infoBadge("内置（随版本可能变化）")
                }
            }
            .padding(Theme.spacing.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func infoBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Theme.brandFill(0.08), in: Capsule())
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceBadge(source: agent.source, size: 12)
            Text(agent.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let project = agent.scope.projectName {
                TagChip(project)
            }
            Spacer(minLength: 8)
            if editable {
                CapsuleTabTray {
                    CapsuleTabButton(title: "预览", fillWidth: false, isSelected: !editing) { editing = false }
                    CapsuleTabButton(title: "编辑", fillWidth: false, isSelected: editing) { editing = true }
                }
            }
            if hasFile {
                Button { service.openInEditor(path: agent.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("用默认编辑器打开")
                Button { service.reveal(path: agent.path) } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("在 Finder 中显示")
            }
            if editable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("移入废纸篓（可恢复）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(editable ? agent.path : "由 Claude Code 管理（只读） · \(agent.path)")
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note = saveNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if editing {
                Button("保存") {
                    service.save(path: agent.path, content: text) { ok in
                        saveNote = ok ? "已保存（写前留有备份）" : "保存失败"
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}

// MARK: - Codex profile 内嵌表单

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
                TextField("名称", text: $name)
                    .disabled(!target.isNew)  // 名称即段名，改名等于新建，避免歧义
                TextField("model（如 gpt-5.5）", text: $model)
                Picker("reasoning effort", selection: $reasoning) {
                    ForEach(reasoningOptions, id: \.self) { Text($0.isEmpty ? "（不设置）" : $0) }
                }
                TextField("personality（如 pragmatic）", text: $personality)
                Picker("approval policy", selection: $approval) {
                    ForEach(approvalOptions, id: \.self) { Text($0.isEmpty ? "（不设置）" : $0) }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Text("写入 ~/.codex/config.toml 的 [profiles.\(name.isEmpty ? "…" : name)] 段")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("保存") {
                    service.saveProfile(CodexProfile(
                        name: name.trimmingCharacters(in: .whitespaces),
                        model: nilIfEmpty(model),
                        reasoningEffort: nilIfEmpty(reasoning),
                        personality: nilIfEmpty(personality),
                        approvalPolicy: nilIfEmpty(approval)))
                    onBack()
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
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
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceBadge(source: .codex, size: 12)
            Text(target.isNew ? "新建 Codex Profile" : target.profile.name)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if !target.isNew {
                Button(role: .destructive) { onDelete(target.profile) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("从 config.toml 移除该段")
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
