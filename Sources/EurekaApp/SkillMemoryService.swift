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
    @Published private(set) var memories: [MemoryEntry] = []
    @Published private(set) var scanning = false
    /// 扫描中的阶段文案（列表已有数据时，仅靠搜索框那个小 spinner 看不出在扫）；扫完置 nil
    @Published private(set) var scanPhase: String?
    /// 上次扫完的时间。nil = 从未扫过（refresh 的判据）；UI 用它显示「上次扫描 X 前」
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.skillmemory", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allSkills: [SkillEntry] = []
    private var allMemories: [MemoryEntry] = []

    // MARK: - 扫描

    /// force = false：只在「从未扫过」时扫 —— 启动预热与页面 onAppear 都走这条，天然幂等，
    /// 所以进页面不会再盲扫一遍（数据靠启动预热已就绪）。
    /// force = true：无条件全量重扫，仅刷新按钮使用。
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
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
            let skills = SkillMemoryIndexer.indexSkills(
                claudeSkillsRoot: SkillMemoryIndexer.claudeSkillsRoot(),
                codexSkillsRoot: SkillMemoryIndexer.codexSkillsRoot(),
                opencodeSkillsRoot: OpencodePaths.skillsRoot(),
                grokSkillsRoot: GrokPaths.skillsRoot(),
                kimiSkillsRoot: KimiPaths.skillsRoot(),
                geminiSkillsRoot: GeminiPaths.skillsRoot(),
                qwenSkillsRoot: QwenPaths.skillsRoot(),
                antigravitySkillsRoots: [],
                hermesSkillsRoot: HermesPaths.skillsRoot(),
                // Hermes 的启停名单在 config.yaml 里（不是目录位置）；EurekaIngest 不依赖
                // EurekaInstall，故在 app 层读出来传进去
                hermesDisabledSkills: HermesConfigEditor.disabledSkills(
                    from: ConfigFile.read(HermesPaths.configFile())),
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
                projectRoots: repoRoots,
                codexInstructionScopes: codexInstructionScopes)
            DispatchQueue.main.async {
                self.allSkills = skills
                self.allMemories = memories
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
        // 记忆页展示：全局记忆（任意类型）+ 各项目根的指令文件（CLAUDE.md/AGENTS.md/GEMINI.md…）。
        // 排除 ~/.claude/projects/<enc>/memory/*.md 之类的会话级自建记忆（数量庞大、非管理对象）。
        let visibleMemories = allMemories.filter { $0.projectName == nil || $0.kind == .instructions }
        guard !query.isEmpty else {
            skills = userSkills
            memories = visibleMemories
            return
        }
        skills = userSkills.filter {
            [$0.name, $0.description, $0.path]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
        memories = visibleMemories.filter {
            "\($0.scope) \($0.path) \($0.projectName ?? "")".lowercased().contains(query)
        }
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
            case .codebuddy, .qoder:
                // 这两个 CLI 没有用户级 skills 目录（UI 不提供新建技能入口）；仅为穷举
                DispatchQueue.main.async { completion?(false) }
                return
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
                // antigravity 无记忆概念（UI 不提供入口）；仅为穷举，写 ~/.gemini/memories
                dir = AntigravityPaths.geminiHome()
                    .appendingPathComponent("memories", isDirectory: true)
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
