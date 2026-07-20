import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能 & 记忆管理：浏览 Claude/Codex 的 skills 与 memory，
/// 支持内嵌编辑、新建、删除（进废纸篓）、启用/停用技能（移到 *.eureka-disabled）。
/// Skills / Memory 两个同级页签共用此视图，由 mode 决定只显示技能或只显示记忆。
struct SkillMemoryView: View {
    /// 页签模式：技能页 or 记忆页
    enum Mode { case skills, memory }

    @ObservedObject var service: SkillMemoryService
    let mode: Mode
    @ObservedObject var usageService: UsageService

    /// 技能页内「列表 | 统计」分段
    enum SkillTab: String, CaseIterable { case list = "列表", stats = "统计" }
    @State private var skillTab: SkillTab = .list
    /// 详情页目标（列表行 / 统计行点击进入）
    @State private var detail: SkillDetailTarget?

    @State private var editor: EditorTarget?
    @State private var creating: CreateTarget?
    @State private var newName = ""
    @State private var deleting: DeleteTarget?
    /// 已折叠的系统技能来源（存 AgentSource.rawValue）；默认展开
    @State private var collapsedSkillSources: Set<String> = []
    /// 已展开的项目技能分组（存项目名）；默认折叠，搜索时强制展开命中项
    @State private var expandedSkillProjects: Set<String> = []
    /// 已折叠的系统记忆来源（存 AgentSource.rawValue）；默认展开
    @State private var collapsedMemorySources: Set<String> = []
    /// 已展开的项目记忆分组（存项目名）；默认折叠，搜索时强制展开命中项
    @State private var expandedMemoryProjects: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            service.refresh()
            if mode == .skills { usageService.loadSkillStats() }
        }
        .sheet(item: $editor) { target in
            EditorSheet(service: service, target: target)
        }
        .sheet(item: $detail) { target in
            SkillDetailView(target: target, service: service, usageService: usageService)
        }
        .alert("新建" + (creating?.label ?? ""), isPresented: creatingBinding) {
            TextField("名称", text: $newName)
            Button("创建") {
                if let creating, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if creating.isSkill {
                        service.createSkill(source: creating.source, name: newName)
                    } else {
                        service.createMemory(source: creating.source, name: newName)
                    }
                }
                newName = ""
            }
            Button("取消", role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            deleting.map { "删除「\($0.title)」？文件会移入废纸篓，可恢复。" } ?? "",
            isPresented: deletingBinding, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                deleting?.perform(service)
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        VStack(spacing: 6) {
            if mode == .skills {
                Picker("", selection: $skillTab) {
                    ForEach(SkillTab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            searchRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField(mode == .skills ? "搜索技能" : "搜索记忆", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            Menu {
                if mode == .skills {
                    Button("Claude 技能") { startCreate(.claude, isSkill: true, "Claude 技能") }
                    Button("Codex 技能") { startCreate(.codex, isSkill: true, "Codex 技能") }
                    Button("opencode 技能") { startCreate(.opencode, isSkill: true, "opencode 技能") }
                    Button("Grok 技能") { startCreate(.grok, isSkill: true, "Grok 技能") }
                    Button("Antigravity 技能") { startCreate(.antigravity, isSkill: true, "Antigravity 技能") }
                    Button("Kimi 技能") { startCreate(.kimi, isSkill: true, "Kimi 技能") }
                } else {
                    Button("Claude 记忆") { startCreate(.claude, isSkill: false, "Claude 记忆") }
                    Button("Codex 指令（AGENTS.md）") {
                        service.createMemory(source: .codex, name: "AGENTS")
                    }
                    Button("Grok 记忆") { startCreate(.grok, isSkill: false, "Grok 记忆") }
                    // kimi 记忆 = 单一全局 AGENTS.md，无需命名 → 直接创建并刷新
                    Button("Kimi 记忆（AGENTS.md）") { service.createMemory(source: .kimi, name: "AGENTS") }
                }
            } label: {
                Image(systemName: "plus.circle")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if mode == .skills && skillTab == .stats {
            SkillAnalyticsView(
                service: service, usageService: usageService,
                openDetail: { detail = $0 })
        } else {
            listContent
        }
    }

    @ViewBuilder
    private var listContent: some View {
        let isEmpty = mode == .skills ? service.skills.isEmpty : service.memories.isEmpty
        // 非搜索态不再整页空态：来源分组常显（空组带占位 + 新建入口）
        if isEmpty && (service.isSearching || service.scanning) {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch mode {
                    case .skills: skillsSections
                    case .memory: memorySections
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

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            if service.scanning {
                ProgressView("正在扫描…")
            } else {
                Image(systemName: mode == .skills ? "wand.and.stars" : "brain.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(
                        (mode == .skills ? Theme.skills : Theme.memory).opacity(0.45))
                Text(service.isSearching ? "没有匹配项" : (mode == .skills ? "没有技能" : "没有记忆"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 技能页：系统技能（按来源可折叠，空组常显带新建入口）+ 各项目技能（可折叠）
    @ViewBuilder
    private var skillsSections: some View {
        if !systemSkills.isEmpty || !service.isSearching {
            sectionHeader("系统技能 \(systemSkills.count)", icon: "wand.and.stars", tint: Theme.skills)
            ForEach(systemSkillsBySource, id: \.0) { source, group in
                let isExpanded = !collapsedSkillSources.contains(source.rawValue)
                SkillSourceHeader(
                    source: source, count: group.count, isExpanded: isExpanded
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if collapsedSkillSources.contains(source.rawValue) {
                            collapsedSkillSources.remove(source.rawValue)
                        } else {
                            collapsedSkillSources.insert(source.rawValue)
                        }
                    }
                }
                if isExpanded {
                    if group.isEmpty {
                        emptySourceRow(text: "暂无技能", actionTitle: "新建") {
                            startCreate(source, isSkill: true, "\(source.displayName) 技能")
                        }
                    } else {
                        ForEach(group) { skillRow($0) }
                    }
                }
            }
        }
        ForEach(skillProjectNames, id: \.self) { name in
            let group = projectSkills(name)
            let isExpanded = service.isSearching || expandedSkillProjects.contains(name)
            SkillProjectHeader(name: name, count: group.count, isExpanded: isExpanded) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedSkillProjects.contains(name) {
                        expandedSkillProjects.remove(name)
                    } else {
                        expandedSkillProjects.insert(name)
                    }
                }
            }
            if isExpanded {
                ForEach(group) { skillRow($0) }
            }
        }
    }

    /// 记忆页：系统记忆（按来源可折叠，空组常显带新建入口）+ 各项目记忆（可折叠）
    @ViewBuilder
    private var memorySections: some View {
        if !systemMemories.isEmpty || !service.isSearching {
            sectionHeader("系统记忆 \(systemMemories.count)", icon: "brain.fill", tint: Theme.memory)
            ForEach(systemMemoriesBySource, id: \.0) { source, group in
                let isExpanded = !collapsedMemorySources.contains(source.rawValue)
                SkillSourceHeader(
                    source: source, count: group.count, isExpanded: isExpanded
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if collapsedMemorySources.contains(source.rawValue) {
                            collapsedMemorySources.remove(source.rawValue)
                        } else {
                            collapsedMemorySources.insert(source.rawValue)
                        }
                    }
                }
                if isExpanded {
                    if group.isEmpty {
                        memoryEmptyRow(source)
                    } else {
                        ForEach(group) { memoryRow($0) }
                    }
                }
            }
        }
        ForEach(memoryProjectNames, id: \.self) { name in
            let group = projectMemories(name)
            let isExpanded = service.isSearching || expandedMemoryProjects.contains(name)
            SkillProjectHeader(name: name, count: group.count, isExpanded: isExpanded) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if expandedMemoryProjects.contains(name) {
                        expandedMemoryProjects.remove(name)
                    } else {
                        expandedMemoryProjects.insert(name)
                    }
                }
            }
            if isExpanded {
                ForEach(group) { memoryRow($0) }
            }
        }
    }

    // MARK: - 技能分栏

    private var systemSkills: [SkillEntry] {
        service.skills.filter { !$0.scope.isProject }
    }
    /// 系统技能按来源分组（allCases 顺序）。非搜索态空组也保留（来源常显，空组给占位 + 新建入口）；
    /// 搜索态只留命中组避免噪音。
    private var systemSkillsBySource: [(AgentSource, [SkillEntry])] {
        AgentSource.allCases.compactMap { source in
            let group = systemSkills.filter { $0.source == source }
            if group.isEmpty && service.isSearching { return nil }
            return (source, group)
        }
    }
    private var skillProjectNames: [String] {
        Array(Set(service.skills.compactMap { $0.scope.projectName })).sorted()
    }
    private func projectSkills(_ name: String) -> [SkillEntry] {
        service.skills.filter { $0.scope.projectName == name }
    }
    /// 归一化 "来源:名" → 技能统计（Claude 调用数据）；用于列表行"最近活跃"
    private var statsByKey: [String: ToolCallsRepo.SkillUsageStat] {
        var map: [String: ToolCallsRepo.SkillUsageStat] = [:]
        for stat in usageService.skillStats {
            map["\(stat.source.rawValue):\(SkillMemoryService.normalizeSkillName(stat.name))"] = stat
        }
        return map
    }
    private func skillStat(for skill: SkillEntry) -> ToolCallsRepo.SkillUsageStat? {
        let map = statsByKey
        let dir = URL(fileURLWithPath: skill.directory).lastPathComponent
        return map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(skill.name))"]
            ?? map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(dir))"]
    }
    private func skillRow(_ skill: SkillEntry) -> some View {
        SkillRow(
            skill: skill, service: service,
            lastActive: skillStat(for: skill)?.lastTs,
            onOpenDetail: {
                detail = SkillDetailTarget(source: skill.source, name: skill.name, entry: skill)
            },
            onEdit: { openEditor(path: skill.path, title: skill.name, isSkill: true) },
            onDelete: { deleting = .skill(skill) })
    }

    // MARK: - 记忆分栏

    /// 系统记忆：全局 CLAUDE.md/AGENTS.md + 用户自建记忆（projectName == nil）
    private var systemMemories: [MemoryEntry] {
        service.memories.filter { $0.projectName == nil }
    }
    /// 系统记忆按来源分组（allCases 顺序）。非搜索态空组也保留（来源常显）；搜索态只留命中组。
    private var systemMemoriesBySource: [(AgentSource, [MemoryEntry])] {
        AgentSource.allCases.compactMap { source in
            let group = systemMemories.filter { $0.source == source }
            if group.isEmpty && service.isSearching { return nil }
            return (source, group)
        }
    }
    private var memoryProjectNames: [String] {
        Array(Set(service.memories.compactMap { $0.projectName })).sorted()
    }
    private func projectMemories(_ name: String) -> [MemoryEntry] {
        service.memories.filter { $0.projectName == name }
    }
    private func memoryRow(_ memory: MemoryEntry) -> some View {
        MemoryRow(
            memory: memory, service: service,
            onEdit: {
                openEditor(
                    path: memory.path, title: memory.scope,
                    isSkill: false, isEditable: memory.isEditable)
            },
            onDelete: { deleting = .memory(memory) })
    }

    /// 空来源占位行：小字说明 + 可选内联新建（视觉重量低于正常行）
    @ViewBuilder
    private func emptySourceRow(
        text: String, actionTitle: String? = nil, action: (() -> Void)? = nil
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
        .padding(.horizontal, 30)
        .padding(.vertical, 4)
    }

    /// 记忆页空来源占位：kimi 一键建 AGENTS.md；antigravity 无概念只给文案；其余走命名新建
    @ViewBuilder
    private func memoryEmptyRow(_ source: AgentSource) -> some View {
        switch source {
        case .codex:
            emptySourceRow(text: "未创建 AGENTS.md", actionTitle: "创建 AGENTS.md") {
                service.createMemory(source: .codex, name: "AGENTS")
            }
        case .kimi:
            emptySourceRow(text: "未创建 AGENTS.md", actionTitle: "创建 AGENTS.md") {
                service.createMemory(source: .kimi, name: "AGENTS")
            }
        case .antigravity:
            emptySourceRow(text: "无记忆概念")
        default:
            emptySourceRow(text: "暂无记忆", actionTitle: "新建") {
                startCreate(source, isSkill: false, "\(source.displayName) 记忆")
            }
        }
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

    // MARK: - 动作

    private func startCreate(_ source: AgentSource, isSkill: Bool, _ label: String) {
        newName = ""
        creating = CreateTarget(source: source, isSkill: isSkill, label: label)
    }

    private func openEditor(
        path: String, title: String, isSkill: Bool, isEditable: Bool = true
    ) {
        editor = EditorTarget(
            id: path, title: title, path: path,
            isSkill: isSkill, isEditable: isEditable)
    }

    private var creatingBinding: Binding<Bool> {
        Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
    }
    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

// MARK: - 数据载体

struct EditorTarget: Identifiable {
    let id: String
    var title: String
    var path: String
    var isSkill: Bool
    var isEditable: Bool = true
}

private struct CreateTarget: Identifiable {
    let id = UUID()
    var source: AgentSource
    var isSkill: Bool
    var label: String
}

private enum DeleteTarget {
    case skill(SkillEntry)
    case memory(MemoryEntry)

    var title: String {
        switch self {
        case .skill(let s): return s.name
        case .memory(let m): return m.scope
        }
    }
    func perform(_ service: SkillMemoryService) {
        switch self {
        case .skill(let s): service.deleteSkill(s)
        case .memory(let m): service.deleteMemory(m)
        }
    }
}

// MARK: - 行

/// 系统技能的来源折叠头：chevron + 来源徽标 + 名称 + 计数
private struct SkillSourceHeader: View {
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
                SourceBadge(source: source, size: 11)
                Text(source.displayName)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Color.primary.opacity(0.03) : .clear)
    }
}

/// 项目技能的折叠头：chevron + 文件夹图标 + 项目名 + 计数
private struct SkillProjectHeader: View {
    let name: String
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
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.sessions.opacity(0.8))
                Text(name)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Color.primary.opacity(0.03) : .clear)
    }
}

