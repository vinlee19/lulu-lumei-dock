import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能 & 记忆管理（紫金改版）：统计概览卡 + 来源筛选 chips + 扁平列表/图标双视图 + 内嵌详情。
/// Skills / Memory 两个同级页签共用此视图，由 mode 决定只显示技能或只显示记忆。
/// 技能行/卡带启停开关（绿=启用/灰=停用）；记忆无启停，按范围（全局/项目）标注。
struct SkillMemoryView: View {
    /// 页签模式：技能页 or 记忆页
    enum Mode { case skills, memory }

    @ObservedObject var service: SkillMemoryService
    let mode: Mode
    @ObservedObject var usageService: UsageService

    /// 内嵌技能详情（卡片点击进入；nil = 列表）
    @State private var detail: SkillDetailTarget?
    /// 内嵌记忆详情（nil = 列表）
    @State private var memoryDetail: MemoryEntry?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// 管理区布局：列表 / 图标网格（默认列表，对齐设计稿）
    @State private var layout: KnowledgeLayout = .list

    @State private var creating: CreateTarget?
    @State private var newName = ""
    @State private var deleting: DeleteTarget?

    /// 离屏渲染/预览专用：指定初始布局（交互时由 LayoutToggle 切换）
    init(service: SkillMemoryService, mode: Mode, usageService: UsageService,
         initialLayout: KnowledgeLayout = .list) {
        self._service = ObservedObject(wrappedValue: service)
        self.mode = mode
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._layout = State(initialValue: initialLayout)
    }

