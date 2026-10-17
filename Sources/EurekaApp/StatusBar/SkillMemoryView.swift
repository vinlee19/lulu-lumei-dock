import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// Skills & memory manager (purple-gold redesign): stats overview card + source filter chips + flat
/// list/icon views + inline detail. The sibling Skills / Memory tabs share this view; mode decides
/// whether it shows only skills or only memories. Skill rows/cards carry an enable toggle (green =
/// enabled / grey = disabled); memories have no toggle and are labeled by scope (global/project).
struct SkillMemoryView: View {
    /// Tab mode: skills / memory / instructions (all three pages share this one view)
    enum Mode {
        case skills
        case memory
        /// User-maintained persistent instructions like CLAUDE.md / AGENTS.md. **Kept apart from
        /// memory**: they're rules written for the agent, not memories the agent accumulated;
        /// mixing them into one number would make "how many memories" meaningless.
        case instructions

        var title: String {
            switch self {
            case .skills: return "Skills"
            case .memory: return "Memory"
            case .instructions: return L10n.text("Instructions", zhHans: "指令")
            }
        }
        var searchPlaceholder: String {
            switch self {
            case .skills: return L10n.text("Search skills", zhHans: "搜索技能")
            case .memory: return L10n.text("Search memories", zhHans: "搜索记忆")
            case .instructions: return L10n.text("Search instruction files", zhHans: "搜索指令文件")
            }
        }
        var noun: String {
            switch self {
            case .skills: return L10n.text("skills", zhHans: "技能")
            case .memory: return L10n.text("memories", zhHans: "记忆")
            case .instructions: return L10n.text("instructions", zhHans: "指令")
            }
        }
    }

    @ObservedObject var service: SkillMemoryService
    let mode: Mode
    @ObservedObject var usageService: UsageService
    /// Used by the skill detail page's "recent sessions" jump; when nil that card greys out as
    /// unreachable (compatible with PreviewRenderer and other existing construction sites)
    var sessionBrowser: SessionBrowserService? = nil

    /// Inline skill detail (entered by clicking a card; nil = list)
    @State private var detail: SkillDetailTarget?
    /// Inline memory detail (nil = list)
    @State private var memoryDetail: MemoryEntry?
    /// Opened memory library (entered by clicking a library row; nil = top-level list)
    @State private var openedLibrary: MemoryLibrary?
    /// Which library the top-level graph mode is showing (nil = the first one, i.e. the one with
    /// the most entries)
    @State private var graphLibraryKey: String?
    /// Source filter (nil = all)
    @State private var selectedSource: AgentSource?
    /// Management area layout: list / icon grid (list by default, matching the design mockup)
    @State private var layout: KnowledgeLayout = .list

    @State private var creating: CreateTarget?
    @State private var newName = ""
    @State private var deleting: DeleteTarget?

