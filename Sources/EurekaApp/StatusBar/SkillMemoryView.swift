import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 技能 & 记忆管理（紫金改版）：统计概览卡 + 来源筛选 chips + 扁平列表/图标双视图 + 内嵌详情。
/// Skills / Memory 两个同级页签共用此视图，由 mode 决定只显示技能或只显示记忆。
/// 技能行/卡带启停开关（绿=启用/灰=停用）；记忆无启停，按范围（全局/项目）标注。
struct SkillMemoryView: View {
    /// 页签模式：技能 / 记忆 / 指令（三页共用这一个视图）
    enum Mode {
        case skills
        case memory
        /// CLAUDE.md / AGENTS.md 这类用户维护的持久指令。**与记忆分开**：它们是写给 agent 的规则，
        /// 不是 agent 攒下来的记忆，混在一个数字里会让「记忆有多少」失去意义。
        case instructions

        var title: String {
            switch self {
            case .skills: return "Skills"
            case .memory: return "Memory"
            case .instructions: return "指令"
            }
        }
        var searchPlaceholder: String {
            switch self {
            case .skills: return "搜索技能"
            case .memory: return "搜索记忆"
            case .instructions: return "搜索指令文件"
            }
        }
        var noun: String {
            switch self {
            case .skills: return "技能"
            case .memory: return "记忆"
            case .instructions: return "指令"
            }
        }
    }

    @ObservedObject var service: SkillMemoryService
    let mode: Mode
    @ObservedObject var usageService: UsageService
    /// 技能详情页「最近调用会话」跳转用；nil 时该卡片按不可达灰显（兼容 PreviewRenderer 等既有构造点）
    var sessionBrowser: SessionBrowserService? = nil

    /// 内嵌技能详情（卡片点击进入；nil = 列表）
    @State private var detail: SkillDetailTarget?
    /// 内嵌记忆详情（nil = 列表）
    @State private var memoryDetail: MemoryEntry?
    /// 展开的记忆库（点库行进入；nil = 顶层列表）
    @State private var openedLibrary: MemoryLibrary?
    /// 顶层图谱模式当前看的是哪个库（nil = 取第一个，即条目最多的那个）
    @State private var graphLibraryKey: String?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// 管理区布局：列表 / 图标网格（默认列表，对齐设计稿）
    @State private var layout: KnowledgeLayout = .list

    @State private var creating: CreateTarget?
    @State private var newName = ""
    @State private var deleting: DeleteTarget?

    /// 离屏渲染/预览专用：指定初始布局与直接展开的记忆库
    /// （二级页没有别的入口能被离屏渲染器点到 —— 它只会渲第一帧）
    init(service: SkillMemoryService, mode: Mode, usageService: UsageService,
         sessionBrowser: SessionBrowserService? = nil,
         initialLayout: KnowledgeLayout = .list,
         initialLibraryKey: String? = nil,
         initialMemoryPath: String? = nil) {
        self._service = ObservedObject(wrappedValue: service)
        self.mode = mode
        self._usageService = ObservedObject(wrappedValue: usageService)
        self.sessionBrowser = sessionBrowser
        self._layout = State(initialValue: initialLayout)
        let library = initialLibraryKey.flatMap { key in
            service.libraries.first { $0.key == key }
        }
        self._openedLibrary = State(initialValue: library)
        self._memoryDetail = State(
            initialValue: initialMemoryPath.flatMap { path in
                (service.memoryEntries + (library?.allFiles ?? []))
                    .first { $0.path == path }
            })
    }