    var body: some View {
        Group {
            if let target = detail {
                SkillDetailView(
                    target: target, service: service, usageService: usageService,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = .skill($0) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let memory = memoryDetail {
                MemoryDetailView(
                    memory: memory, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { memoryDetail = nil } },
                    onDelete: { deleting = .memory(memory) })
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
            if mode == .skills {
                usageService.loadSkillStats()
                // 本周命中总数（统计卡副标题）：全来源、本周窗口，一次性拉取
                usageService.loadSkillRanking(source: nil, from: UsageService.DashboardPeriod.week.startDate, to: Date())
            }
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
                detail = nil
                memoryDetail = nil
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏（标题 + 搜索 + 新建 + 刷新 + 布局切换）

    private var header: some View {
        HStack(spacing: 12) {
            Text(mode == .skills ? "Skills" : "Memory").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: mode == .skills ? "搜索技能" : "搜索记忆",
                text: $service.searchText, scanning: service.scanning,
                resultCount: totalCount)
            Spacer(minLength: 12)
            createMenu
            RefreshButton(help: mode == .skills ? "刷新技能" : "刷新记忆") { service.refresh() }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 「新建」：紧凑紫色图标菜单（与刷新按钮同款圆底），各 CLI 分列菜单项。
    private var createMenu: some View {
        Menu {
            if mode == .skills {
                Button("Claude 技能") { startCreate(.claude, isSkill: true, "Claude 技能") }
                Button("Codex 技能") { startCreate(.codex, isSkill: true, "Codex 技能") }
                Button("OpenCode 技能") { startCreate(.opencode, isSkill: true, "OpenCode 技能") }
                Button("Grok 技能") { startCreate(.grok, isSkill: true, "Grok 技能") }
                Button("Antigravity 技能") { startCreate(.antigravity, isSkill: true, "Antigravity 技能") }
                Button("Kimi 技能") { startCreate(.kimi, isSkill: true, "Kimi 技能") }
                Button("Gemini 技能") { startCreate(.gemini, isSkill: true, "Gemini 技能") }
                Button("Qwen 技能") { startCreate(.qwen, isSkill: true, "Qwen 技能") }
            } else {
                Button("Claude 记忆") { startCreate(.claude, isSkill: false, "Claude 记忆") }
                Button("Codex 指令（AGENTS.md）") { service.createMemory(source: .codex, name: "AGENTS") }
                Button("Grok 记忆") { startCreate(.grok, isSkill: false, "Grok 记忆") }
                Button("Kimi 记忆（AGENTS.md）") { service.createMemory(source: .kimi, name: "AGENTS") }
                Button("Gemini 记忆（GEMINI.md）") { service.createMemory(source: .gemini, name: "GEMINI") }
                Button("Qwen 记忆") { startCreate(.qwen, isSkill: false, "Qwen 记忆") }
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
        .help(mode == .skills ? "新建技能" : "新建记忆")
    }

    // MARK: - 主体（统计概览卡 + 来源 chips + 扁平列表/网格）

    private let gridColumns = [GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: "全部",
                    allIcon: mode == .skills ? "sparkles" : "brain.head.profile",
                    totalCount: totalCount,
                    sources: sourcesByCount,
                    count: { count(for: $0) })
                body(for: mode)
                if let error = service.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    @ViewBuilder
    private func body(for mode: Mode) -> some View {
        switch mode {
        case .skills:
            let ctx = skillContext
            if ctx.items.isEmpty {
                emptyState.padding(.top, 40)
            } else if layout == .cards {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    ForEach(ctx.items) { skill in
                        SkillCard(
                            skill: skill, service: service,
                            stat: ctx.stats[skill.id], maxHit: ctx.maxHit,
                            onOpen: { openSkillDetail(skill) },
                            onDelete: { deleting = .skill(skill) })
                    }
                }
            } else {
                KnowledgeListContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(ctx.items.enumerated()), id: \.element.id) { index, skill in
                            SkillListRow(
                                skill: skill, service: service,
                                stat: ctx.stats[skill.id], maxHit: ctx.maxHit,
                                onOpen: { openSkillDetail(skill) },
                                onDelete: { deleting = .skill(skill) })
                            if index < ctx.items.count - 1 {
                                Divider().opacity(0.4).padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        case .memory:
            let items = memoryItems
            if items.isEmpty {
                emptyState.padding(.top, 40)
            } else if layout == .cards {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    ForEach(items) { memory in
                        MemoryCard(
                            memory: memory, service: service,
                            onOpen: { openMemory(memory) },
                            onDelete: { deleting = .memory(memory) })
                    }
                }
            } else {
                KnowledgeListContainer {
                    VStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, memory in
                            MemoryListRow(
                                memory: memory, service: service,
                                onOpen: { openMemory(memory) },
                                onDelete: { deleting = .memory(memory) })
                            if index < items.count - 1 {
                                Divider().opacity(0.4).padding(.leading, 50)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - 统计概览卡

    @ViewBuilder
    private var statsCard: some View {
        if mode == .skills {
            let enabled = service.skills.filter(\.enabled).count
            let projectCount = service.skills.filter { $0.scope.projectName != nil }.count
            let weekHits = usageService.skillRanking.reduce(0) { $0 + $1.count }
            StatOverviewCard(
                value: "\(totalCount)", unit: "技能",
                subtitle: "本周命中 \(weekHits)",
                distributionTitle: "启用分布",
                segments: [
                    .init(label: "启用", count: enabled, color: Theme.enabledGreen),
                    .init(label: "停用", count: totalCount - enabled, color: Theme.draftGray),
                ],
                trailingNote: projectCount > 0 ? "项目级 \(projectCount)" : nil)
        } else {
            let global = service.memories.filter { $0.projectName == nil }.count
            let bytes = service.memories.reduce(UInt64(0)) { $0 + $1.sizeBytes }
            StatOverviewCard(
                value: "\(totalCount)", unit: "记忆文件",
                subtitle: "\(sourcesByCount.count) 来源 · \(formatBytes(bytes))",
                distributionTitle: "范围分布",
                segments: [
                    .init(label: "全局", count: global, color: Theme.brand),
                    .init(label: "项目级", count: totalCount - global, color: Theme.gold),
                ])
        }
    }

    // MARK: - 计数 / 筛选 / 排序

    private var totalCount: Int {
        mode == .skills ? service.skills.count : service.memories.count
    }

    private func count(for source: AgentSource) -> Int {
        mode == .skills
            ? service.skills(for: source).count
            : service.memories(for: source).count
    }

    /// 有数据的来源，按计数降序（chips 顺序贴合设计稿）
    private var sourcesByCount: [AgentSource] {
        AgentSource.allCases.filter { count(for: $0) > 0 }
            .sorted { count(for: $0) > count(for: $1) }
    }

    /// 技能：来源筛选 + 按命中次数降序（无命中数据的排后、按名），并预取统计避免重复建表
    private var skillContext: (items: [SkillEntry], stats: [SkillEntry.ID: ToolCallsRepo.SkillUsageStat], maxHit: Int) {
        var map: [String: ToolCallsRepo.SkillUsageStat] = [:]
        for stat in usageService.skillStats {
            map["\(stat.source.rawValue):\(SkillMemoryService.normalizeSkillName(stat.name))"] = stat
        }
        func stat(_ skill: SkillEntry) -> ToolCallsRepo.SkillUsageStat? {
            let dir = URL(fileURLWithPath: skill.directory).lastPathComponent
            return map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(skill.name))"]
                ?? map["\(skill.source.rawValue):\(SkillMemoryService.normalizeSkillName(dir))"]
        }
        let base = service.skills.filter { selectedSource == nil || $0.source == selectedSource }
        var stats: [SkillEntry.ID: ToolCallsRepo.SkillUsageStat] = [:]
        for skill in base { if let s = stat(skill) { stats[skill.id] = s } }
        let sorted = base.sorted {
            let lc = stats[$0.id]?.count ?? 0
            let rc = stats[$1.id]?.count ?? 0
            if lc != rc { return lc > rc }
            return $0.name.lowercased() < $1.name.lowercased()
        }
        let maxHit = max(1, stats.values.map(\.count).max() ?? 1)
        return (sorted, stats, maxHit)
    }

    /// 记忆：来源筛选 + 全局优先、再按修改时间降序
    private var memoryItems: [MemoryEntry] {
        service.memories
            .filter { selectedSource == nil || $0.source == selectedSource }
            .sorted {
                let lg = $0.projectName == nil
                let rg = $1.projectName == nil
                if lg != rg { return lg && !rg }
                return $0.modifiedAt > $1.modifiedAt
            }
    }

    private func openSkillDetail(_ skill: SkillEntry) {
        withAnimation(.easeOut(duration: 0.15)) {
            detail = SkillDetailTarget(source: skill.source, name: skill.name, entry: skill)
        }
    }

    private func openMemory(_ memory: MemoryEntry) {
        withAnimation(.easeOut(duration: 0.15)) { memoryDetail = memory }
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
                icon: mode == .skills ? "wand.and.stars" : "brain.fill",
                title: service.isSearching || selectedSource != nil
                    ? "没有匹配项"
                    : (mode == .skills ? "还没有技能" : "还没有记忆"),
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : "点右上角「＋」创建各 CLI 的" + (mode == .skills ? "技能" : "记忆"))
        }
    }

    // MARK: - 动作

    private func startCreate(_ source: AgentSource, isSkill: Bool, _ label: String) {
        newName = ""
        creating = CreateTarget(source: source, isSkill: isSkill, label: label)
    }

    private var creatingBinding: Binding<Bool> {
        Binding(get: { creating != nil }, set: { if !$0 { creating = nil } })
    }
    private var deletingBinding: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
}

/// 家目录缩写为 ~（记忆路径展示）
private func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - 数据载体

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

// MARK: - 卡片

/// 技能操作菜单（卡片 / 列表行共用）
@ViewBuilder
private func skillContextMenu(
    _ skill: SkillEntry, service: SkillMemoryService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button("查看详情") { onOpen() }
    Button(skill.enabled ? "停用" : "启用") { service.setSkillEnabled(skill, !skill.enabled) }
    Button("用默认编辑器打开") { service.openInEditor(path: skill.path) }
    Button("在 Finder 中显示") { service.reveal(path: skill.path) }
    Divider()
    Button("删除", role: .destructive) { onDelete() }
}

private func skillActions(
    _ skill: SkillEntry, service: SkillMemoryService, onDelete: @escaping () -> Void
) -> [CardAction] {
    [
        CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: skill.path) },
        CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: skill.path) },
        CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() },
    ]
}

/// 技能图标卡：logo + 等宽名 + 启用开关 + 描述（2 行）+ 命中次数 · 项目 · 最近；悬停浮现动作
private struct SkillCard: View {
    let skill: SkillEntry
    let service: SkillMemoryService
    let stat: ToolCallsRepo.SkillUsageStat?
    let maxHit: Int
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeCard(
            enabled: skill.enabled, minHeight: 92,
            actions: skillActions(skill, service: service, onDelete: onDelete),
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: skill.source, size: 28)
                    Text(skill.name)
                        .font(Theme.font.monoSkillName(13))
                        .foregroundStyle(skill.enabled ? .primary : .secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    MiniSwitch(isOn: skill.enabled) { service.setSkillEnabled(skill, !skill.enabled) }
                }
                // 恒占 2 行：网格卡片等高，避免 LazyVGrid 参差留白
                Text(skill.description ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let stat, stat.count > 0 {
                        Text("命中 \(stat.count) 次")
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.brand)
                    }
                    if let project = skill.scope.projectName { TagChip(project) }
                    Spacer(minLength: 0)
                    if let last = stat?.lastTs {
                        Text(relativeFormatter.localizedString(for: last, relativeTo: Date()))
                            .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    }
                }
            }
        } menu: {
            skillContextMenu(skill, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }
}

/// 技能列表行：logo + 名称/描述两行 + 用量条·命中次数 + 最近 + 启用开关；悬停浮现动作
private struct SkillListRow: View {
    let skill: SkillEntry
    let service: SkillMemoryService
    let stat: ToolCallsRepo.SkillUsageStat?
    let maxHit: Int
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeRow(
            enabled: skill.enabled,
            actions: skillActions(skill, service: service, onDelete: onDelete),
            onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                SourceLogoTile(source: skill.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(skill.name)
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .foregroundStyle(skill.enabled ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                        if let project = skill.scope.projectName { TagChip(project) }
                    }
                    if let desc = skill.description, !desc.isEmpty {
                        Text(desc).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
        } menu: {
            skillContextMenu(skill, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if let stat, stat.count > 0 {
                Capsule().fill(Theme.hairline)
                    .frame(width: 72, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.brand)
                            .frame(width: max(4, 72 * CGFloat(stat.count) / CGFloat(maxHit)), height: 6)
                    }
                Text("\(stat.count) 次")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.brand)
            }
            if let last = stat?.lastTs {
                Text(relativeFormatter.localizedString(for: last, relativeTo: Date()))
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            MiniSwitch(isOn: skill.enabled) { service.setSkillEnabled(skill, !skill.enabled) }
        }
    }
}

private func memoryActions(
    _ memory: MemoryEntry, service: SkillMemoryService, onDelete: @escaping () -> Void
) -> [CardAction] {
    var acts: [CardAction] = []
    if memory.isEditable {
        acts.append(CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: memory.path) })
    }
    acts.append(CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: memory.path) })
    if memory.isDeletable {
        acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
    }
    return acts
}