    /// Offscreen rendering/preview only: sets the initial layout and a memory library to open
    /// directly (the second-level page has no other entry the offscreen renderer can click -- it
    /// only renders the first frame)
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
                    // When detail switches straight from skill A to skill B (⌘K jump), target
                    // changes but view identity doesn't, so SwiftUI reuses the old state; target.id
                    // forces a rebuild so onAppear reloads all four states
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
                // This week's total hits (stats card subtitle): all sources, this week's window,
                // fetched once
                usageService.loadSkillRanking(source: nil, from: UsageService.DashboardPeriod.week.startDate, to: Date())
            }
            consumeFocus()
        }
        .onChange(of: service.focusPath) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
        .alert(L10n.format("New %@", zhHans: "新建%@", creating?.label ?? ""), isPresented: creatingBinding) {
            TextField(L10n.text("Name", zhHans: "名称"), text: $newName)
            Button(L10n.text("Create", zhHans: "创建")) {
                if let creating, !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                    if creating.isSkill {
                        service.createSkill(source: creating.source, name: newName)
                    } else {
                        service.createMemory(source: creating.source, name: newName)
                    }
                }
                newName = ""
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) { newName = "" }
        }
        .confirmationDialog(
            deleting.map {
                L10n.format(
                    "Delete “%@”? The file moves to the Trash and can be restored.",
                    zhHans: "删除「%@」？文件会移入废纸篓，可恢复。",
                    $0.title)
            } ?? "",
            isPresented: deletingBinding, titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                deleting?.perform(service)
                detail = nil
                memoryDetail = nil
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    // MARK: - Top bar (title + search + new + refresh + layout toggle)

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
            RefreshButton(help: L10n.format("Force rescan %@", zhHans: "强制重扫%@", mode.noun)) {
                service.refresh(force: true)
            }
            // The graph only makes sense for memories (memories have [[links]] between them and
            // point at origin sessions; skills have no such relations)
            LayoutToggle(
                layout: $layout,
                cases: mode == .memory ? KnowledgeLayout.allCases : KnowledgeLayout.withoutGraph)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// "New": compact purple icon menu (same round background as the refresh button), one menu item
    /// per CLI.
    private var createMenu: some View {
        Menu {
            if mode == .skills {
                Button(L10n.text("Claude skill", zhHans: "Claude 技能")) { startCreate(.claude, isSkill: true, L10n.text("Claude skill", zhHans: "Claude 技能")) }
                Button(L10n.text("Codex skill", zhHans: "Codex 技能")) { startCreate(.codex, isSkill: true, L10n.text("Codex skill", zhHans: "Codex 技能")) }
                Button(L10n.text("OpenCode skill", zhHans: "OpenCode 技能")) { startCreate(.opencode, isSkill: true, L10n.text("OpenCode skill", zhHans: "OpenCode 技能")) }
                Button(L10n.text("Grok skill", zhHans: "Grok 技能")) { startCreate(.grok, isSkill: true, L10n.text("Grok skill", zhHans: "Grok 技能")) }
                Button(L10n.text("Antigravity skill", zhHans: "Antigravity 技能")) { startCreate(.antigravity, isSkill: true, L10n.text("Antigravity skill", zhHans: "Antigravity 技能")) }
                Button(L10n.text("Kimi skill", zhHans: "Kimi 技能")) { startCreate(.kimi, isSkill: true, L10n.text("Kimi skill", zhHans: "Kimi 技能")) }
                Button(L10n.text("Gemini skill", zhHans: "Gemini 技能")) { startCreate(.gemini, isSkill: true, L10n.text("Gemini skill", zhHans: "Gemini 技能")) }
                Button(L10n.text("Qwen skill", zhHans: "Qwen 技能")) { startCreate(.qwen, isSkill: true, L10n.text("Qwen skill", zhHans: "Qwen 技能")) }
                Button(L10n.text("Hermes skill", zhHans: "Hermes 技能")) { startCreate(.hermes, isSkill: true, L10n.text("Hermes skill", zhHans: "Hermes 技能")) }
                Button(L10n.text("Cursor skill", zhHans: "Cursor 技能")) { startCreate(.cursor, isSkill: true, L10n.text("Cursor skill", zhHans: "Cursor 技能")) }
                Button(L10n.text("CodeBuddy skill", zhHans: "CodeBuddy 技能")) { startCreate(.codebuddy, isSkill: true, L10n.text("CodeBuddy skill", zhHans: "CodeBuddy 技能")) }
                Button(L10n.text("Qoder skill", zhHans: "Qoder 技能")) { startCreate(.qoder, isSkill: true, L10n.text("Qoder skill", zhHans: "Qoder 技能")) }
                Button(L10n.text("Trae skill", zhHans: "Trae 技能")) { startCreate(.trae, isSkill: true, L10n.text("Trae skill", zhHans: "Trae 技能")) }
                Button(L10n.text("ZCode skill", zhHans: "ZCode 技能")) { startCreate(.zcode, isSkill: true, L10n.text("ZCode skill", zhHans: "ZCode 技能")) }
            } else if mode == .memory {
                Button(L10n.text("Claude memory", zhHans: "Claude 记忆")) { startCreate(.claude, isSkill: false, L10n.text("Claude memory", zhHans: "Claude 记忆")) }
                Button(L10n.text("OpenCode memory", zhHans: "OpenCode 记忆")) { startCreate(.opencode, isSkill: false, L10n.text("OpenCode memory", zhHans: "OpenCode 记忆")) }
                Button(L10n.text("Grok memory", zhHans: "Grok 记忆")) { startCreate(.grok, isSkill: false, L10n.text("Grok memory", zhHans: "Grok 记忆")) }
                Button(L10n.text("Qwen memory", zhHans: "Qwen 记忆")) { startCreate(.qwen, isSkill: false, L10n.text("Qwen memory", zhHans: "Qwen 记忆")) }
                Button(L10n.text("CodeBuddy memory", zhHans: "CodeBuddy 记忆")) { startCreate(.codebuddy, isSkill: false, L10n.text("CodeBuddy memory", zhHans: "CodeBuddy 记忆")) }
                Button(L10n.text("Qoder memory", zhHans: "Qoder 记忆")) { startCreate(.qoder, isSkill: false, L10n.text("Qoder memory", zhHans: "Qoder 记忆")) }
                // hermes memory = fixed memories/MEMORY.md (name ignored, see createMemory)
                Button(L10n.text("Hermes memory (MEMORY.md)", zhHans: "Hermes 记忆（MEMORY.md）")) { service.createMemory(source: .hermes, name: "MEMORY") }
                // trae memory = fixed memory/user_profile.md (only the CN install has a memory
                // library, see createMemory)
                Button(L10n.text("Trae memory (user_profile.md)", zhHans: "Trae 记忆（user_profile.md）")) {
                    service.createMemory(source: .trae, name: "user_profile")
                }
            } else {
                // Instruction files: for these three CLIs the "global memory" is really a
                // fixed-name instruction file, so the create entry follows the Instructions page
                // (Claude's CLAUDE.md is made by the user or /init, not offered here)
                Button(L10n.text("Codex instructions (AGENTS.md)", zhHans: "Codex 指令（AGENTS.md）")) { service.createMemory(source: .codex, name: "AGENTS") }
                Button(L10n.text("Kimi instructions (AGENTS.md)", zhHans: "Kimi 指令（AGENTS.md）")) { service.createMemory(source: .kimi, name: "AGENTS") }
                Button(L10n.text("Gemini instructions (GEMINI.md)", zhHans: "Gemini 指令（GEMINI.md）")) { service.createMemory(source: .gemini, name: "GEMINI") }
                Button(L10n.text("Trae instructions (user_rules.md)", zhHans: "Trae 指令（user_rules.md）")) {
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
        .help(mode == .skills ? L10n.text("New skill", zhHans: "新建技能") : L10n.text("New memory", zhHans: "新建记忆"))
    }

    // MARK: - Body (stats overview card + source chips + flat list/grid)

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
                    allLabel: L10n.text("All", zhHans: "全部"),
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
            // Instruction files have no memory library and no graph (no [[links]] between them, no
            // origin sessions) → list/cards only
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
                        // Memory libraries come first: a project's 70+ memories fold into one row;
                        // click in to see entries
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

    /// Top-level graph mode: pick a memory library first (a graph is naturally "one per library"),
    /// then draw its relation graph
    @ViewBuilder
    private func memoryGraphBoard(_ libraries: [MemoryLibrary]) -> some View {
        if libraries.isEmpty {
            EmptyStateView(
                icon: "point.3.filled.connected.trianglepath.dotted",
                title: service.scanning
                    ? L10n.text("Scanning…", zhHans: "正在扫描…")
                    : L10n.text("No memory libraries yet", zhHans: "还没有记忆库"),
                hint: service.isSearching
                    ? L10n.text(
                        "The graph stays hidden while you search (clear the search box to see it)",
                        zhHans: "搜索中不显示图谱（清空搜索框看图）")
                    : L10n.text(
                        "Memory libraries come from Claude / Qwen projects/<project>/memory directories",
                        zhHans: "记忆库来自 Claude / Qwen 的 projects/<项目>/memory 目录"))
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

    // MARK: - Stats overview card

    /// Icon of the "All" chip (meaning differs per page)
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
                value: "\(totalCount)", unit: L10n.text("instruction files", zhHans: "指令文件"),
                subtitle: L10n.format(
                    "%1$@ sources · %2$@",
                    zhHans: "%1$@ 来源 · %2$@",
                    String(service.instructionSourceCount),
                    formatBytes(service.instructionTotalBytes)),
                distributionTitle: L10n.text("Scope", zhHans: "范围分布"),
                segments: [
                    .init(label: L10n.text("Global", zhHans: "全局"), count: scope.global, color: Theme.brand),
                    .init(label: L10n.text("Project root", zhHans: "项目根"), count: scope.project, color: Theme.gold),
                ])
        } else if mode == .skills {
            let enabled = service.skills.filter(\.enabled).count
            let projectCount = service.skills.filter { $0.scope.projectName != nil }.count
            let weekHits = usageService.skillRanking.reduce(0) { $0 + $1.count }
            StatOverviewCard(
                value: "\(totalCount)", unit: L10n.text("skills", zhHans: "技能"),
                subtitle: L10n.format("Hits this week %@", zhHans: "本周命中 %@", String(weekHits)),
                distributionTitle: L10n.text("Enablement", zhHans: "启用分布"),
                segments: [
                    .init(label: L10n.text("Enabled", zhHans: "启用"), count: enabled, color: Theme.enabledGreen),
                    .init(label: L10n.text("Disabled", zhHans: "停用"), count: totalCount - enabled, color: Theme.draftGray),
                ],
                trailingNote: projectCount > 0
                    ? L10n.format("Project-level %@", zhHans: "项目级 %@", String(projectCount)) : nil)
        } else {
            // Basis: service.memoryEntries (standalone entries + every file inside libraries). This
            // used to read the filtered list array, which counted none of the 97 project memories
            // -- so the number was always low.
            let scope = service.memoryScopeBreakdown
            let libraryNote = service.libraries.isEmpty
                ? nil : L10n.format(
                    "%@ memory libraries", zhHans: "%@ 个记忆库", String(service.libraries.count))
            StatOverviewCard(
                value: "\(totalCount)", unit: L10n.text("memories", zhHans: "记忆"),
                subtitle: L10n.format(
                    "%1$@ sources · %2$@",
                    zhHans: "%1$@ 来源 · %2$@",
                    String(service.memorySourceCount),
                    formatBytes(service.memoryTotalBytes)),
                distributionTitle: L10n.text("Scope", zhHans: "范围分布"),
                segments: [
                    .init(label: L10n.text("Global", zhHans: "全局"), count: scope.global, color: Theme.brand),
                    .init(label: L10n.text("Project libraries", zhHans: "项目记忆库"), count: scope.library, color: Theme.enabledGreen),
                ],
                trailingNote: libraryNote)
        }
    }

    // MARK: - Counting / filtering / sorting

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

    /// Sources with data, by count descending (chip order matches the design mockup).
    ///
    /// **Compute counts into a dictionary first, then sort**: calling `count(for:)` in the
    /// comparator filters the whole table on every comparison (12 sources ≈ 30 comparisons × two
    /// calls × hundreds of rows = tens of thousands of passes per frame, and body re-evaluates
    /// repeatedly). rawValue also breaks ties -- `sorted` isn't stable, so chips with equal counts
    /// would otherwise jitter.
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

    /// Skills: source filter + hit count descending (those without hit data last, by name),
    /// prefetching stats to avoid rebuilding the table
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

    /// Memories: source filter + global first, then modification time descending
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

    /// Memory libraries (service.libraries is empty while searching -- library entries are then
    /// flattened into memoryItems)
    private var libraryItems: [MemoryLibrary] {
        service.libraries(for: selectedSource)
    }

    /// Instruction files: source filter + global first, then modification time descending (same
    /// ordering as memories)
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

    /// Cross-page jump target: find this tab's entry by path and open its detail (not cleared if
    /// not found -- it may belong to another tab, or scanning hasn't finished). Uses
    /// `knowledgeSnapshot()` (the full set) rather than
    /// `service.skills`/`memoryEntries`/`instructions`: those three are the current search-filtered
    /// views, while the ⌘K index is built over the full set; the consumer must use the same basis,
    /// or switching pages with leftover searchText makes entries that do exist impossible to find.
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
                Text(L10n.text("Scanning…", zhHans: "正在扫描…")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                icon: emptyIcon,
                title: service.isSearching || selectedSource != nil
                    ? L10n.text("No matches", zhHans: "没有匹配项")
                    : L10n.format("No %@ yet", zhHans: "还没有%@", mode.noun),
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : (mode == .instructions
                        ? L10n.text(
                            "CLAUDE.md / AGENTS.md / GEMINI.md at each repository root shows up here",
                            zhHans: "各仓库根的 CLAUDE.md / AGENTS.md / GEMINI.md 会出现在这里")
                        : L10n.format(
                            "Use + at the top right to create %@ for each CLI",
                            zhHans: "点右上角「＋」创建各 CLI 的%@",
                            mode.noun)))
        }
    }

    private var emptyIcon: String {
        switch mode {
        case .skills: return "wand.and.stars"
        case .memory: return "brain.fill"
        case .instructions: return "doc.plaintext"
        }
    }

    // MARK: - Actions

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

/// Abbreviates the home directory to ~ (for displaying memory paths)
private func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

// MARK: - Data carriers

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

// MARK: - Cards

/// Skill action menu (shared by cards / list rows)
@ViewBuilder
private func skillContextMenu(
    _ skill: SkillEntry, service: SkillMemoryService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(L10n.text("View details", zhHans: "查看详情")) { onOpen() }
    Button(skill.enabled ? L10n.text("Disable", zhHans: "停用") : L10n.text("Enable", zhHans: "启用")) { service.setSkillEnabled(skill, !skill.enabled) }
    Button(L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: skill.path) }
    Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: skill.path) }
    Divider()
    Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) { onDelete() }
}