    var body: some View {
        Group {
            if let target = detail {
                SkillDetailView(
                    target: target, service: service, usageService: usageService,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = .skill($0) },
                    sessionBrowser: sessionBrowser)
                    // detail 从技能 A 直切技能 B 时（⌘K 直达）target 变了但 view identity 不变，
                    // SwiftUI 会复用旧状态；用 target.id 强制重建，让 onAppear 重新加载四个状态
                    .id(target.id)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let memory = memoryDetail {
                MemoryDetailView(
                    memory: memory, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { memoryDetail = nil } },
                    onDelete: { deleting = .memory(memory) },
                    onOpenMemory: { openMemory($0) })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let library = openedLibrary {
                MemoryLibraryView(
                    library: library, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { openedLibrary = nil } },
                    onOpenMemory: { openMemory($0) },
                    onDelete: { deleting = .memory($0) })
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
            consumeFocus()
        }
        .onChange(of: service.focusPath) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
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
            Text(mode.title).font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: mode.searchPlaceholder,
                text: $service.searchText, scanning: service.scanning,
                resultCount: totalCount)
            Spacer(minLength: 12)
            createMenu
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: "强制重扫" + mode.noun) {
                service.refresh(force: true)
            }
            // 图谱只对记忆有意义（记忆之间有 [[链接]]、还指向来源会话；技能之间没有这种关系）
            LayoutToggle(
                layout: $layout,
                cases: mode == .memory ? KnowledgeLayout.allCases : KnowledgeLayout.withoutGraph)
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
                Button("Hermes 技能") { startCreate(.hermes, isSkill: true, "Hermes 技能") }
                Button("Cursor 技能") { startCreate(.cursor, isSkill: true, "Cursor 技能") }
                Button("CodeBuddy 技能") { startCreate(.codebuddy, isSkill: true, "CodeBuddy 技能") }
                Button("Qoder 技能") { startCreate(.qoder, isSkill: true, "Qoder 技能") }
                Button("Trae 技能") { startCreate(.trae, isSkill: true, "Trae 技能") }
            } else if mode == .memory {
                Button("Claude 记忆") { startCreate(.claude, isSkill: false, "Claude 记忆") }
                Button("OpenCode 记忆") { startCreate(.opencode, isSkill: false, "OpenCode 记忆") }
                Button("Grok 记忆") { startCreate(.grok, isSkill: false, "Grok 记忆") }
                Button("Qwen 记忆") { startCreate(.qwen, isSkill: false, "Qwen 记忆") }
                Button("CodeBuddy 记忆") { startCreate(.codebuddy, isSkill: false, "CodeBuddy 记忆") }
                Button("Qoder 记忆") { startCreate(.qoder, isSkill: false, "Qoder 记忆") }
                // hermes 记忆 = 固定 memories/MEMORY.md（name 忽略，见 createMemory）
                Button("Hermes 记忆（MEMORY.md）") { service.createMemory(source: .hermes, name: "MEMORY") }
                // trae 记忆 = 固定 memory/user_profile.md（只有 CN 版有记忆库，见 createMemory）
                Button("Trae 记忆（user_profile.md）") {
                    service.createMemory(source: .trae, name: "user_profile")
                }
            } else {
                // 指令文件：这三个 CLI 的"全局记忆"其实就是一份固定名字的指令文件，
                // 所以创建入口跟着指令页走（Claude 的 CLAUDE.md 由用户自己或 /init 生成，不在这提供）
                Button("Codex 指令（AGENTS.md）") { service.createMemory(source: .codex, name: "AGENTS") }
                Button("Kimi 指令（AGENTS.md）") { service.createMemory(source: .kimi, name: "AGENTS") }
                Button("Gemini 指令（GEMINI.md）") { service.createMemory(source: .gemini, name: "GEMINI") }
                Button("Trae 指令（user_rules.md）") {
                    service.createMemory(source: .trae, name: "user_rules")
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brandFg)
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
                    allIcon: allSourcesIcon,
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
        case .instructions:
            // 指令文件没有记忆库、没有图谱（它们之间没有 [[链接]] 也没有来源会话）→ 只有列表/卡片
            let items = instructionItems
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
        case .memory:
            let items = memoryItems
            let libraries = libraryItems
            if layout == .graph {
                memoryGraphBoard(libraries)
            } else if items.isEmpty, libraries.isEmpty {
                emptyState.padding(.top, 40)
            } else if layout == .cards {
                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                    ForEach(libraries) { library in
                        MemoryLibraryCard(library: library, onOpen: { open(library) })
                    }
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
                        // 记忆库先列：一个项目 70+ 条记忆折成一行，点进去看条目
                        ForEach(libraries) { library in
                            MemoryLibraryRow(library: library, onOpen: { open(library) })
                            Divider().opacity(0.4).padding(.leading, 50)
                        }
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

    /// 顶层图谱模式：先挑一个记忆库（图谱天然是「一库一张」），再画它的关系图
    @ViewBuilder
    private func memoryGraphBoard(_ libraries: [MemoryLibrary]) -> some View {
        if libraries.isEmpty {
            EmptyStateView(
                icon: "point.3.filled.connected.trianglepath.dotted",
                title: service.scanning ? "正在扫描…" : "还没有记忆库",
                hint: service.isSearching
                    ? "搜索中不显示图谱（清空搜索框看图）"
                    : "记忆库来自 Claude / Qwen 的 projects/<项目>/memory 目录")
                .padding(.top, 40)
        } else {
            let picked = libraries.first { $0.key == graphLibraryKey } ?? libraries[0]
            VStack(alignment: .leading, spacing: 12) {
                if libraries.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        CapsuleTabTray {
                            ForEach(libraries) { library in
                                CapsuleTabButton(
                                    title: "\(library.projectName) \(library.count)",
                                    fillWidth: false, isSelected: library.key == picked.key
                                ) { graphLibraryKey = library.key }
                            }
                        }
                    }
                }
                MemoryGraphSection(
                    library: picked, service: service,
                    onOpenMemory: { openMemory($0) })
            }
        }
    }

    // MARK: - 统计概览卡

    /// 「全部」chip 的图标（各页语义不同）
    private var allSourcesIcon: String {
        switch mode {
        case .skills: return "sparkles"
        case .memory: return "brain.head.profile"
        case .instructions: return "doc.plaintext"
        }
    }

    @ViewBuilder
    private var statsCard: some View {
        if mode == .instructions {
            let scope = service.instructionScopeBreakdown
            StatOverviewCard(
                value: "\(totalCount)", unit: "指令文件",
                subtitle: "\(service.instructionSourceCount) 来源 · "
                    + formatBytes(service.instructionTotalBytes),
                distributionTitle: "范围分布",
                segments: [
                    .init(label: "全局", count: scope.global, color: Theme.brand),
                    .init(label: "项目根", count: scope.project, color: Theme.gold),
                ])
        } else if mode == .skills {
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
            // 口径：service.memoryEntries（独立条目 + 全部库内文件）。
            // 以前这里读被过滤后的列表数组，97 条项目记忆一条都没算进来 —— 数字因此总是偏小。
            let scope = service.memoryScopeBreakdown
            let libraryNote = service.libraries.isEmpty
                ? nil : "\(service.libraries.count) 个记忆库"
            StatOverviewCard(
                value: "\(totalCount)", unit: "记忆",
                subtitle: "\(service.memorySourceCount) 来源 · "
                    + formatBytes(service.memoryTotalBytes),
                distributionTitle: "范围分布",
                segments: [
                    .init(label: "全局", count: scope.global, color: Theme.brand),
                    .init(label: "项目记忆库", count: scope.library, color: Theme.enabledGreen),
                ],
                trailingNote: libraryNote)
        }
    }

    // MARK: - 计数 / 筛选 / 排序

    private var totalCount: Int {
        switch mode {
        case .skills: return service.skills.count
        case .memory: return service.memoryTotal
        case .instructions: return service.instructionTotal
        }
    }

    private func count(for source: AgentSource) -> Int {
        switch mode {
        case .skills: return service.skills(for: source).count
        case .memory: return service.memoryCount(for: source)
        case .instructions: return service.instructionCount(for: source)
        }
    }

    /// 有数据的来源，按计数降序（chips 顺序贴合设计稿）。
    ///
    /// **先把计数算成字典再排**：比较器里调 `count(for:)` 会让每次比较都 filter 一遍全表
    /// （12 个源约 30 次比较 × 两次调用 × 数百条数据 = 每帧上万次遍历，而 body 会反复求值）。
    /// 顺带用 rawValue 做同名次的 tiebreak —— `sorted` 不保证稳定，否则同计数的 chips 顺序会抖。
    private var sourcesByCount: [AgentSource] {
        var counts: [AgentSource: Int] = [:]
        for source in AgentSource.allCases {
            let n = count(for: source)
            if n > 0 { counts[source] = n }
        }
        return counts.keys.sorted {
            let lhs = counts[$0] ?? 0
            let rhs = counts[$1] ?? 0
            return lhs == rhs ? $0.rawValue < $1.rawValue : lhs > rhs
        }
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

    /// 记忆库（搜索时 service.libraries 为空 —— 那时库内条目已扁平并入 memoryItems）
    private var libraryItems: [MemoryLibrary] {
        service.libraries(for: selectedSource)
    }

    /// 指令文件：来源筛选 + 全局优先、再按修改时间降序（与记忆同一套次序）
    private var instructionItems: [MemoryEntry] {
        service.instructions
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

    /// 跨页直达落点：按路径找到本签条目并打开详情（找不到不清空——可能属于别的签，或扫描还没跑完）。
    /// 用 `knowledgeSnapshot()`（全集）而非 `service.skills`/`memoryEntries`/`instructions`：
    /// 那三个是搜索过滤过的当前视图，⌘K 索引口径本就是全集，消费口径必须与之一致，否则
    /// 带着 searchText 残留切页会导致明明存在的条目查不到。
    private func consumeFocus() {
        guard let path = service.focusPath else { return }
        let snap = service.knowledgeSnapshot()
        if mode == .skills {
            guard let skill = snap.skills.first(where: { $0.path == path }) else { return }
            withAnimation(.easeOut(duration: 0.15)) {
                detail = SkillDetailTarget(source: skill.source, name: skill.name, entry: skill)
            }
            service.focusPath = nil
        } else {
            guard let memory = snap.memories.first(where: { $0.path == path }) else { return }
            withAnimation(.easeOut(duration: 0.15)) { memoryDetail = memory }
            service.focusPath = nil
        }
    }

    private func openMemory(_ memory: MemoryEntry) {
        withAnimation(.easeOut(duration: 0.15)) { memoryDetail = memory }
    }

    private func open(_ library: MemoryLibrary) {
        withAnimation(.easeOut(duration: 0.15)) { openedLibrary = library }
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
                icon: emptyIcon,
                title: service.isSearching || selectedSource != nil
                    ? "没有匹配项" : "还没有\(mode.noun)",
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : (mode == .instructions
                        ? "各仓库根的 CLAUDE.md / AGENTS.md / GEMINI.md 会出现在这里"
                        : "点右上角「＋」创建各 CLI 的\(mode.noun)"))
        }
    }

    private var emptyIcon: String {
        switch mode {
        case .skills: return "wand.and.stars"
        case .memory: return "brain.fill"
        case .instructions: return "doc.plaintext"
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
                            .foregroundStyle(Theme.brandFg)
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
                    .foregroundStyle(Theme.brandFg)
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
    // 多个来源会话时这个按钮跳最近的那个；要精选走右键菜单（Codex 的 MEMORY.md 关联 15 个）
    let jumpable = memory.relatedSessions.filter(\.exists)
    if let first = jumpable.first {
        acts.append(CardAction(
            icon: "bubble.left.and.bubble.right",
            help: jumpable.count > 1
                ? "跳到最近一次相关会话（共 \(jumpable.count) 个，右键可选）"
                : "跳到写下这条记忆的会话"
        ) { revealSession(first.sessionId) })
    }
    if memory.isEditable {
        acts.append(CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: memory.path) })
    }
    acts.append(CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: memory.path) })
    if memory.isDeletable {
        acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
    }
    return acts
}

