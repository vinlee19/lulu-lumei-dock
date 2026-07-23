import AppKit
import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

/// 技能 & 记忆的浏览与完整管理：Claude + Codex 双源。
/// 自带后台扫描队列；编辑写前备份、删除进废纸篓、停用 = 移到 *.eureka-disabled 同级目录（均可逆）。
final class SkillMemoryService: ObservableObject {
    @Published private(set) var skills: [SkillEntry] = []
    @Published private(set) var memories: [MemoryEntry] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastError: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.skillmemory", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allSkills: [SkillEntry] = []
    private var allMemories: [MemoryEntry] = []

    // MARK: - 扫描

    func refresh() {
        guard !scanning else { return }
        scanning = true
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
                projectRoots: repoRoots,
                codexInstructionScopes: codexInstructionScopes)
            DispatchQueue.main.async {
                self.allSkills = skills
                self.allMemories = memories
                self.scanning = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        // 列表只展示用户自建/安装技能；内置(bundled) 仅供详情矩阵与跨源判定
        let userSkills = allSkills.filter { $0.origin == .user }
        // 记忆页只展示系统级记忆（全局 + 用户自建）；项目级记忆归属项目上下文，不进本页
        let systemMemories = allMemories.filter { $0.projectName == nil }
        guard !query.isEmpty else {
            skills = userSkills
            memories = systemMemories
            return
        }
        skills = userSkills.filter {
            [$0.name, $0.description, $0.path]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
        memories = systemMemories.filter {
            "\($0.scope) \($0.path)".lowercased().contains(query)
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
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
                DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
                DispatchQueue.main.async { completion?(ok); self?.refresh() }
                return
            case .qwen:
                dir = QwenPaths.memoriesRoot()
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
                DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
        }
    }

    /// 启用/停用技能：在启用区 ↔ <root>.eureka-disabled 之间移动整个目录（可逆、非破坏）。
    /// 从技能自身目录推导所属 skills 根（父目录），因此系统级与项目级技能都适用。
    func setSkillEnabled(_ skill: SkillEntry, _ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard skill.enabled != enabled else { completion?(true); return }
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
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
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
