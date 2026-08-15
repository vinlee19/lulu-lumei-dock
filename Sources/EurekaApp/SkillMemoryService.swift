import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaUsage
import Foundation

/// 技能 & 记忆的浏览与完整管理：覆盖全部 agent 源（含项目级目录，发现口径见
/// ProjectRoots.recentCwds / SkillMemoryIndexer.projectSkillRoots）。
/// 自带后台扫描队列；编辑写前备份、删除进废纸篓、停用 = 移到 *.eureka-disabled 同级目录（均可逆）。
final class SkillMemoryService: ObservableObject {
    @Published private(set) var skills: [SkillEntry] = []
    /// 记忆列表里的**独立记忆条目**（各 CLI 的全局记忆目录）。两类东西不在这里：
    /// 项目记忆库的条目折叠进 `libraries`（一个项目 70+ 条会把全局记忆冲掉）；
    /// CLAUDE.md / AGENTS.md 这类**用户维护的持久指令**归 `instructions`，它们不是记忆。
    @Published private(set) var memories: [MemoryEntry] = []
    /// 持久指令文件：CLAUDE.md / AGENTS.md / GEMINI.md / QWEN.md / `.cursor/rules` / Hermes SOUL。
    /// 独立成「指令」页签 —— 它们是用户写给 agent 的规则，不是 agent 攒下来的记忆，
    /// 混在一起统计会让「记忆有多少」这个数字失去意义。
    @Published private(set) var instructions: [MemoryEntry] = []
    /// 记忆库（Claude / Qwen 的 `projects/<encoded>/memory`）；搜索时为空（改为扁平展开命中条目）
    @Published private(set) var libraries: [MemoryLibrary] = []
    /// **统计唯一口径**：独立条目 + 全部库内文件（搜索时 = 命中集）。
    /// 统计卡、来源 chips、搜索结果数都读它 —— 以前它们读的是被过滤后的列表数组，
    /// 于是 97 条项目记忆一条都没算进去。
    @Published private(set) var memoryEntries: [MemoryEntry] = []
    @Published private(set) var scanning = false
    /// 扫描中的阶段文案（列表已有数据时，仅靠搜索框那个小 spinner 看不出在扫）；扫完置 nil
    @Published private(set) var scanPhase: String?
    /// 上次扫完的时间。nil = 从未扫过（refresh 的判据）；UI 用它显示「上次扫描 X 前」
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    /// 跨页直达：待聚焦条目的文件路径（PopoverRootView 写入，对应页签消费后清空）
    @Published var focusPath: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.skillmemory", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allSkills: [SkillEntry] = []
    private var allMemories: [MemoryEntry] = []
    private var allLibraries: [MemoryLibrary] = []
    /// 本轮扫描发现的全部仓库根。一致性检查要靠它发现「**完全没有**指令文件」的仓库 ——
    /// 那种仓库压根不会出现在 allMemories 里（实勘 starrocks 就是这样）。
    private var allRepoRoots: [(root: URL, name: String)] = []
    /// 记忆库 → 关系图。构图是纯函数但不便宜（semantic-layer 126 节点），
    /// 而 SwiftUI 的 body 会反复求值 → 按库缓存，每次重扫清空。
    private var graphCache: [String: MemoryGraph.Graph] = [:]
    /// `"<库 key>|<画布宽度>"` → 排版结果（见 layout(for:width:)）
    private var layoutCache: [String: MemoryGraphLayout.Result] = [:]

    // MARK: - 扫描