/// 跳「会话」页并选中：与用量页/诊断页同一条链路（接收端在 PopoverRootView）
private func revealSession(_ sessionId: String) {
    NotificationCenter.default.post(name: .eurekaRevealSession, object: sessionId)
}

/// 「来源会话」按钮/菜单的标签（详情页工具条用）
private func sessionLabel(_ text: String) -> some View {
    HStack(spacing: 3) {
        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 10))
        Text(text).font(.system(size: 10.5))
    }
}

/// 「来源会话」菜单项：0 个不显示，1 个是按钮，多个折成子菜单
/// （Claude 一条记忆对一个会话；Codex 的 MEMORY.md 聚合 15 个）。
/// 记录文件已删除的置灰而不是隐藏 —— 让人知道这条记忆有来源，只是追不回去了。
@ViewBuilder
private func sessionMenuItems(_ memory: MemoryEntry) -> some View {
    let refs = memory.relatedSessions
    if refs.count == 1, let ref = refs[0] as MemorySessionRef? {
        Button("跳到来源会话") { revealSession(ref.sessionId) }
            .disabled(!ref.exists)
    } else if refs.count > 1 {
        Menu("来源会话（\(refs.filter(\.exists).count)/\(refs.count) 可跳转）") {
            ForEach(refs) { ref in
                Button("会话 \(ref.sessionId.prefix(8))") { revealSession(ref.sessionId) }
                    .disabled(!ref.exists)
            }
        }
    }
}