private func skillActions(
    _ skill: SkillEntry, service: SkillMemoryService, onDelete: @escaping () -> Void
) -> [CardAction] {
    [
        CardAction(icon: "pencil", help: L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: skill.path) },
        CardAction(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: skill.path) },
        CardAction(icon: "trash", destructive: true, help: L10n.text("Move to Trash (can be restored)", zhHans: "移入废纸篓（可恢复）")) { onDelete() },
    ]
}

/// Skill icon card: logo + monospaced name + enable toggle + description (2 lines) + hit count ·
/// project · last used; actions appear on hover
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
                // Always takes 2 lines: grid cards stay equal height, avoiding ragged gaps in
                // LazyVGrid
                Text(skill.description ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true).lineSpacing(1.5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let stat, stat.count > 0 {
                        Text(L10n.format("%@ hits", zhHans: "命中 %@ 次", String(stat.count)))
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

/// Skill list row: logo + two-line name/description + usage bar · hit count + last used + enable
/// toggle; actions appear on hover
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
                Text(L10n.format("%@ times", zhHans: "%@ 次", String(stat.count)))
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
    // With several origin sessions this button jumps to the most recent; picking one goes through
    // the context menu (Codex's MEMORY.md links 15)
    let jumpable = memory.relatedSessions.filter(\.exists)
    if let first = jumpable.first {
        acts.append(CardAction(
            icon: "bubble.left.and.bubble.right",
            help: jumpable.count > 1
                ? L10n.format(
                    "Jump to the latest related session (%@ total; right-click to choose)",
                    zhHans: "跳到最近一次相关会话（共 %@ 个，右键可选）",
                    String(jumpable.count))
                : L10n.text("Jump to the session that wrote this memory", zhHans: "跳到写下这条记忆的会话")
        ) { revealSession(first.sessionId) })
    }
    if memory.isEditable {
        acts.append(CardAction(icon: "pencil", help: L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: memory.path) })
    }
    acts.append(CardAction(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: memory.path) })
    if memory.isDeletable {
        acts.append(CardAction(icon: "trash", destructive: true, help: L10n.text("Move to Trash (can be restored)", zhHans: "移入废纸篓（可恢复）")) { onDelete() })
    }
    return acts
}