    /// force = false：只在「从未扫过」时扫 —— 启动预热与页面 onAppear 都走这条，天然幂等，
    /// 所以进页面不会再盲扫一遍（数据靠启动预热已就绪）。
    /// force = true：无条件全量重扫，仅刷新按钮使用。
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        // 用户点刷新就是要最新的：丢掉 cwd 发现缓存，否则 60s 内拿到的还是上次那份
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        scanPhase = "正在扫描技能与记忆…"
        queue.async { [weak self] in
            guard let self else { return }
            // 各项目仓库根（技能与记忆共用同一份发现）
            let repoRoots = ProjectScopeDiscovery.repoRoots(resolver: self.resolver)
            let codexInstructionScopes = ProjectScopeDiscovery.codexInstructionScopes(
                resolver: self.resolver)
            // 项目级技能根：与云备份共用同一发现口径（见 SkillMemoryIndexer.projectSkillRoots）
            let projectRoots = SkillMemoryIndexer.projectSkillRoots(repoRoots: repoRoots)
            // 内置/携带技能根（只读，供详情矩阵与跨源判定；不进列表）
            var bundledRoots: [(root: URL, source: AgentSource)] = []
            for root in SkillMemoryIndexer.claudePluginSkillsRoots() {
                bundledRoots.append((root, .claude))
            }
            bundledRoots.append((
                SkillMemoryIndexer.codexSkillsRoot()
                    .appendingPathComponent(".system", isDirectory: true), .codex))
            bundledRoots.append((GrokPaths.bundledSkillsRoot(), .grok))
            // antigravity：skillsRoots 首根为用户级，其余为内置 builtin
            for root in AntigravityPaths.skillsRoots().dropFirst() {
                bundledRoots.append((root, .antigravity))
            }
            // cursor 内置技能 ~/.cursor/skills-cursor（官方分发、随客户端更新，
            // 它自己的 create-skill 技能明写「绝不要往这里写」→ 只读，走 bundled）
            bundledRoots.append((CursorPaths.bundledSkillsRoot(), .cursor))
            // trae 内置技能有**两处**且内容不同：`builtin_skills`（TRAE-code-review…）与
            // `builtin/global/skills`（TRAE-computer-use…）。只扫一处会漏一半。
            for root in TraePaths.bundledSkillsRoots() {
                bundledRoots.append((root, .trae))
            }
            let skills = SkillMemoryIndexer.indexSkills(
                claudeSkillsRoot: SkillMemoryIndexer.claudeSkillsRoot(),
                codexSkillsRoot: SkillMemoryIndexer.codexSkillsRoot(),
                // Codex 把技能也塞进了 memories git 仓库；不在这里收，记忆页就会多出一条假记忆
                codexMemorySkillsRoot: SkillMemoryIndexer.codexHome()
                    .appendingPathComponent("memories/skills", isDirectory: true),
                opencodeSkillsRoot: OpencodePaths.skillsRoot(),
                grokSkillsRoot: GrokPaths.skillsRoot(),
                kimiSkillsRoot: KimiPaths.skillsRoot(),
                geminiSkillsRoot: GeminiPaths.skillsRoot(),
                qwenSkillsRoot: QwenPaths.skillsRoot(),
                // 用户级 ~/.gemini/antigravity/skills；内置 builtin 走 bundledRoots
                antigravitySkillsRoots: [AntigravityPaths.userSkillsRoot()],
                hermesSkillsRoot: HermesPaths.skillsRoot(),
                // Hermes 的启停名单在 config.yaml 里（不是目录位置）；EurekaIngest 不依赖
                // EurekaInstall，故在 app 层读出来传进去
                hermesDisabledSkills: HermesConfigEditor.disabledSkills(
                    from: ConfigFile.read(HermesPaths.configFile())),
                cursorSkillsRoot: CursorPaths.skillsRoot(),
                codeBuddySkillsRoot: CodeBuddyPaths.skillsRoot(),
                qoderSkillsRoot: QoderPaths.skillsRoot(),
                // zcode 技能装在共享的 ~/.agents/skills（与桌面版共用）
                zcodeSkillsRoot: ZcodePaths.skillsRoot(),
                // CN 与国际版可能同时装着 → 已装渠道各一个可写根
                traeSkillsRoots: TraePaths.userSkillsRoots(),
                projectSkillRoots: projectRoots,
                bundledRoots: bundledRoots)
            let memories = SkillMemoryIndexer.indexMemory(
                claudeHome: SkillMemoryIndexer.claudeHome(),
                codexHome: SkillMemoryIndexer.codexHome(),
                opencodeHome: OpencodePaths.configHome(),
                claudeProjectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
                grokMemoryRoot: GrokPaths.memoryRoot(),
                kimiHome: KimiPaths.configHome(),
                geminiHome: GeminiPaths.configHome(),
                qwenHome: QwenPaths.configHome(),
                hermesHome: HermesPaths.configHome(),
                codeBuddyMemoryRoot: CodeBuddyPaths.memoryRoot(),
                qoderMemoriesRoot: QoderPaths.memoriesRoot(),
                // 记忆库只有 CN 版有；用户手写规则两个渠道都有
                traeMemoryRoot: TraePaths.memoryRoot(),
                traeRulesHomes: TraePaths.installedChannels().map { TraePaths.configHome($0) },
                projectRoots: repoRoots,
                codexInstructionScopes: codexInstructionScopes)
            let libraries = MemoryLibrary.group(memories)
            DispatchQueue.main.async {
                self.allSkills = skills
                self.allMemories = memories
                self.allLibraries = libraries
                self.allRepoRoots = repoRoots
                self.graphCache.removeAll()
                self.layoutCache.removeAll()
                self.scanning = false
                self.scanPhase = nil
                self.lastScanAt = Date()
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        // 列表只展示用户自建/安装技能；内置(bundled) 仅供详情矩阵与跨源判定
        let userSkills = allSkills.filter { $0.origin == .user }
        // 记忆分三路（**不丢弃任何条目**）：
        //  1. 指令文件 → instructions（独立页签）
        //  2. 不属于记忆库的独立记忆 → memories
        //  3. 库内条目 → 折叠成 libraries 一行一库，但照样计入统计口径 memoryEntries
        let standalone = allMemories.filter { $0.libraryKey == nil }
        let standaloneMemories = standalone.filter { $0.kind != .instructions }
        let instructionFiles = standalone.filter { $0.kind == .instructions }
        let libraryFiles = allMemories.filter { $0.libraryKey != nil }
        guard !query.isEmpty else {
            skills = userSkills
            memories = standaloneMemories
            instructions = instructionFiles
            libraries = allLibraries
            memoryEntries = standaloneMemories + libraryFiles
            return
        }
        skills = userSkills.filter {
            [$0.name, $0.description, $0.path]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
        // 搜索时**库要展开**：命中的库内条目扁平并入结果，否则用户搜一条记忆会什么都搜不到
        let matched = (standaloneMemories + libraryFiles).filter { Self.matches($0, query: query) }
        memories = matched
        instructions = instructionFiles.filter { Self.matches($0, query: query) }
        libraries = []
        memoryEntries = matched
    }

    private static func matches(_ entry: MemoryEntry, query: String) -> Bool {
        [entry.title, entry.scope, entry.path, entry.summary ?? "", entry.projectName ?? ""]
            .joined(separator: " ").lowercased().contains(query)
    }

    // MARK: - 跨源配置矩阵 / 名称归一

    /// 某技能名在各来源的配置情况（详情页 logo 矩阵）：来源 → .user/.bundled（缺=未配置）。
    /// best-effort：按归一化名（去 `plugin:` 前缀、小写）匹配 name 或目录名；同源 user 优先于 bundled。
    func configurations(forName name: String) -> [AgentSource: SkillOrigin] {
        let key = Self.normalizeSkillName(name)
        var result: [AgentSource: SkillOrigin] = [:]
        for entry in allSkills {
            let dirName = URL(fileURLWithPath: entry.directory).lastPathComponent
            guard Self.normalizeSkillName(entry.name) == key
                || Self.normalizeSkillName(dirName) == key else { continue }
            if result[entry.source] == .user { continue }
            result[entry.source] = entry.origin
        }
        return result
    }

    /// 归一化技能名用于跨源/统计匹配（委托 SkillMemoryIndexer，纯函数便于单测）
    static func normalizeSkillName(_ name: String) -> String {
        SkillMemoryIndexer.normalizeSkillName(name)
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    func skills(for source: AgentSource) -> [SkillEntry] { skills.filter { $0.source == source } }
    func memories(for source: AgentSource) -> [MemoryEntry] { memories.filter { $0.source == source } }

    // MARK: - 记忆统计（唯一口径：memoryEntries，含库内条目）

    /// 记忆总数（独立条目 + 库内文件；搜索时 = 命中数）
    var memoryTotal: Int { memoryEntries.count }

    func memoryCount(for source: AgentSource) -> Int {
        memoryEntries.filter { $0.source == source }.count
    }

    var memoryTotalBytes: UInt64 {
        memoryEntries.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    /// 记忆的范围分布：全局记忆 / 项目记忆库（指令文件已不在记忆口径里）
    var memoryScopeBreakdown: (global: Int, library: Int) {
        var global = 0
        var library = 0
        for entry in memoryEntries {
            if entry.libraryKey != nil { library += 1 } else { global += 1 }
        }
        return (global, library)
    }

    var memorySourceCount: Int { Set(memoryEntries.map(\.source)).count }

    // MARK: - 指令统计（与记忆完全分开的一套）

    var instructionTotal: Int { instructions.count }

    func instructionCount(for source: AgentSource) -> Int {
        instructions.filter { $0.source == source }.count
    }

    var instructionTotalBytes: UInt64 {
        instructions.reduce(UInt64(0)) { $0 + $1.sizeBytes }
    }

    /// 指令的范围分布：全局（`~/.claude/CLAUDE.md` 之类）/ 项目根
    var instructionScopeBreakdown: (global: Int, project: Int) {
        let project = instructions.filter { $0.projectName != nil }.count
        return (instructions.count - project, project)
    }

    var instructionSourceCount: Int { Set(instructions.map(\.source)).count }

    func instructions(for source: AgentSource) -> [MemoryEntry] {
        instructions.filter { $0.source == source }
    }

    func libraries(for source: AgentSource?) -> [MemoryLibrary] {
        guard let source else { return libraries }
        return libraries.filter { $0.source == source }
    }

    /// 某条记忆所属的记忆库（详情页的关联小图要拿整库的图再取一跳）
    func library(containing entry: MemoryEntry) -> MemoryLibrary? {
        guard let key = entry.libraryKey else { return nil }
        return allLibraries.first { $0.key == key }
    }

    // MARK: - 跨源配置一致性

    /// 计算在 `ConsistencyChecker`（EurekaIngest 的纯函数，阈值口径由单测钉住）。
    /// 这里只负责把手上的四份数据递进去。
    var consistencyReport: ConsistencyChecker.Report {
        ConsistencyChecker.report(
            skills: allSkills, memories: allMemories, libraries: allLibraries,
            repoNames: allRepoRoots.map(\.name))
    }

    /// 记忆库的关系图（按库缓存；重扫时清空）
    func graph(for library: MemoryLibrary) -> MemoryGraph.Graph {
        if let cached = graphCache[library.key] { return cached }
        let graph = MemoryGraphBuilder.build(library.graphInput())
        graphCache[library.key] = graph
        return graph
    }

    /// 记忆库图谱的**排版结果**（按库 + 画布宽度缓存）。
    /// 排版是纯函数但不便宜（semantic-layer 126 节点 / 53 行），而它跑在 `GeometryReader`
    /// 的 body 里 —— 不缓存就是每帧重排。宽度量化到整数点，避免浮点抖动让缓存永不命中。
    func layout(for library: MemoryLibrary, width: CGFloat) -> MemoryGraphLayout.Result {
        let key = "\(library.key)|\(Int(width.rounded()))"
        if let cached = layoutCache[key] { return cached }
        let result = MemoryGraphLayout.layout(
            graph(for: library), metrics: .standard(width: width))
        layoutCache[key] = result
        return result
    }

    // MARK: - 读

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: - 写（队列上执行，完成回主线程刷新）

    /// 原子写入：写前留 .bak.eureka.<ts> 备份
    func save(path: String, content: String, completion: ((Bool) -> Void)? = nil) {
        guard !Self.isCodexGeneratedMemory(path) else {
            completion?(false)
            return
        }
        queue.async { [weak self] in
            var ok = false
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: path) {
                    let backup = path + ".bak.eureka.\(Self.timestamp())"
                    try? fm.removeItem(atPath: backup)
                    try? fm.copyItem(atPath: path, toPath: backup)
                }
                try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    func createSkill(source: AgentSource, name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let root: URL
            switch source {
            case .claude: root = SkillMemoryIndexer.claudeSkillsRoot()
            case .codex: root = SkillMemoryIndexer.codexSkillsRoot()
            case .opencode: root = OpencodePaths.skillsRoot()
            case .grok: root = GrokPaths.skillsRoot()
            case .antigravity: root = AntigravityPaths.userSkillsRoot()
            case .kimi: root = KimiPaths.skillsRoot()
            case .gemini: root = GeminiPaths.skillsRoot()
            case .qwen: root = QwenPaths.skillsRoot()
            case .hermes: root = HermesPaths.skillsRoot()
            case .cursor: root = CursorPaths.skillsRoot()
            case .codebuddy: root = CodeBuddyPaths.skillsRoot()
            case .qoder: root = QoderPaths.skillsRoot()
            case .trae:
                // 两个渠道都可能装：优先写已装的第一个（CN 在前）；都没装就按 CN 建。
                // `builtin_skills` / `builtin/global/skills` 随客户端分发，只读，不能往里建。
                root = TraePaths.userSkillsRoots().first ?? TraePaths.skillsRoot(.cn)
            case .zcode:
                root = ZcodePaths.skillsRoot()
            }
            let slug = Self.slugify(name)
            let dir = root.appendingPathComponent(slug, isDirectory: true)
            let file = dir.appendingPathComponent("SKILL.md")
            let template = "---\nname: \(slug)\ndescription: \n---\n\n"
            var ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try template.write(to: file, atomically: true, encoding: .utf8)
                }
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    func createMemory(source: AgentSource, name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let dir: URL
            switch source {
            case .claude:
                dir = SkillMemoryIndexer.claudeHome()
                    .appendingPathComponent("memories", isDirectory: true)
            case .codex:
                // Codex memories/ 是后台生成状态；用户持久指令写 AGENTS.md。
                let home = SkillMemoryIndexer.codexHome()
                let file = home.appendingPathComponent("AGENTS.md")
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: home, withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# AGENTS.md\n\n".write(
                            to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .opencode:
                dir = OpencodePaths.configHome()
                    .appendingPathComponent("memories", isDirectory: true)
            case .grok:
                dir = GrokPaths.memoryRoot()  // grok 用 ~/.grok/memory（无 memories 子目录）
            case .antigravity:
                // antigravity 没有自己的记忆目录（~/.gemini/antigravity/ 下只有 skills）。
                // 以前这里写 ~/.gemini/memories —— 那是 Gemini 的，建完会被索引成 gemini
                // 来源。宁可不提供入口，也不借用别人的目录。
                DispatchQueue.main.async { completion?(false) }
                return
            case .kimi:
                // kimi 记忆 = 单一全局 AGENTS.md（AGENTS.md-first，无 memories 目录概念）：
                // 直接创建 ~/.kimi-code/AGENTS.md（name 参数忽略），已存在则不覆盖
                let file = KimiPaths.globalAgentsMd()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# AGENTS.md\n\n".write(to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .qwen:
                dir = QwenPaths.memoriesRoot()
            case .cursor:
                // Cursor 没有**全局**记忆目录：服务端记忆只有开关落在本地
                // （`cursor/memoriesEnabled`），本地那份等价物是项目级规则
                // `<repo>/.cursor/rules/*.mdc`——它归属某个仓库，不该由这个
                // 「新建全局记忆」入口凭空造。索引照常收（见 SkillMemoryIndexer）。
                DispatchQueue.main.async { completion?(false) }
                return
            case .codebuddy:
                dir = CodeBuddyPaths.memoryRoot()  // ~/.codebuddy/memery（官方拼写）
            case .qoder:
                // qoder 记忆布局 memories/<user-hash>/global/<category>/；
                // 新建落到首个 <user-hash>/global/（一个都没有就 memories/global/）
                let root = QoderPaths.memoriesRoot()
                let subdirs = ((try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                    .filter {
                        (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    }
                dir = (subdirs.first ?? root)
                    .appendingPathComponent("global", isDirectory: true)
            case .hermes:
                // hermes 记忆 = 固定两份全局文件（memories/MEMORY.md 与 USER.md），name 参数忽略。
                // 正文是「条目以 \n§\n 相连」的扁平格式且有字数上限，外部写坏会触发 Hermes 的
                // 漂移保护（存 .bak 并拒绝后续写入）→ 这里建**空文件**，让 Hermes 自己写第一条。
                let file = HermesPaths.memoriesRoot().appendingPathComponent("MEMORY.md")
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try Data().write(to: file, options: .atomic)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .gemini:
                // gemini 记忆 = 全局 GEMINI.md（GEMINI.md-first，无 memories 目录概念）：
                // 直接创建 ~/.gemini/GEMINI.md（name 参数忽略），已存在则不覆盖
                let file = GeminiPaths.globalGeminiMd()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try "# GEMINI.md\n\n".write(to: file, atomically: true, encoding: .utf8)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .trae:
                // trae 有两份固定名字的全局文件，靠 name 选（同 codex/kimi/gemini 的做法：
                // 菜单传一个固定名字进来，不是用户输入的标题）：
                //   `user_rules` → `<dataFolder>/user_rules.md`（用户手写规则 → 指令页）
                //   其它        → `~/.trae-cn/memory/user_profile.md`（Trae 自写画像 → 记忆页）
                // 项目记忆 `memory/projects/<encoded>/project_memory.md` 归属某个仓库，
                // 不该由这个「新建全局」入口凭空造。
                // 一律建**空文件**（同 Hermes 的规矩）：两份都是分节扁平文档，塞一个假标题
                // 进去会污染 Trae 自己的分节解析。记忆库只有 CN 版有，所以画像固定落 CN；
                // 规则落已装渠道的第一个。
                let file = Self.slugify(name) == "user-rules" || name == "user_rules"
                    ? (TraePaths.installedChannels().first.map { TraePaths.userRulesFile($0) }
                        ?? TraePaths.userRulesFile(.cn))
                    : TraePaths.userProfileFile()
                var ok = false
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if !FileManager.default.fileExists(atPath: file.path) {
                        try Data().write(to: file, options: .atomic)
                    }
                    ok = true
                } catch {
                    self?.report(error)
                }
                DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
                return
            case .zcode:
                // zcode 未观测到全局记忆文件布局（~/.zcode 无 AGENTS.md 类文件）——
                // 不提供入口（同 antigravity 的规矩：宁可不建，也不造一个 CLI 不认的文件）
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let file = dir.appendingPathComponent(Self.slugify(name) + ".md")
            var ok = false
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: file.path) {
                    try "# \(name)\n\n".write(to: file, atomically: true, encoding: .utf8)
                }
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// 删除技能（整个目录）→ 废纸篓
    func deleteSkill(_ skill: SkillEntry, completion: ((Bool) -> Void)? = nil) {
        trash(path: skill.directory, completion: completion)
    }

    /// 删除记忆文件 → 废纸篓
    func deleteMemory(_ memory: MemoryEntry, completion: ((Bool) -> Void)? = nil) {
        guard memory.isDeletable else { completion?(false); return }
        trash(path: memory.path, completion: completion)
    }

    private func trash(path: String, completion: ((Bool) -> Void)?) {
        queue.async { [weak self] in
            var ok = false
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: path), resultingItemURL: nil)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// 启用/停用技能：在启用区 ↔ <root>.eureka-disabled 之间移动整个目录（可逆、非破坏）。
    /// 从技能自身目录推导所属 skills 根（父目录），因此系统级与项目级技能都适用。
    func setSkillEnabled(_ skill: SkillEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard skill.enabled != enabled else { completion?(true); return }
        // Hermes 的启停是 config.yaml 里的 skills.disabled 名单，**不能挪目录**：
        // 它用 .bundled_manifest 的 md5 + curator 状态记账内置技能，目录一动就被判成篡改/丢失。
        if skill.source == .hermes {
            setHermesSkillEnabled(skill, enabled, completion: completion)
            return
        }
        queue.async { [weak self] in
            let dirURL = URL(fileURLWithPath: skill.directory)
            // 当前所在根 = 技能目录的父目录；停用区推导出启用区，反之亦然
            let currentRoot = dirURL.deletingLastPathComponent()
            let activeRoot = skill.enabled
                ? currentRoot
                : SkillMemoryService.activeRoot(fromDisabled: currentRoot)
            let destRoot = enabled ? activeRoot : SkillMemoryIndexer.disabledRoot(for: activeRoot)
            let dest = destRoot.appendingPathComponent(dirURL.lastPathComponent, isDirectory: true)
            var ok = false
            do {
                try FileManager.default.createDirectory(
                    at: destRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: dirURL, to: dest)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Hermes 技能启停：往 `~/.hermes/config.yaml` 的 `skills.disabled` 增删 frontmatter name。
    /// 走 ConfigFile.backupThenWrite（写前留 *.bak.eureka.<ts>），与 Codex config.toml 同一套安全网。
    /// 编辑器是行级手术，注释与键序原样保留；无法安全改写的形态会原样返回 → 视作失败不落盘。
    private func setHermesSkillEnabled(
        _ skill: SkillEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            let configURL = HermesPaths.configFile()
            // config.yaml 不在就不写：ConfigFile.backupThenWrite 会连 ~/.hermes 一起 mkdir，
            // 凭空造出一份只有 skills.disabled 的配置，而 Hermes 会把它当"已配置"读。
            guard FileManager.default.fileExists(atPath: configURL.path) else {
                DispatchQueue.main.async {
                    self?.lastError = "未找到 \(configURL.path)，无法改写 Hermes 技能启停名单"
                    completion?(false)
                }
                return
            }
            let original = ConfigFile.read(configURL)
            let updated = HermesConfigEditor.setSkillDisabled(
                skill.name, disabled: !enabled, in: original)
            var ok = false
            if updated == original {
                // 名单已是目标状态，或该 config 形态无法行级改写 —— 两种情况都不写盘
                ok = HermesConfigEditor.disabledSkills(from: original).contains(skill.name) != enabled
            } else {
                do {
                    try ConfigFile.backupThenWrite(path: configURL, newContent: updated)
                    ok = true
                } catch {
                    self?.report(error)
                }
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    // MARK: - 跨页联动（主线程；与 rebuild 同一约束）

    /// 知识面快照（全文索引用）：用户技能 + 全部记忆（含库内条目与指令）。搜索过滤前的全集。
    func knowledgeSnapshot() -> (skills: [SkillEntry], memories: [MemoryEntry]) {
        (allSkills.filter { $0.origin == .user }, allMemories)
    }

    /// 与某会话相关的记忆（originSessionId 或 relatedSessions 命中；会话详情「本会话产出」用）
    func memories(relatedTo sessionId: String) -> [MemoryEntry] {
        allMemories.filter { entry in
            entry.originSessionId == sessionId
                || entry.relatedSessions.contains { $0.sessionId == sessionId }
        }
    }

    // MARK: - 外部打开（主线程）

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - 工具

    private func report(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.lastError = message }
    }

    /// `~/.codex/memories` 由 Codex 后台维护，服务层也拒绝写入，避免绕过 UI 只读态。
    private static func isCodexGeneratedMemory(_ path: String) -> Bool {
        let root = SkillMemoryIndexer.codexHome()
            .appendingPathComponent("memories", isDirectory: true)
            .standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target.hasPrefix(root + "/")
    }

    /// 停用区根 `<x>.eureka-disabled` → 对应启用区根 `<x>`（反推）
    static func activeRoot(fromDisabled disabledRoot: URL) -> URL {
        let name = disabledRoot.lastPathComponent
        let suffix = ".eureka-disabled"
        guard name.hasSuffix(suffix) else { return disabledRoot }
        let activeName = String(name.dropLast(suffix.count))
        return disabledRoot.deletingLastPathComponent()
            .appendingPathComponent(activeName, isDirectory: true)
    }

    static func slugify(_ name: String) -> String {
        var slug = String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "untitled" : slug
    }

    static func timestamp() -> Int { Int(Date().timeIntervalSince1970) }
}
