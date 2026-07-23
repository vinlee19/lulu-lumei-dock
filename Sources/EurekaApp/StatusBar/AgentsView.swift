import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// Agent 配置：统计瓦片（点击按 CLI 筛选）+ 卡片网格 + 内嵌详情，与「计划」页同一套交互语言。
/// Claude/OpenCode/Grok 逐文件 markdown，可编辑/启停/删除；Kimi 为内置只读；
/// Codex 是 config.toml 的 `[profiles.*]` 预设，内嵌表单增删改。
struct AgentsView: View {
    @ObservedObject var service: AgentConfigService

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
    /// 折叠的来源分区（点击分区头折叠/展开）
    @State private var collapsedSources: Set<AgentSource> = []
    /// 管理区布局：卡片网格 / 列表
    @State private var layout: KnowledgeLayout = .cards

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
        .onAppear { service.refresh() }
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

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(placeholder: "搜索 agent / profile", text: $service.searchText, scanning: service.scanning)
            LayoutToggle(layout: $layout)
            Menu {
                Button("Claude Agent") { startCreate(.claude) }
                Button("OpenCode Agent") { startCreate(.opencode) }
                Button("Grok Agent") { startCreate(.grok) }
                Button("Codex Profile") {
                    profileDetail = ProfileEditTarget(
                        id: "new", profile: CodexProfile(name: ""), isNew: true)
                }
            } label: {
                Image(systemName: "plus.circle").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
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

    // MARK: - 计数

    /// Claude 分区条目：用户/项目 agent + 插件 + 内置（一个网格内按此顺序排）
    private var claudeItems: [AgentDefinition] {
        sorted(service.claudeAgents) + service.pluginAgents + service.builtinAgents
    }

    private func items(for source: AgentSource) -> [AgentDefinition] {
        switch source {
        case .claude: return claudeItems
        case .opencode: return sorted(service.opencodeAgents)
        case .grok: return sorted(service.grokAgents)
        case .kimi: return service.kimiBuiltinAgents
        default: return []
        }
    }

    /// 系统级在前，项目级按项目名归并，同组按名称
    private func sorted(_ items: [AgentDefinition]) -> [AgentDefinition] {
        items.sorted {
            let l = $0.scope.projectName ?? ""
            let r = $1.scope.projectName ?? ""
            if l != r { return l < r }
            return $0.name.lowercased() < $1.name.lowercased()
        }
    }

    private func count(for source: AgentSource) -> Int {
        source == .codex ? service.codexProfiles.count : items(for: source).count
    }

    private var totalCount: Int {
        tileSources.reduce(0) { $0 + count(for: $1) }
    }

    /// 瓦片来源：可新建的常显（Claude/OpenCode/Grok/Codex）；Kimi 内置只在有数据时显示
    private var tileSources: [AgentSource] {
        var sources: [AgentSource] = [.claude, .opencode, .grok]
        if !service.kimiBuiltinAgents.isEmpty { sources.append(.kimi) }
        sources.append(.codex)
        return sources
    }

    private var visibleSources: [AgentSource] {
        if let selected = selectedSource {
            return tileSources.contains(selected) ? [selected] : []
        }
        return tileSources
    }

    // MARK: - 主体（统计瓦片 + 分区卡片网格）

    private let gridColumns = [GridItem(.adaptive(minimum: 290), spacing: 14)]

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                statsTiles
                ForEach(visibleSources, id: \.self) { source in
                    sectionContent(source)
                }
                if let error = service.lastError {
                    Text(error)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }
            .padding(Theme.spacing.page)
        }
    }

    private var statsTiles: some View {
        HStack(spacing: 10) {
            StatTile(
                value: "\(totalCount)",
                label: "全部", icon: "person.2.fill",
                tint: Theme.brand,
                isSelected: selectedSource == nil
            ) { selectedSource = nil }
            ForEach(tileSources, id: \.self) { source in
                StatTile(
                    value: "\(count(for: source))",
                    label: source.displayName, source: source,
                    tint: Theme.brand,
                    isSelected: selectedSource == source
                ) { selectedSource = source }
            }
        }
    }

    @ViewBuilder
    private func sectionContent(_ source: AgentSource) -> some View {
        let total = count(for: source)
        // 搜索无命中的分区隐藏；非搜索态空分区常显（带新建占位）
        if total > 0 || !service.isSearching {
            sectionHeader(source: source, count: total)
            if !collapsedSources.contains(source) {
                if source == .codex {
                    if service.codexProfiles.isEmpty {
                        emptySectionRow("暂无 profile", actionTitle: "新建") {
                            profileDetail = ProfileEditTarget(
                                id: "new", profile: CodexProfile(name: ""), isNew: true)
                        }
                    } else {
                        profilesView(service.codexProfiles)
                    }
                } else {
                    let group = items(for: source)
                    if group.isEmpty {
                        if let kind = createKind(for: source) {
                            emptySectionRow("暂无 agent", actionTitle: "新建") { startCreate(kind) }
                        } else {
                            emptySectionRow("暂无 agent")
                        }
                    } else {
                        agentsView(group)
                    }
                }
            }
        }
    }

    /// 按当前布局出 agent 卡片网格或通栏列表
    @ViewBuilder
    private func agentsView(_ group: [AgentDefinition]) -> some View {
        switch layout {
        case .cards:
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                ForEach(group) { agent in
                    AgentCard(
                        agent: agent, service: service,
                        onOpen: { openAgent(agent) },
                        onDelete: { deletingAgent = agent })
                }
            }
        case .list:
            VStack(spacing: 0) {
                ForEach(Array(group.enumerated()), id: \.element.id) { index, agent in
                    AgentRow(
                        agent: agent, service: service,
                        onOpen: { openAgent(agent) },
                        onDelete: { deletingAgent = agent })
                    if index < group.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 12)
                    }
                }
            }
        }
    }

    /// 按当前布局出 Codex profile 卡片网格或通栏列表
    @ViewBuilder
    private func profilesView(_ profiles: [CodexProfile]) -> some View {
        switch layout {
        case .cards:
            LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                ForEach(profiles) { profile in
                    ProfileCard(
                        profile: profile,
                        onOpen: { openProfile(profile) },
                        onDelete: { deletingProfile = profile })
                }
            }
        case .list:
            VStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    ProfileRow(
                        profile: profile,
                        onOpen: { openProfile(profile) },
                        onDelete: { deletingProfile = profile })
                    if index < profiles.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func openAgent(_ agent: AgentDefinition) {
        withAnimation(.easeOut(duration: 0.15)) { detail = agent }
    }

    private func openProfile(_ profile: CodexProfile) {
        withAnimation(.easeOut(duration: 0.15)) {
            profileDetail = ProfileEditTarget(id: profile.name, profile: profile, isNew: false)
        }
    }

    private func createKind(for source: AgentSource) -> AgentCreateKind? {
        switch source {
        case .claude: return .claude
        case .opencode: return .opencode
        case .grok: return .grok
        default: return nil
        }
    }

    /// 分区头：统一 SourceSectionHeader（折叠箭头 + 徽标 + 名称 + 中性计数，与他页一致）
    private func sectionHeader(source: AgentSource, count: Int) -> some View {
        SourceSectionHeader(
            source: source,
            title: source.displayName,
            count: count,
            collapsed: collapsedSources.contains(source),
            onToggle: {
                if collapsedSources.contains(source) {
                    collapsedSources.remove(source)
                } else {
                    collapsedSources.insert(source)
                }
            })
    }

    /// 空分区占位行：小字说明 + 可选内联新建
    private func emptySectionRow(
        _ text: String, actionTitle: String? = nil, action: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderless)
                    .controlSize(.mini)
                    .font(.system(size: 10))
            }
            Spacer(minLength: 0)
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