/// Jumps to the Sessions page and selects it: the same path as the usage/diagnostics pages
/// (receiver is in PopoverRootView)
private func revealSession(_ sessionId: String) {
    NotificationCenter.default.post(name: .eurekaRevealSession, object: sessionId)
}

/// Label of the "origin session" button/menu (used by the detail page toolbar)
private func sessionLabel(_ text: String) -> some View {
    HStack(spacing: 3) {
        Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 10))
        Text(text).font(.system(size: 10.5))
    }
}

/// "Origin session" menu items: hidden for 0, a button for 1, folded into a submenu for several
/// (one Claude memory maps to one session; Codex's MEMORY.md aggregates 15). Ones whose transcript
/// file was deleted are greyed out rather than hidden -- so it's clear the memory has an origin
/// that just can't be traced anymore.
@ViewBuilder
private func sessionMenuItems(_ memory: MemoryEntry) -> some View {
    let refs = memory.relatedSessions
    if refs.count == 1, let ref = refs[0] as MemorySessionRef? {
        Button(L10n.text("Jump to source session", zhHans: "跳到来源会话")) { revealSession(ref.sessionId) }
            .disabled(!ref.exists)
    } else if refs.count > 1 {
        Menu(L10n.format(
            "Source sessions (%1$@/%2$@ available)",
            zhHans: "来源会话（%1$@/%2$@ 可跳转）",
            String(refs.filter(\.exists).count), String(refs.count))) {
            ForEach(refs) { ref in
                Button(L10n.format("Session %@", zhHans: "会话 %@", String(ref.sessionId.prefix(8)))) { revealSession(ref.sessionId) }
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
    Button(memory.isEditable ? L10n.text("View / Edit", zhHans: "查看 / 编辑") : L10n.text("View", zhHans: "查看")) { onOpen() }
    sessionMenuItems(memory)
    if memory.isEditable {
        Button(L10n.text("Open in default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: memory.path) }
    }
    Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: memory.path) }
    if memory.isDeletable {
        Divider()
        Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) { onDelete() }
    }
}

/// Memory type chip (only meaningful for library entries: global ones like CLAUDE.md have no
/// frontmatter type)
@ViewBuilder
private func memoryTypeChip(_ memory: MemoryEntry) -> some View {
    if memory.libraryKey != nil, memory.memoryType != .other {
        TagChip(memory.memoryType.label, tint: Theme.brand)
    }
}

/// A horizontal line segment for the legend (to apply a dashed stroke style)
private struct LegendLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// Memory type colors (shared by the library stats card's type distribution segments and the
/// legend). Uses only existing semantic colors, no new palette.
private func typeColor(_ type: MemoryType) -> Color {
    switch type {
    case .feedback: return Theme.brand
    case .project: return Theme.gold
    case .user: return Theme.enabledGreen
    case .reference: return Theme.brand.opacity(0.55)
    case .other: return Theme.draftGray
    }
}

// MARK: - Memory library (a project's memory/ directory folded into one row)

/// Memory library list row: project name + entry count + directory + jumpable session count + size
/// · last updated + chevron
private struct MemoryLibraryRow: View {
    let library: MemoryLibrary
    let onOpen: () -> Void

    var body: some View {
        KnowledgeRow(onOpen: onOpen) {
            HStack(spacing: 10) {
                SourceLogoTile(source: library.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(L10n.format("%@ memory library", zhHans: "%@ 记忆库", library.projectName))
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        // 0 entries = only a MEMORY.md (Qwen creates an empty index first); say so
                        // instead of showing a 0
                        if library.count == 0 {
                            TagChip(L10n.text("Index only", zhHans: "仅索引"), neutral: true)
                        } else {
                            TagChip(L10n.format("%@ entries", zhHans: "%@ 条", String(library.count)), tint: Theme.brand)
                        }
                        if library.index == nil { TagChip(L10n.text("No index", zhHans: "无索引"), neutral: true) }
                        // Not listed in MEMORY.md = dead memory the agent can't read; must be
                        // reported explicitly
                        if !library.unindexedEntries.isEmpty {
                            TagChip(L10n.format("%@ not indexed", zhHans: "%@ 条未收录", String(library.unindexedEntries.count)), tint: Theme.gold)
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
            // Same-name libraries from different sources (Claude and Qwen both have
            // aftership-semantic-layer) are told apart by logo and path
            .help(abbreviateHome(library.directory))
        } menu: {
            Button(L10n.text("View memory library", zhHans: "查看记忆库")) { onOpen() }
        }
    }
}

/// Memory library icon card (for the icon layout)
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
                    // Same basis as the list row: 0 entries = only a MEMORY.md
                    if library.count == 0 {
                        TagChip(L10n.text("Index only", zhHans: "仅索引"), neutral: true)
                    } else {
                        TagChip(L10n.format("%@ entries", zhHans: "%@ 条", String(library.count)), tint: Theme.brand)
                    }
                }
                Text(abbreviateHome(library.directory))
                    .font(.system(size: 10.5).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(L10n.text("Memory library", zhHans: "记忆库")).font(.system(size: 9.5)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    MemoryLibraryMeta(library: library)
                }
            }
        } menu: {
            Button(L10n.text("View memory library", zhHans: "查看记忆库")) { onOpen() }
        }
    }
}

/// Library trailing meta: jumpable session count + size · last updated (shared by row and card,
/// same basis)
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
                .help(L10n.format(
                    "%@ source sessions still have transcripts you can open",
                    zhHans: "%@ 个来源会话的记录还在，可以点开",
                    String(library.linkedSessionCount)))
            }
            Text(formatBytes(library.sizeBytes))
                .font(.system(size: 9.5).monospacedDigit()).foregroundStyle(.tertiary)
            Text("·").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            Text(library.latestModifiedAt, formatter: relativeFormatter)
                .font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
    }
}