@ViewBuilder
private func memoryContextMenu(
    _ memory: MemoryEntry, service: SkillMemoryService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(memory.isEditable ? "查看 / 编辑" : "查看") { onOpen() }
    sessionMenuItems(memory)
    if memory.isEditable {
        Button("用默认编辑器打开") { service.openInEditor(path: memory.path) }
    }
    Button("在 Finder 中显示") { service.reveal(path: memory.path) }
    if memory.isDeletable {
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    }
}

/// 记忆类型 chip（库内条目才有意义：全局 CLAUDE.md 之类没有 frontmatter 分类）
@ViewBuilder
private func memoryTypeChip(_ memory: MemoryEntry) -> some View {
    if memory.libraryKey != nil, memory.memoryType != .other {
        TagChip(memory.memoryType.label, tint: Theme.brand)
    }
}

/// 图例用的一条水平线段（供 stroke 上虚线样式）
private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 记忆类型配色（库统计卡的类型分布段、图例共用）。只用现成语义色，不引入新色板。
private func typeColor(_ type: MemoryType) -> Color {
    switch type {
    case .feedback: return Theme.brand
    case .project: return Theme.gold
    case .user: return Theme.enabledGreen
    case .reference: return Theme.brand.opacity(0.55)
    case .other: return Theme.draftGray
    }
}

