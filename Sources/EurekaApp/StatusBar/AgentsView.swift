import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// Agent 配置：Claude agent 定义（系统/项目分栏）+ Codex profiles。
/// Claude 逐文件 markdown，可编辑/启停/删除；Codex 是 config.toml 的 `[profiles.*]` 预设，可增删改。
struct AgentsView: View {
    @ObservedObject var service: AgentConfigService

    @State private var fileEditor: AgentFileEditTarget?
    @State private var profileEditor: ProfileEditTarget?
    @State private var creatingAgent = false
    @State private var creatingKind: AgentCreateKind = .claude
    @State private var newAgentName = ""
    @State private var deletingAgent: AgentDefinition?
    @State private var deletingProfile: CodexProfile?
    /// 已折叠的来源类别（存 AgentSource.rawValue）；默认展开
    @State private var collapsedSources: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { service.refresh() }
        .sheet(item: $fileEditor) { target in
            AgentFileEditorSheet(service: service, target: target)
        }
        .sheet(item: $profileEditor) { target in
            CodexProfileEditorSheet(service: service, target: target)
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
            Button("删除", role: .destructive) { if let a = deletingAgent { service.deleteAgent(a) } }
            Button("取消", role: .cancel) {}
        }
        .confirmationDialog(
            deletingProfile.map { "删除 Codex profile「\($0.name)」？会从 config.toml 移除该段。" } ?? "",
            isPresented: deletingProfileBinding, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let p = deletingProfile { service.deleteProfile(name: p.name) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("搜索 agent / profile", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            Menu {
                Button("Claude Agent") { newAgentName = ""; creatingKind = .claude; creatingAgent = true }
                Button("opencode Agent") { newAgentName = ""; creatingKind = .opencode; creatingAgent = true }
                Button("Grok Agent") { newAgentName = ""; creatingKind = .grok; creatingAgent = true }
                Button("Codex Profile") {
                    profileEditor = ProfileEditTarget(
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

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        // 非搜索态类别常显（空类别带占位），整页空态只在搜索无命中/扫描中出现
        if service.isSearching,
           service.claudeAgents.isEmpty, service.opencodeAgents.isEmpty,
           service.grokAgents.isEmpty, service.kimiBuiltinAgents.isEmpty,
           service.pluginAgents.isEmpty, service.builtinAgents.isEmpty,
           service.codexProfiles.isEmpty {
            VStack(spacing: 8) {
                if service.scanning {
                    ProgressView("正在扫描…")
                } else {
                    Image(systemName: "person.2.badge.gearshape")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.agents.opacity(0.45))
                    Text(service.isSearching ? "没有匹配项" : "还没有 agent / profile")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if !service.isSearching {
                        Text("点右上角 + 新建 Claude / opencode Agent 或 Codex Profile")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // 按来源分类别，每类可折叠；非搜索态空类别也常显（带新建占位）
                    if claudeCount > 0 || !service.isSearching {
                        sourceCategory(.claude, count: claudeCount) {
                            agentSubsections(agents: service.claudeAgents)
                            pluginSections
                            builtinSection
                        }
                    }
                    if opencodeCount > 0 || !service.isSearching {
                        sourceCategory(.opencode, count: opencodeCount) {
                            if service.opencodeAgents.isEmpty {
                                emptyCategoryRow("暂无 agent", actionTitle: "新建") {
                                    newAgentName = ""
                                    creatingKind = .opencode
                                    creatingAgent = true
                                }
                            } else {
                                agentSubsections(agents: service.opencodeAgents)
                            }
                        }
                    }
                    if grokCount > 0 || !service.isSearching {
                        sourceCategory(.grok, count: grokCount) {
                            if service.grokAgents.isEmpty {
                                emptyCategoryRow("暂无 agent", actionTitle: "新建") {
                                    newAgentName = ""
                                    creatingKind = .grok
                                    creatingAgent = true
                                }
                            } else {
                                agentSubsections(agents: service.grokAgents)
                            }
                        }
                    }
                    if kimiCount > 0 || !service.isSearching {
                        sourceCategory(.kimi, count: kimiCount) {
                            kimiBuiltinSection
                        }
                    }
                    if codexCount > 0 || !service.isSearching {
                        sourceCategory(.codex, count: codexCount) {
                            if service.codexProfiles.isEmpty {
                                emptyCategoryRow("暂无 profile", actionTitle: "新建") {
                                    profileEditor = ProfileEditTarget(
                                        id: "new", profile: CodexProfile(name: ""), isNew: true)
                                }
                            } else {
                                codexProfileSection
                            }
                        }
                    }
                    if let error = service.lastError {
                        Text(error)
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 12)
                            .padding(.top, 6)
                    }
                }
            }
        }
    }

    // MARK: - 来源类别（Claude / opencode / Codex 三大可折叠类别）

    private var claudeCount: Int {
        service.claudeAgents.count + service.pluginAgents.count + service.builtinAgents.count
    }
    private var opencodeCount: Int { service.opencodeAgents.count }
    private var grokCount: Int { service.grokAgents.count }
    private var kimiCount: Int { service.kimiBuiltinAgents.count }
    private var codexCount: Int { service.codexProfiles.count }

    private var createAlertTitle: String {
        switch creatingKind {
        case .claude: return "新建 Claude Agent"
        case .opencode: return "新建 opencode Agent"
        case .grok: return "新建 Grok Agent"
        }
    }

    /// 一个来源类别：可折叠标题 + （展开时）其下所有子分栏
    @ViewBuilder
    private func sourceCategory<Content: View>(
        _ source: AgentSource, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        let isExpanded = service.isSearching || !collapsedSources.contains(source.rawValue)
        AgentSourceHeader(source: source, count: count, isExpanded: isExpanded) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if collapsedSources.contains(source.rawValue) {
                    collapsedSources.remove(source.rawValue)
                } else {
                    collapsedSources.insert(source.rawValue)
                }
            }
        }
        if isExpanded { content() }
    }

    // MARK: - agent 子分栏（系统 + 各项目；来源已由类别标题体现）

    @ViewBuilder
    private func agentSubsections(agents: [AgentDefinition]) -> some View {
        let system = agents.filter { !$0.scope.isProject }
        let projectNames = Array(Set(agents.compactMap { $0.scope.projectName })).sorted()
        if !system.isEmpty {
            sectionHeader("系统 \(system.count)", icon: "laptopcomputer", tint: Theme.agents)
            ForEach(system) { agentRow($0) }
        }
        ForEach(projectNames, id: \.self) { name in
            let group = agents.filter { $0.scope.projectName == name }
            sectionHeader("项目 · \(name)  \(group.count)", icon: "folder.fill", tint: Theme.sessions)
            ForEach(group) { agentRow($0) }
        }
    }

    /// Codex 类别下的 profile 子分栏
    @ViewBuilder
    private var codexProfileSection: some View {
        if !service.codexProfiles.isEmpty {
            sectionHeader("Profile \(service.codexProfiles.count)",
                          icon: "slider.horizontal.3", tint: Theme.agents)
            ForEach(service.codexProfiles) { profile in
                ProfileRow(
                    profile: profile,
                    onEdit: { profileEditor = ProfileEditTarget(
                        id: profile.name, profile: profile, isNew: false) },
                    onDelete: { deletingProfile = profile })
            }
        }
    }

    private func agentRow(_ agent: AgentDefinition) -> some View {
        AgentRow(
            agent: agent, service: service,
            onEdit: { fileEditor = AgentFileEditTarget(
                id: agent.path, title: agent.name, path: agent.path) },
            onDelete: { deletingAgent = agent })
    }

    // MARK: - 系统定义 agent（插件 + 内置）

    /// 插件 agent：按插件名分组（插件文件由 Claude Code 管理，仅支持查看 + 启用/停用）
    @ViewBuilder
    private var pluginSections: some View {
        let names = Array(Set(service.pluginAgents.compactMap { $0.pluginName })).sorted()
        ForEach(names, id: \.self) { name in
            let group = service.pluginAgents.filter { $0.pluginName == name }
            sectionHeader("插件 · \(name)  \(group.count)",
                          icon: "puzzlepiece.extension.fill", tint: Theme.skills)
            ForEach(group) { systemAgentRow($0) }
        }
    }

    /// 内置 agent：Claude Code 自带（只读，随版本可能变化）
    @ViewBuilder
    private var builtinSection: some View {
        if !service.builtinAgents.isEmpty {
            sectionHeader("内置（Claude Code） \(service.builtinAgents.count)",
                          icon: "shippingbox.fill", tint: Theme.history)
            ForEach(service.builtinAgents) { systemAgentRow($0) }
        }
    }

    /// Kimi 内置 subagent profile：编译内嵌于 CLI，磁盘无用户自定义约定 → 只读
    @ViewBuilder
    private var kimiBuiltinSection: some View {
        if !service.kimiBuiltinAgents.isEmpty {
            sectionHeader("内置（Kimi Code，只读） \(service.kimiBuiltinAgents.count)",
                          icon: "shippingbox.fill", tint: Theme.history)
            ForEach(service.kimiBuiltinAgents) { systemAgentRow($0) }
        }
    }

    private func systemAgentRow(_ agent: AgentDefinition) -> some View {
        SystemAgentRow(
            agent: agent, service: service,
            onView: { fileEditor = AgentFileEditTarget(
                id: agent.path, title: agent.name, path: agent.path) })
    }

    /// 空类别占位行：小字 + 内联新建（视觉重量低于正常行）
    private func emptyCategoryRow(
        _ text: String, actionTitle: String, action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Button(actionTitle, action: action)
                .buttonStyle(.borderless)
                .controlSize(.mini)
                .font(.system(size: 10))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 4)
    }

    private func sectionHeader(_ title: String, icon: String? = nil, tint: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
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

struct AgentFileEditTarget: Identifiable {
    let id: String
    var title: String
    var path: String
}

struct ProfileEditTarget: Identifiable {
    let id: String
    var profile: CodexProfile
    var isNew: Bool
}

// MARK: - 行

private struct AgentRow: View {
    let agent: AgentDefinition
    let service: AgentConfigService
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: agent.source, size: 12)
                .opacity(agent.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(agent.enabled ? .primary : .secondary)
                    .lineLimit(1)
                if let desc = agent.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if agent.model != nil || agent.mode != nil || !agent.tools.isEmpty {
                    HStack(spacing: 5) {
                        if let mode = agent.mode {
                            metaBadge("mode: \(mode)")
                        }
                        if let model = agent.model {
                            metaBadge("model: \(model)")
                        }
                        metaBadge(agent.tools.isEmpty ? "全部工具" : "\(agent.tools.count) 个工具")
                    }
                }
            }
            Spacer(minLength: 6)
            Toggle("", isOn: Binding(
                get: { agent.enabled },
                set: { service.setAgentEnabled(agent, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(agent.enabled ? "已启用（点按停用）" : "已停用（点按启用）")
            agentMenu(path: agent.path, onEdit: onEdit, onDelete: onDelete, service: service)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }

    private func metaBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.agents.opacity(0.08), in: Capsule())
    }
}

/// 来源类别折叠头：chevron + 来源徽标 + 名称 + 计数（Claude / opencode / Codex）
private struct AgentSourceHeader: View {
    let source: AgentSource
    let count: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                SourceBadge(source: source, size: 13)
                Text(source.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Color.primary.opacity(0.04) : .clear)
    }
}

/// 插件 / 内置 agent 行：插件可查看 + 启用/停用（无删除，避免误伤插件）；内置只读（无文件）
private struct SystemAgentRow: View {
    let agent: AgentDefinition
    let service: AgentConfigService
    let onView: () -> Void

    private var hasFile: Bool { !agent.path.isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: agent.source, size: 12)
                .opacity(agent.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(agent.enabled ? .primary : .secondary)
                    .lineLimit(1)
                if let desc = agent.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                if agent.model != nil || !agent.tools.isEmpty {
                    HStack(spacing: 5) {
                        if let model = agent.model { badge("model: \(model)") }
                        if !agent.tools.isEmpty { badge("\(agent.tools.count) 个工具") }
                    }
                }
            }
            Spacer(minLength: 6)
            if agent.builtin {
                badge("内置")
            } else if hasFile {
                Toggle("", isOn: Binding(
                    get: { agent.enabled },
                    set: { service.setAgentEnabled(agent, $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(agent.enabled ? "已启用（点按停用）" : "已停用（点按启用）")
                Menu {
                    Button("查看") { onView() }
                    Button("用默认编辑器打开") { service.openInEditor(path: agent.path) }
                    Button("在 Finder 中显示") { service.reveal(path: agent.path) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { if hasFile { onView() } }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.agents.opacity(0.08), in: Capsule())
    }
}

private struct ProfileRow: View {
    let profile: CodexProfile
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var summary: String {
        [profile.model.map { "model: \($0)" },
         profile.reasoningEffort.map { "reasoning: \($0)" },
         profile.personality.map { "persona: \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: .codex, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                if !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            Menu {
                Button("编辑") { onEdit() }
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

@ViewBuilder
private func agentMenu(
    path: String, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void,
    service: AgentConfigService
) -> some View {
    Menu {
        Button("编辑") { onEdit() }
        Button("用默认编辑器打开") { service.openInEditor(path: path) }
        Button("在 Finder 中显示") { service.reveal(path: path) }
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    } label: {
        Image(systemName: "ellipsis")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
}

// MARK: - Claude agent markdown 编辑 sheet

private struct AgentFileEditorSheet: View {
    let service: AgentConfigService
    let target: AgentFileEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button { service.reveal(path: target.path) } label: { Image(systemName: "folder") }
                    .help("在 Finder 中显示")
                Button { service.openInEditor(path: target.path) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("用默认编辑器打开")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()

            TextEditor(text: $text)
                .font(.system(size: 12).monospaced())
                .frame(minWidth: 460, minHeight: 320)

            Divider()
            HStack {
                Text(target.path)
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("取消") { dismiss() }
                Button(saved ? "已保存" : "保存") {
                    service.save(path: target.path, content: text) { _ in }
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
        }
        .frame(width: 520, height: 440)
        .onAppear {
            if !loaded {
                text = service.readContent(path: target.path) ?? ""
                loaded = true
            }
        }
    }
}

// MARK: - Codex profile 表单 sheet

private struct CodexProfileEditorSheet: View {
    let service: AgentConfigService
    let target: ProfileEditTarget

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var model = ""
    @State private var reasoning = ""
    @State private var personality = ""
    @State private var approval = ""
    @State private var loaded = false

    private let reasoningOptions = ["", "minimal", "low", "medium", "high", "xhigh"]
    private let approvalOptions = ["", "untrusted", "on-failure", "on-request", "never"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(target.isNew ? "新建 Codex Profile" : "编辑 Codex Profile")
                .font(.system(size: 13, weight: .semibold))
                .padding(10)
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
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    service.saveProfile(CodexProfile(
                        name: name.trimmingCharacters(in: .whitespaces),
                        model: nilIfEmpty(model),
                        reasoningEffort: nilIfEmpty(reasoning),
                        personality: nilIfEmpty(personality),
                        approvalPolicy: nilIfEmpty(approval)))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(10)
        }
        .frame(width: 420, height: 360)
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

    private func nilIfEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}