private struct SkillRow: View {
    let skill: SkillEntry
    let service: SkillMemoryService
    let lastActive: Date?
    let onOpenDetail: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: skill.source, size: 12)
                .opacity(skill.enabled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(skill.enabled ? .primary : .secondary)
                    .lineLimit(1)
                if let desc = skill.description {
                    Text(desc)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            if let lastActive {
                Text(relativeFormatter.localizedString(for: lastActive, relativeTo: Date()))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .help("最近调用时间")
            }
            Toggle("", isOn: Binding(
                get: { skill.enabled },
                set: { service.setSkillEnabled(skill, $0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(skill.enabled ? "已启用（点按停用）" : "已停用（点按启用）")
            rowMenu(path: skill.path, onEdit: onEdit, onDelete: onDelete, service: service)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpenDetail() }
    }
}

private struct MemoryRow: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            SourceBadge(source: memory.source, size: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(memory.scope)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(URL(fileURLWithPath: memory.path).lastPathComponent)
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if memory.kind == .generated {
                    Text("Codex 生成记忆 · 只读")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 6)
            Text(formatBytes(memory.sizeBytes))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            rowMenu(
                path: memory.path, onEdit: onEdit, onDelete: onDelete,
                service: service, canEdit: memory.isEditable, canDelete: memory.isDeletable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onEdit() }
    }
}

@ViewBuilder
private func rowMenu(
    path: String, onEdit: @escaping () -> Void, onDelete: @escaping () -> Void,
    service: SkillMemoryService, canEdit: Bool = true, canDelete: Bool = true
) -> some View {
    Menu {
        Button(canEdit ? "编辑" : "查看") { onEdit() }
        if canEdit {
            Button("用默认编辑器打开") { service.openInEditor(path: path) }
        }
        Button("在 Finder 中显示") { service.reveal(path: path) }
        if canDelete {
            Divider()
            Button("删除", role: .destructive) { onDelete() }
        }
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

// MARK: - 编辑 sheet

struct EditorSheet: View {
    let service: SkillMemoryService
    let target: EditorTarget

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var saved = false
    @State private var editing = false  // false = 预览渲染，true = 原文编辑

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if target.isEditable {
                    Picker("", selection: $editing) {
                        Text("预览").tag(false)
                        Text("编辑").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
                Button { service.reveal(path: target.path) } label: {
                    Image(systemName: "folder")
                }
                .help("在 Finder 中显示")
                if target.isEditable {
                    Button { service.openInEditor(path: target.path) } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .help("用默认编辑器打开")
                }
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()

            Group {
                if editing {
                    TextEditor(text: $text)
                        .font(.system(size: 12).monospaced())
                } else {
                    ScrollView {
                        MarkdownRichText(text: text)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 320)

            Divider()
            HStack {
                Text(target.isEditable ? target.path : "Codex 生成状态（只读） · \(target.path)")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button(target.isEditable ? "取消" : "关闭") { dismiss() }
                if target.isEditable {
                    Button(saved ? "已保存" : "保存") {
                        service.save(path: target.path, content: text) { _ in }
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
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