// MARK: - 记忆库（一个项目的 memory/ 目录折成一行）

/// 记忆库列表行：项目名 + 条目数 + 目录 + 可跳会话数 + 体积 · 最近更新 + chevron
private struct MemoryLibraryRow: View {
    let library: MemoryLibrary
    let onOpen: () -> Void

    var body: some View {
        KnowledgeRow(onOpen: onOpen) {
            HStack(spacing: 10) {
                SourceLogoTile(source: library.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(library.projectName) 记忆库")
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        // 0 条 = 只有一份 MEMORY.md（Qwen 会先建空索引），说清楚而不是显示个 0
                        if library.count == 0 {
                            TagChip("仅索引", neutral: true)
                        } else {
                            TagChip("\(library.count) 条", tint: Theme.brand)
                        }
                        if library.index == nil { TagChip("无索引", neutral: true) }
                        // 未被 MEMORY.md 收录 = agent 读不到的死记忆，必须显式报出来
                        if !library.unindexedEntries.isEmpty {
                            TagChip("\(library.unindexedEntries.count) 条未收录", tint: Theme.gold)
                        }
                    }
                    Text(abbreviateHome(library.directory))
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    MemoryLibraryMeta(library: library)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize()
            }
            // 同名不同源的库（Claude 与 Qwen 都有 aftership-semantic-layer）靠 logo 与路径区分
            .help(abbreviateHome(library.directory))
        } menu: {
            Button("查看记忆库") { onOpen() }
        }
    }
}

/// 记忆库图标卡（图标布局用）
private struct MemoryLibraryCard: View {
    let library: MemoryLibrary
    let onOpen: () -> Void

    var body: some View {
        KnowledgeCard(minHeight: 78, onOpen: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: library.source, size: 28)
                    Text(library.projectName)
                        .font(Theme.font.monoSkillName(13))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    // 与列表行同一套口径：0 条 = 只有一份 MEMORY.md
                    if library.count == 0 {
                        TagChip("仅索引", neutral: true)
                    } else {
                        TagChip("\(library.count) 条", tint: Theme.brand)
                    }
                }
                Text(abbreviateHome(library.directory))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text("记忆库").font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    MemoryLibraryMeta(library: library)
                }
            }
        } menu: {
            Button("查看记忆库") { onOpen() }
        }
    }
}

/// 库的尾部 meta：可跳会话数 + 体积 · 最近更新（行与卡共用，口径一致）
private struct MemoryLibraryMeta: View {
    let library: MemoryLibrary