/// Memory icon card: left color spine (global purple / project gold) + logo + name + scope badge +
/// path + project chip + size · time
private struct MemoryCard: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var isGlobal: Bool { memory.projectName == nil }

    var body: some View {
        // Border identical to Skills / Plans / Agents (no scope color spine); scope is expressed by
        // ScopeBadge
        KnowledgeCard(
            minHeight: 78,
            actions: memoryActions(memory, service: service, onDelete: onDelete),
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    SourceLogoTile(source: memory.source, size: 28)
                    // The title is the entry's own name (frontmatter name / file name). Using the
                    // scope would give dozens of memories in the same project identical titles down
                    // the column.
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
                    if memory.kind == .generated { TagChip(L10n.text("Read-only", zhHans: "只读"), neutral: true) }
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

/// Memory list row: logo + name/scope badge + path + project chip + size · time; actions appear on
/// hover (no toggle)
private struct MemoryListRow: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onOpen: () -> Void
    let onDelete: () -> Void
    /// The memory library page passes false: every entry in a library belongs to the same project,
    /// already named in the title; repeating the "Project" badge + project name on each row would
    /// waste most of the row width
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
                        if memory.kind == .generated { TagChip(L10n.text("Read-only", zhHans: "只读"), neutral: true) }
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

// MARK: - Inline memory detail (document card rendering + preview/edit switch, same layout as plan detail)

private struct MemoryDetailView: View {
    let memory: MemoryEntry
    let service: SkillMemoryService
    let onBack: () -> Void
    let onDelete: () -> Void
    /// Clicking another memory in the relation mini-graph → open that one
    var onOpenMemory: ((MemoryEntry) -> Void)?

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?
    @State private var selectedNode: MemoryGraph.NodeID?
    /// Relation mini-graph expanded by default (it's the only clue to "why this memory exists")
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
        // Load in init: avoids a blank first frame (memories are all small files, reading on the
        // main thread is imperceptible)
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

    /// Strips frontmatter in preview: name / description / type / originSessionId are already shown
    /// by the top bar and relation area; repeating the YAML in the body is just noise. **Edit mode
    /// and save always use the raw text**.
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

    // MARK: Relation mini-graph (this entry + memories referencing it / referenced by it + origin sessions)

    /// nil = this memory isn't in a memory library, or has no relations at all (then don't spend
    /// space drawing a lone dot)
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
                Text(L10n.text("Related", zhHans: "关联")).font(.system(size: 11, weight: .semibold))
                Text(L10n.format("%@ links", zhHans: "%@ 处", String(relation.graph.nodes.count - 1)))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                Spacer()
                Button(showRelations ? L10n.text("Collapse", zhHans: "收起") : L10n.text("Expand", zhHans: "展开")) { showRelations.toggle() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5))
            }
            if showRelations {
                GeometryReader { geo in
                    // Fixed height + two-axis scrolling: the layout height is only known after
                    // layout, so start with a frame big enough
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

    /// Relation area height: based on the node count of the **longest column**, so the last row
    /// isn't cut in half. Row height comes from `Metrics.compact` (not hardcoded, so it follows
    /// metric changes); capped at 260, after which scrolling takes over.
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
                    Text(L10n.text("Back", zhHans: "返回")).font(.system(size: 11))
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
            // Origin sessions: only offer an entry while the transcript file still exists (jumping
            // to an empty page is worse than no entry). Several fold into a dropdown (Codex's
            // MEMORY.md aggregates 15 sessions).
            let jumpable = memory.relatedSessions.filter(\.exists)
            if jumpable.count == 1, let ref = jumpable.first {
                Button { revealSession(ref.sessionId) } label: { sessionLabel(L10n.text("Source session", zhHans: "来源会话")) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.goldFg)
                    .help(L10n.text("Jump to the session that wrote this memory", zhHans: "跳到写下这条记忆的那次会话"))
            } else if jumpable.count > 1 {
                Menu {
                    ForEach(jumpable) { ref in
                        Button(L10n.format("Session %@", zhHans: "会话 %@", String(ref.sessionId.prefix(8)))) { revealSession(ref.sessionId) }
                    }
                } label: {
                    sessionLabel(L10n.format("Source sessions %@", zhHans: "来源会话 %@", String(jumpable.count)))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(Theme.goldFg)
                .help(L10n.format("This memory aggregates %@ sessions", zhHans: "这条记忆聚合了 %@ 次会话", String(jumpable.count)))
            }
            if memory.isEditable {
                CapsuleTabTray {
                    CapsuleTabButton(title: L10n.text("Preview", zhHans: "预览"), fillWidth: false, isSelected: !editing) { editing = false }
                    CapsuleTabButton(title: L10n.text("Edit", zhHans: "编辑"), fillWidth: false, isSelected: editing) { editing = true }
                }
                Button { service.openInEditor(path: memory.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Open in default editor", zhHans: "用默认编辑器打开"))
            }
            Button { service.reveal(path: memory.path) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"))
            if memory.isDeletable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
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
            Text(memory.isEditable ? memory.path : L10n.format("Codex generated state (read-only) · %@", zhHans: "Codex 生成状态（只读） · %@", memory.path))
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
                Button(L10n.text("Save", zhHans: "保存")) {
                    service.save(path: memory.path, content: text) { ok in
                        saveNote = ok ? L10n.text("Saved (a backup was kept before writing)", zhHans: "已保存（写前留有备份）") : L10n.text("Couldn't save", zhHans: "保存失败")
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

// MARK: - Memory library page (library stats + type filter + list/graph)

/// Content page of one memory library. Interaction mirrors `SkillDetailView` (back button at top +
/// inline, no new window).
private struct MemoryLibraryView: View {
    let library: MemoryLibrary
    @ObservedObject var service: SkillMemoryService
    let onBack: () -> Void
    let onOpenMemory: (MemoryEntry) -> Void
    let onDelete: (MemoryEntry) -> Void

    @State private var layout: KnowledgeLayout = .list
    /// Type filter (nil = all)
    @State private var typeFilter: MemoryType?
    /// Show only entries "not listed in the index" (the toggle in the drift hint)
    @State private var showingUnindexedOnly = false
    /// One-click index repair in progress (guards double clicks; the forced rescan afterwards makes
    /// the drift hint disappear on its own)
    @State private var repairingIndex = false

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
                    Text(L10n.text("Back", zhHans: "返回")).font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceBadge(source: library.source, size: 12)
            Text(L10n.format("%@ memory library", zhHans: "%@ 记忆库", library.projectName))
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            LayoutToggle(layout: $layout, cases: [.list, .graph])
            Button { service.reveal(path: library.directory) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Show the memory library folder in Finder", zhHans: "在 Finder 中显示记忆库目录"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var stats: some View {
        let breakdown = library.typeBreakdown
        return StatOverviewCard(
            value: "\(library.count)", unit: L10n.text("memories", zhHans: "条记忆"),
            subtitle: L10n.format(
                "%1$@ · updated %2$@",
                zhHans: "%1$@ · 最近 %2$@",
                formatBytes(library.sizeBytes),
                relativeFormatter.localizedString(
                    for: library.latestModifiedAt, relativeTo: Date())),
            distributionTitle: L10n.text("Types", zhHans: "类型分布"),
            segments: MemoryType.allCases.compactMap { type in
                guard let count = breakdown[type], count > 0 else { return nil }
                return .init(label: type.label, count: count, color: typeColor(type))
            },
            trailingNote: library.linkedSessionCount > 0
                ? L10n.format(
                    "%@ openable sessions", zhHans: "可跳会话 %@",
                    String(library.linkedSessionCount)) : nil)
    }

    /// Index drift hint. **This is the most useful sentence on the page**: entries not listed in
    /// `MEMORY.md` are invisible to the agent the next time it reads the index, so they're wasted.
    /// One click filters the list to them.
    @ViewBuilder
    private var driftNotice: some View {
        let unindexed = library.unindexedEntries
        let dangling = library.danglingIndexRefs
        if !unindexed.isEmpty || !dangling.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.goldFg)
                    Text(L10n.text("Index and directory are out of sync", zhHans: "索引与目录不一致")).font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 8)
                    if !unindexed.isEmpty {
                        Button(showingUnindexedOnly ? L10n.text("Show all", zhHans: "显示全部") : L10n.text("Unindexed only", zhHans: "只看未收录")) {
                            showingUnindexedOnly.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                    }
                    Button(repairingIndex ? L10n.text("Repairing…", zhHans: "修复中…") : L10n.text("Repair", zhHans: "一键修复")) {
                        repairingIndex = true
                        service.repairLibraryIndex(library) { _ in
                            repairingIndex = false
                            showingUnindexedOnly = false
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 10.5, weight: .medium))
                    .disabled(repairingIndex)
                    .help(L10n.text("Add missing entries and drop index lines that point at files that no longer exist (MEMORY.md is backed up before writing)", zhHans: "补录未收录条目、删除指向已不存在文件的索引行（写前自动备份 MEMORY.md）"))
                }
                if !unindexed.isEmpty {
                    Text(L10n.format(
                        "%1$@ memories are not listed in MEMORY.md — the agent will not see them when it reads the index: %2$@",
                        zhHans: "%1$@ 条记忆没被 MEMORY.md 收录 —— agent 读索引时看不到它们：%2$@",
                        String(unindexed.count),
                        unindexed.prefix(3).map(\.title).joined(separator: L10n.text(", ", zhHans: "、"))
                            + (unindexed.count > 3 ? L10n.text(" etc.", zhHans: " 等") : "")))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                if !dangling.isEmpty {
                    Text(L10n.format(
                        "%1$@ index entries point at files that no longer exist: %2$@",
                        zhHans: "%1$@ 条索引条目指向已不存在的文件：%2$@",
                        String(dangling.count),
                        dangling.prefix(3).joined(separator: L10n.text(", ", zhHans: "、"))))
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
                    title: L10n.format("All %@", zhHans: "全部 %@", String(library.count)), fillWidth: false, isSelected: typeFilter == nil
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

    /// The index comes first (it's this library's table of contents), followed by entries filtered
    /// by type / unindexed
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
            EmptyStateView(icon: "brain.fill", title: L10n.text("No matching memories", zhHans: "没有匹配的记忆"))
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

// MARK: - Graph section (legend + canvas; shared by top-level graph mode and the library page)

/// A memory library's relation graph. Canvas width comes from `GeometryReader`; scrolls
/// horizontally when too wide (`MemoryGraphLayout` only degrades with too many nodes; it won't
/// refuse to draw because of one extra swimlane).
private struct MemoryGraphSection: View {
    let library: MemoryLibrary
    @ObservedObject var service: SkillMemoryService
    let onOpenMemory: (MemoryEntry) -> Void

    @State private var selected: MemoryGraph.NodeID?

    var body: some View {
        let graph = service.graph(for: library)
        VStack(alignment: .leading, spacing: 10) {
            if graph.entryCount == 0 {
                // A library with only a MEMORY.md (Qwen creates an empty index first): the canvas
                // would be empty; say so instead of leaving a blank frame
                EmptyStateView(
                    icon: "books.vertical",
                    title: L10n.text("This memory library is still only an index", zhHans: "这个记忆库还只有索引"),
                    hint: L10n.format(
                        "%@'s memory/ directory only has MEMORY.md — no memory entries yet",
                        zhHans: "%@ 的 memory/ 目录里只有 MEMORY.md，还没有记忆条目",
                        library.projectName))
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
                // Goes through the service cache: this is inside body, and without caching 126
                // nodes would be re-laid out every frame
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

    /// Legend + **say what was left out**: unresolved `[[links]]` and deleted origin sessions are
    /// counted explicitly, so nobody assumes the graph shows everything.
    @ViewBuilder
    private func legend(_ graph: MemoryGraph.Graph) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                legendItem(L10n.text("References", zhHans: "引用"), color: Theme.brand.opacity(0.55), dashed: false)
                legendItem(L10n.text("Included", zhHans: "收录"), color: Theme.brand.opacity(0.28), dashed: true)
                legendItem(L10n.text("Source sessions", zhHans: "来源会话"), color: Theme.gold.opacity(0.7), dashed: true)
                Spacer(minLength: 0)
                Text(L10n.format("%1$@ memories · %2$@ sessions", zhHans: "%1$@ 条记忆 · %2$@ 个会话", String(graph.entryCount), String(graph.sessionCount)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if graph.unresolvedLinkCount > 0 || graph.missingSessionCount > 0 {
                HStack(spacing: 10) {
                    if graph.unresolvedLinkCount > 0 {
                        Text(L10n.format("%@ [[links]] have no target and were not drawn", zhHans: "%@ 条 [[链接]] 找不到目标，未画边", String(graph.unresolvedLinkCount)))
                    }
                    if graph.missingSessionCount > 0 {
                        Text(L10n.format("%@ memories have a deleted source session (gray dashed line, not clickable)", zhHans: "%@ 条记忆的来源会话已删除（灰色虚线，点不开）", String(graph.missingSessionCount)))
                    }
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func legendItem(_ label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            // Must stroke a real line segment: `Capsule().strokeBorder` in a 1.4pt-tall frame
            // degenerates to invisible (the stroke is thicker than the shape), leaving the legend
            // with text only
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
                title: L10n.text("This library is too big to graph", zhHans: "这个库太大，图谱不画了"),
                hint: L10n.format(
                    "%1$@ nodes is over the limit of %2$@; narrow it with the type filter above, or use the list",
                    zhHans: "%1$@ 个节点超过上限 %2$@；用上面的类型筛选缩小范围，或看列表",
                    String(count), String(limit)))
        }
    }
}