@ViewBuilder
private func memoryContextMenu(
    _ memory: MemoryEntry, service: SkillMemoryService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(memory.isEditable ? "查看 / 编辑" : "查看") { onOpen() }
    if memory.isEditable {
        Button("用默认编辑器打开") { service.openInEditor(path: memory.path) }
    }
    Button("在 Finder 中显示") { service.reveal(path: memory.path) }
    if memory.isDeletable {
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    }
}

/// 记忆图标卡：左色脊（全局紫 / 项目金）+ logo + 名 + 范围徽标 + 路径 + 项目 chip + 大小·时间
private struct MemoryCard: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var isGlobal: Bool { memory.projectName == nil }

    var body: some View {
        // 边框与 Skills / Plans / Agents 完全一致（不加范围色脊）；范围由 ScopeBadge 表达
        KnowledgeCard(
            minHeight: 78,
            actions: memoryActions(memory, service: service, onDelete: onDelete),
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: memory.source, size: 28)
                    Text(memory.scope)
                        .font(Theme.font.monoSkillName(13))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ScopeBadge(isGlobal: isGlobal)
                }
                Text(abbreviateHome(memory.path))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let project = memory.projectName { TagChip(project) }
                    if memory.kind == .generated { TagChip("只读", neutral: true) }
                    Spacer(minLength: 0)
                    Text(formatBytes(memory.sizeBytes))
                        .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
                    Text("·").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Text(memory.modifiedAt, formatter: relativeFormatter)
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        } menu: {
            memoryContextMenu(memory, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }
}