    var body: some View {
        HStack(spacing: 8) {
            if library.linkedSessionCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 8.5))
                    Text("\(library.linkedSessionCount)")
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(Theme.goldFg)
                .help("\(library.linkedSessionCount) 个来源会话的记录还在，可以点开")
            }
            Text(formatBytes(library.sizeBytes))
                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            Text("·").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(library.latestModifiedAt, formatter: relativeFormatter)
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
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
                    // 标题用条目自己的名字（frontmatter name / 文件名）。用 scope 的话，
                    // 同一项目的几十条记忆会整列重名。
                    Text(memory.title)
                        .font(Theme.font.monoSkillName(13))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    ScopeBadge(isGlobal: isGlobal)
                }
                Text(memory.summary ?? abbreviateHome(memory.path))
                    .font(memory.summary == nil
                        ? .system(size: 10.5).monospaced() : .system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    memoryTypeChip(memory)
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
    /// 记忆库二级页传 false：库里每条都属于同一个项目，标题已经写明，
    /// 再逐行重复「项目」徽标 + 项目名会白占大半行宽
    var showsScope = true

    private var isGlobal: Bool { memory.projectName == nil }

    var body: some View {
        KnowledgeRow(
            actions: memoryActions(memory, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                SourceLogoTile(source: memory.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(memory.title)
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        if showsScope { ScopeBadge(isGlobal: isGlobal) }
                        memoryTypeChip(memory)
                        if memory.kind == .generated { TagChip("只读", neutral: true) }
                    }
                    Text(memory.summary ?? abbreviateHome(memory.path))
                        .font(memory.summary == nil
                            ? .system(size: 10).monospaced() : .system(size: 10))
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
            if showsScope, let project = memory.projectName { TagChip(project) }
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
    /// 关联小图里点到别的记忆 → 打开那一条
    var onOpenMemory: ((MemoryEntry) -> Void)?

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?
    @State private var selectedNode: MemoryGraph.NodeID?
    /// 关联小图默认展开（它是这条记忆"为什么存在"的唯一线索）
    @State private var showRelations = true

    init(
        memory: MemoryEntry, service: SkillMemoryService,
        onBack: @escaping () -> Void, onDelete: @escaping () -> Void,
        onOpenMemory: ((MemoryEntry) -> Void)? = nil
    ) {
        self.memory = memory
        self.service = service
        self.onBack = onBack
        self.onDelete = onDelete
        self.onOpenMemory = onOpenMemory
        // init 即加载：避免首帧空白（记忆均为小文件，主线程读取无感）
        _text = State(initialValue: service.readContent(path: memory.path) ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !editing, let relation {
                relationCard(relation)
                Divider()
            }
            if editing {
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
                    .padding(8)
            } else {
                MarkdownDocumentCard(text: Self.strippingFrontmatter(text))
            }
            Divider()
            footer
        }
    }

    /// 预览时剥掉 frontmatter：name / description / type / originSessionId 已经由顶栏与
    /// 关联区呈现，正文再照抄一遍 YAML 只是噪声。**编辑态与保存写回的始终是原文**。
    static func strippingFrontmatter(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return raw }
        return lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 关联小图（本条 + 引用它/它引用的记忆 + 来源会话）

    /// nil = 这条记忆不属于记忆库，或它没有任何关联（那就别占版面画一个孤点）
    private var relation: (library: MemoryLibrary, graph: MemoryGraph.Graph)? {
        guard let library = service.library(containing: memory) else { return nil }
        let graph = service.graph(for: library)
        guard let focus = graph.nodeID(forPath: memory.path) else { return nil }
        let sub = graph.subgraph(around: focus)
        guard sub.nodes.count > 1 else { return nil }
        return (library, sub)
    }

    @ViewBuilder
    private func relationCard(_ relation: (library: MemoryLibrary, graph: MemoryGraph.Graph)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .font(.system(size: 10)).foregroundStyle(Theme.brandFg)
                Text("关联").font(.system(size: 11, weight: .semibold))
                Text("\(relation.graph.nodes.count - 1) 处")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Button(showRelations ? "收起" : "展开") { showRelations.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
            }
            if showRelations {
                GeometryReader { geo in
                    // 高度固定 + 双向滚动：布局高度要等排完才知道，拿不到就先给一个够用的框
                    let result = MemoryGraphLayout.layout(
                        relation.graph, metrics: .compact(width: max(280, geo.size.width)))
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        MemoryGraphCanvasView(
                            result: result, selected: $selectedNode,
                            onOpenMemory: { path in
                                guard let entry = relation.library.allFiles
                                    .first(where: { $0.path == path }), entry.path != memory.path
                                else { return }
                                onOpenMemory?(entry)
                            },
                            onRevealSession: { revealSession($0) })
                    }
                }
                .frame(height: Self.relationHeight(relation.graph))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.surfaceTertiary)
    }

    /// 关联区高度：按**最长那一列**的节点数算，别把最后一行切一半。
    /// 行高取自 `Metrics.compact`（不硬编码，改度量时这里跟着变），上限 260 后由滚动接管。
    static func relationHeight(_ graph: MemoryGraph.Graph) -> CGFloat {
        let metrics = MemoryGraphLayout.Metrics.compact(width: 0)
        var perColumn: [String: Int] = [:]
        for node in graph.nodes {
            switch node.kind {
            case .entry(let type): perColumn[type.rawValue, default: 0] += 1
            case .session: perColumn["session", default: 0] += 1
            default: break
            }
        }
        let rows = max(1, perColumn.values.max() ?? 1)
        let needed = CGFloat(rows) * (metrics.nodeHeight + metrics.rowGap)
            - metrics.rowGap + metrics.margin * 2
        return min(260, needed)
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
            Text(memory.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let project = memory.projectName { TagChip(project) }
            memoryTypeChip(memory)
            Spacer(minLength: 8)
            // 来源会话：只在记录文件还在时给入口（跳过去是空页面比没入口更糟）。
            // 多个时折成下拉（Codex 的 MEMORY.md 聚合 15 次会话）。
            let jumpable = memory.relatedSessions.filter(\.exists)
            if jumpable.count == 1, let ref = jumpable.first {
                Button { revealSession(ref.sessionId) } label: { sessionLabel("来源会话") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.goldFg)
                    .help("跳到写下这条记忆的那次会话")
            } else if jumpable.count > 1 {
                Menu {
                    ForEach(jumpable) { ref in
                        Button("会话 \(ref.sessionId.prefix(8))") { revealSession(ref.sessionId) }
                    }
                } label: {
                    sessionLabel("来源会话 \(jumpable.count)")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.goldFg)
                .help("这条记忆聚合了 \(jumpable.count) 次会话")
            }
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

// MARK: - 记忆库二级页（库统计 + 类型筛选 + 列表/图谱）

/// 一个记忆库的内容页。交互与 `SkillDetailView` 同构（顶部返回 + 内嵌，不开新窗口）。
private struct MemoryLibraryView: View {
    let library: MemoryLibrary
    @ObservedObject var service: SkillMemoryService
    let onBack: () -> Void
    let onOpenMemory: (MemoryEntry) -> Void
    let onDelete: (MemoryEntry) -> Void

    @State private var layout: KnowledgeLayout = .list
    /// 类型筛选（nil = 全部）
    @State private var typeFilter: MemoryType?
    /// 只看「未被索引收录」的条目（漂移提示里的开关）
    @State private var showingUnindexedOnly = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    stats
                    driftNotice
                    typeChips
                    if layout == .graph {
                        MemoryGraphSection(
                            library: library, service: service, onOpenMemory: onOpenMemory)
                    } else {
                        list
                    }
                }
                .padding(22)
            }
            .background(Theme.surfaceSecondary)
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
            SourceBadge(source: library.source, size: 12)
            Text("\(library.projectName) 记忆库")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            LayoutToggle(layout: $layout, cases: [.list, .graph])
            Button { service.reveal(path: library.directory) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示记忆库目录")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stats: some View {
        let breakdown = library.typeBreakdown
        return StatOverviewCard(
            value: "\(library.count)", unit: "条记忆",
            subtitle: formatBytes(library.sizeBytes)
                + " · 最近 " + relativeFormatter.localizedString(
                    for: library.latestModifiedAt, relativeTo: Date()),
            distributionTitle: "类型分布",
            segments: MemoryType.allCases.compactMap { type in
                guard let count = breakdown[type], count > 0 else { return nil }
                return .init(label: type.label, count: count, color: typeColor(type))
            },
            trailingNote: library.linkedSessionCount > 0
                ? "可跳会话 \(library.linkedSessionCount)" : nil)
    }

    /// 索引漂移提示。**这是这一页最有用的一句话**：未被 `MEMORY.md` 收录的条目，
    /// agent 下次读索引时看不到，等于白写。点一下就把列表筛到这些条目上。
    @ViewBuilder
    private var driftNotice: some View {
        let unindexed = library.unindexedEntries
        let dangling = library.danglingIndexRefs
        if !unindexed.isEmpty || !dangling.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.goldFg)
                    Text("索引与目录不一致").font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 8)
                    if !unindexed.isEmpty {
                        Button(showingUnindexedOnly ? "显示全部" : "只看未收录") {
                            showingUnindexedOnly.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                    }
                }
                if !unindexed.isEmpty {
                    Text("\(unindexed.count) 条记忆没被 MEMORY.md 收录 —— agent 读索引时看不到它们："
                        + unindexed.prefix(3).map(\.title).joined(separator: "、")
                        + (unindexed.count > 3 ? " 等" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if !dangling.isEmpty {
                    Text("\(dangling.count) 条索引条目指向已不存在的文件："
                        + dangling.prefix(3).joined(separator: "、"))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .fill(Theme.gold.opacity(0.08)))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.3), lineWidth: 0.8))
        }
    }

    @ViewBuilder
    private var typeChips: some View {
        let breakdown = library.typeBreakdown
        let present = MemoryType.allCases.filter { (breakdown[$0] ?? 0) > 0 }
        if present.count > 1 {
            CapsuleTabTray {
                CapsuleTabButton(
                    title: "全部 \(library.count)", fillWidth: false, isSelected: typeFilter == nil
                ) { typeFilter = nil }
                ForEach(present, id: \.self) { type in
                    CapsuleTabButton(
                        title: "\(type.label) \(breakdown[type] ?? 0)",
                        icon: type.icon, fillWidth: false, isSelected: typeFilter == type
                    ) { typeFilter = (typeFilter == type ? nil : type) }
                }
            }
        }
    }

    /// 索引在最前（它是这个库的目录），其后是按类型 / 未收录筛选后的条目
    private var items: [MemoryEntry] {
        if showingUnindexedOnly { return library.unindexedEntries }
        let entries = library.entries.filter { typeFilter == nil || $0.memoryType == typeFilter }
        guard typeFilter == nil, let index = library.index else { return entries }
        return [index] + entries
    }

    @ViewBuilder
    private var list: some View {
        let rows = items
        if rows.isEmpty {
            EmptyStateView(icon: "brain.fill", title: "没有匹配的记忆")
        } else {
            KnowledgeListContainer {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, memory in
                        MemoryListRow(
                            memory: memory, service: service,
                            onOpen: { onOpenMemory(memory) },
                            onDelete: { onDelete(memory) },
                            showsScope: false)
                        if index < rows.count - 1 {
                            Divider().opacity(0.4).padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 图谱区块（图例 + 画布；顶层图谱模式与库二级页共用）

/// 一个记忆库的关系图。画布宽度由 `GeometryReader` 给，超宽时横向滚动
/// （`MemoryGraphLayout` 只在节点过多时降级，不会因为多一条泳道就不画）。
private struct MemoryGraphSection: View {
    let library: MemoryLibrary
    @ObservedObject var service: SkillMemoryService
    let onOpenMemory: (MemoryEntry) -> Void

    @State private var selected: MemoryGraph.NodeID?

    var body: some View {
        let graph = service.graph(for: library)
        VStack(alignment: .leading, spacing: 10) {
            if graph.entryCount == 0 {
                // 只有一份 MEMORY.md 的库（Qwen 会先建空索引）：画布会是空的，说清楚而不是留个空框
                EmptyStateView(
                    icon: "books.vertical",
                    title: "这个记忆库还只有索引",
                    hint: "\(library.projectName) 的 memory/ 目录里只有 MEMORY.md，还没有记忆条目")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                legend(graph)
                canvas(graph)
            }
        }
    }

    @ViewBuilder
    private func canvas(_ graph: MemoryGraph.Graph) -> some View {
        Group {
            GeometryReader { geo in
                // 走 service 的缓存：这里在 body 里，不缓存就是每帧重排 126 个节点
                let result = service.layout(for: library, width: max(320, geo.size.width))
                if let degraded = result.degraded {
                    degradedNote(degraded)
                } else {
                    ScrollView([.horizontal, .vertical], showsIndicators: true) {
                        MemoryGraphCanvasView(
                            result: result, selected: $selected,
                            onOpenMemory: { path in
                                guard let entry = library.allFiles
                                    .first(where: { $0.path == path }) else { return }
                                onOpenMemory(entry)
                            },
                            onRevealSession: { revealSession($0) })
                    }
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5))
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous))
                }
            }
            .frame(height: 470)
        }
    }

    /// 图例 + **把省掉的东西说出来**：解析不到的 `[[链接]]`、已删除的来源会话都要显式计数，
    /// 不能让人以为图上画的就是全部。
    @ViewBuilder
    private func legend(_ graph: MemoryGraph.Graph) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                legendItem("引用", color: Theme.brand.opacity(0.55), dashed: false)
                legendItem("收录", color: Theme.brand.opacity(0.28), dashed: true)
                legendItem("来源会话", color: Theme.gold.opacity(0.7), dashed: true)
                Spacer(minLength: 0)
                Text("\(graph.entryCount) 条记忆 · \(graph.sessionCount) 个会话")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if graph.unresolvedLinkCount > 0 || graph.missingSessionCount > 0 {
                HStack(spacing: 10) {
                    if graph.unresolvedLinkCount > 0 {
                        Text("\(graph.unresolvedLinkCount) 条 [[链接]] 找不到目标，未画边")
                    }
                    if graph.missingSessionCount > 0 {
                        Text("\(graph.missingSessionCount) 条记忆的来源会话已删除（灰色虚线，点不开）")
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func legendItem(_ label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            // 必须 stroke 一条真的线段：`Capsule().strokeBorder` 在 1.4pt 高的 frame 里
            // 会退化成看不见（描边比形状还厚），图例就只剩文字了
            LegendLine()
                .stroke(color, style: StrokeStyle(lineWidth: 1.4, dash: dashed ? [2.5, 2.5] : []))
                .frame(width: 16, height: 1.4)
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func degradedNote(_ degraded: MemoryGraphLayout.Degradation) -> some View {
        switch degraded {
        case .tooManyNodes(let count, let limit):
            EmptyStateView(
                icon: "square.stack.3d.up.slash",
                title: "这个库太大，图谱不画了",
                hint: "\(count) 个节点超过上限 \(limit)；用上面的类型筛选缩小范围，或看列表")
        }
    }
}