// MARK: - 卡片

/// agent 卡片：名称 + 启停圆点/内置标 + 描述 + meta（项目/插件/model）；悬停浮现动作
private struct AgentCard: View {
    let agent: AgentDefinition
    let service: AgentConfigService
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var hasFile: Bool { !agent.path.isEmpty }
    /// 用户自建 agent 才可删（插件文件由 Claude Code 管理；内置无文件）
    private var deletable: Bool { hasFile && !agent.builtin && agent.pluginName == nil }

    private var actions: [CardAction] {
        var acts: [CardAction] = []
        if hasFile {
            acts.append(CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: agent.path) })
            acts.append(CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: agent.path) })
        }
        if deletable {
            acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
        }
        return acts
    }

    var body: some View {
        KnowledgeCard(enabled: agent.enabled, height: 128, actions: actions, onOpen: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: agent.source, size: 32)
                    Text(agent.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(agent.enabled ? .primary : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if agent.builtin {
                        TagChip("内置", neutral: true)
                    } else if hasFile {
                        StatusDot(enabled: agent.enabled) {
                            service.setAgentEnabled(agent, !agent.enabled)
                        }
                    }
                }
                if let desc = agent.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if let project = agent.scope.projectName {
                        TagChip(project)
                    } else if let plugin = agent.pluginName {
                        Text("插件 · \(plugin)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let model = agent.model {
                        Text(model)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        } menu: {
            Button(deletable ? "查看 / 编辑" : "查看") { onOpen() }
            if hasFile {
                if !agent.builtin {
                    Button(agent.enabled ? "停用" : "启用") {
                        service.setAgentEnabled(agent, !agent.enabled)
                    }
                }
                Button("用默认编辑器打开") { service.openInEditor(path: agent.path) }
                Button("在 Finder 中显示") { service.reveal(path: agent.path) }
            }
            if deletable {
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            }
        }
    }
}

/// Codex profile 卡片：名称 + 配置摘要；悬停浮现删除
private struct ProfileCard: View {
    let profile: CodexProfile
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        [profile.model.map { "model: \($0)" },
         profile.reasoningEffort.map { "reasoning: \($0)" },
         profile.personality.map { "persona: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        KnowledgeCard(
            height: 128,
            actions: [CardAction(icon: "trash", destructive: true, help: "从 config.toml 移除该段") { onDelete() }],
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: .codex, size: 32)
                    Text(profile.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if let approval = profile.approvalPolicy {
                        Text("approval: \(approval)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        } menu: {
            Button("编辑") { onOpen() }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
    }
}

/// agent 列表行：logo + 名称/描述两行 + model + 启停圆点/内置标；悬停浮现动作
private struct AgentRow: View {
    let agent: AgentDefinition
    let service: AgentConfigService
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var hasFile: Bool { !agent.path.isEmpty }
    private var deletable: Bool { hasFile && !agent.builtin && agent.pluginName == nil }

    private var actions: [CardAction] {
        var acts: [CardAction] = []
        if hasFile {
            acts.append(CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: agent.path) })
            acts.append(CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: agent.path) })
        }
        if deletable {
            acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
        }
        return acts
    }

    var body: some View {
        KnowledgeRow(enabled: agent.enabled, actions: actions, onOpen: onOpen) {
            HStack(spacing: 10) {
                SourceLogoTile(source: agent.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(agent.name)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(agent.enabled ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let project = agent.scope.projectName {
                            TagChip(project)
                        }
                    }
                    if let desc = agent.description, !desc.isEmpty {
                        Text(desc)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    } else if let plugin = agent.pluginName {
                        Text("插件 · \(plugin)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let model = agent.model {
                    Text(model)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if agent.builtin {
                    TagChip("内置", neutral: true)
                } else if hasFile {
                    StatusDot(enabled: agent.enabled) {
                        service.setAgentEnabled(agent, !agent.enabled)
                    }
                }
            }
        } menu: {
            Button(deletable ? "查看 / 编辑" : "查看") { onOpen() }
            if hasFile {
                if !agent.builtin {
                    Button(agent.enabled ? "停用" : "启用") { service.setAgentEnabled(agent, !agent.enabled) }
                }
                Button("用默认编辑器打开") { service.openInEditor(path: agent.path) }
                Button("在 Finder 中显示") { service.reveal(path: agent.path) }
            }
            if deletable {
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            }
        }
    }
}

/// Codex profile 列表行：logo + 名称/摘要两行 + approval；悬停浮现删除
private struct ProfileRow: View {
    let profile: CodexProfile
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        [profile.model.map { "model: \($0)" },
         profile.reasoningEffort.map { "reasoning: \($0)" },
         profile.personality.map { "persona: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        KnowledgeRow(
            actions: [CardAction(icon: "trash", destructive: true, help: "从 config.toml 移除该段") { onDelete() }],
            onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                SourceLogoTile(source: .codex, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let approval = profile.approvalPolicy {
                    Text("approval: \(approval)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        } menu: {
            Button("编辑") { onOpen() }
            Divider()
            Button("删除", role: .destructive) { onDelete() }
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