/// 记忆列表行：logo + 名/范围徽标 + 路径 + 项目 chip + 大小 · 时间；悬停浮现动作（无启停）
private struct MemoryListRow: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var isGlobal: Bool { memory.projectName == nil }

    var body: some View {
        KnowledgeRow(
            actions: memoryActions(memory, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                SourceLogoTile(source: memory.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(memory.scope)
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        ScopeBadge(isGlobal: isGlobal)
                        if memory.kind == .generated { TagChip("只读", neutral: true) }
                    }
                    Text(abbreviateHome(memory.path))
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
        } menu: {
            memoryContextMenu(memory, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            if let project = memory.projectName { TagChip(project) }
            Text(formatBytes(memory.sizeBytes))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            Text(memory.modifiedAt, formatter: relativeFormatter)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 记忆内嵌详情（文档卡渲染 + 预览/编辑切换，与计划详情同排版）

private struct MemoryDetailView: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?

    init(
        memory: MemoryEntry, service: SkillMemoryService,
        onBack: @escaping () -> Void, onDelete: @escaping () -> Void
    ) {
        self.memory = memory
        self.service = service
        self.onBack = onBack
        self.onDelete = onDelete
        // init 即加载：避免首帧空白（记忆均为小文件，主线程读取无感）
        _text = State(initialValue: service.readContent(path: memory.path) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
                    .padding(8)
            } else {
                MarkdownDocumentCard(text: text)
            }
            Divider()
            footer
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
            SourceBadge(source: memory.source, size: 12)
            Text(memory.scope)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if memory.isEditable {
                CapsuleTabTray {
                    CapsuleTabButton(title: "预览", fillWidth: false, isSelected: !editing) { editing = false }
                    CapsuleTabButton(title: "编辑", fillWidth: false, isSelected: editing) { editing = true }
                }
                Button { service.openInEditor(path: memory.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("用默认编辑器打开")
            }
            Button { service.reveal(path: memory.path) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            if memory.isDeletable {
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
            Text(memory.isEditable ? memory.path : "Codex 生成状态（只读） · \(memory.path)")
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
                    service.save(path: memory.path, content: text) { ok in
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
