import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaUsage
import Foundation

/// Agent 配置管理：Claude agent 定义文件（`~/.claude/agents/*.md` + 项目级）
/// 与 Codex profiles（`~/.codex/config.toml` 的 `[profiles.*]`）。双源特点不同：
/// Claude 是逐文件的 markdown（frontmatter + 正文），Codex 是 TOML 段（键值预设）。
final class AgentConfigService: ObservableObject {
    @Published private(set) var claudeAgents: [AgentDefinition] = []
    @Published private(set) var opencodeAgents: [AgentDefinition] = []
    @Published private(set) var grokAgents: [AgentDefinition] = []
    /// 已安装插件提供的 agent（`~/.claude/plugins`），按 pluginName 分组展示
    @Published private(set) var pluginAgents: [AgentDefinition] = []
    /// Claude Code 内置 agent（静态清单，只读）
    @Published private(set) var builtinAgents: [AgentDefinition] = []
    /// Kimi Code 内置 subagent profile（编译内嵌，只读；磁盘无用户自定义约定）
    @Published private(set) var kimiBuiltinAgents: [AgentDefinition] = []
    @Published private(set) var codexProfiles: [CodexProfile] = []
    @Published private(set) var scanning = false
    @Published private(set) var lastError: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.agents", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allAgents: [AgentDefinition] = []
    private var allOpencodeAgents: [AgentDefinition] = []
    private var allGrokAgents: [AgentDefinition] = []
    private var allPluginAgents: [AgentDefinition] = []
    private var allBuiltinAgents: [AgentDefinition] = []
    private var allKimiBuiltinAgents: [AgentDefinition] = []
    private var allProfiles: [CodexProfile] = []

    private var codexConfigURL: URL { EurekaCLI.codexConfigURL }

    // MARK: - 扫描

    func refresh() {
        guard !scanning else { return }
        scanning = true
        queue.async { [weak self] in
            guard let self else { return }
            // 项目级 agent 根：各项目仓库根下的 .claude/agents 与 .opencode/agents
            var claudeProjectRoots: [ProjectScopedRoot] = []
            var opencodeProjectRoots: [ProjectScopedRoot] = []
            var grokProjectRoots: [ProjectScopedRoot] = []
            for (root, name) in ProjectScopeDiscovery.repoRoots(resolver: self.resolver) {
                claudeProjectRoots.append(ProjectScopedRoot(
                    root: root.appendingPathComponent(".claude/agents", isDirectory: true),
                    source: .claude, projectName: name))
                opencodeProjectRoots.append(ProjectScopedRoot(
                    root: root.appendingPathComponent(".opencode/agents", isDirectory: true),
                    source: .opencode, projectName: name))
                grokProjectRoots.append(ProjectScopedRoot(
                    root: root.appendingPathComponent(".grok/agents", isDirectory: true),
                    source: .grok, projectName: name))
            }
            let agents = AgentDefinitionIndexer.indexClaudeAgents(
                systemRoot: AgentDefinitionIndexer.claudeAgentsRoot(),
                projectRoots: claudeProjectRoots)
            let opencodeAgents = AgentDefinitionIndexer.indexOpencodeAgents(
                systemRoots: OpencodePaths.agentsRoots(),
                projectRoots: opencodeProjectRoots)
            let grokAgents = AgentDefinitionIndexer.indexGrokAgents(
                systemRoots: GrokPaths.agentsRoots(),
                projectRoots: grokProjectRoots)
            let pluginAgents = AgentDefinitionIndexer.indexPluginAgents(
                pluginsRoot: AgentDefinitionIndexer.claudePluginsRoot())
            let builtinAgents = AgentDefinitionIndexer.builtinClaudeAgents()
            let kimiBuiltins = AgentDefinitionIndexer.builtinKimiAgents()
            let profiles = CodexProfileEditor.read(from: ConfigFile.read(self.codexConfigURL))
            DispatchQueue.main.async {
                self.allAgents = agents
                self.allOpencodeAgents = opencodeAgents
                self.allGrokAgents = grokAgents
                self.allPluginAgents = pluginAgents
                self.allBuiltinAgents = builtinAgents
                self.allKimiBuiltinAgents = kimiBuiltins
                self.allProfiles = profiles
                self.scanning = false
                self.rebuild()
            }
        }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else {
            claudeAgents = allAgents
            opencodeAgents = allOpencodeAgents
            grokAgents = allGrokAgents
            pluginAgents = allPluginAgents
            builtinAgents = allBuiltinAgents
            kimiBuiltinAgents = allKimiBuiltinAgents
            codexProfiles = allProfiles
            return
        }
        func matchAgent(_ agent: AgentDefinition) -> Bool {
            [agent.name, agent.description, agent.path, agent.pluginName,
             agent.tools.joined(separator: " ")]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
        claudeAgents = allAgents.filter(matchAgent)
        opencodeAgents = allOpencodeAgents.filter(matchAgent)
        grokAgents = allGrokAgents.filter(matchAgent)
        pluginAgents = allPluginAgents.filter(matchAgent)
        builtinAgents = allBuiltinAgents.filter(matchAgent)
        kimiBuiltinAgents = allKimiBuiltinAgents.filter(matchAgent)
        codexProfiles = allProfiles.filter {
            [$0.name, $0.model, $0.personality, $0.reasoningEffort]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Claude agent 读/写

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// 原子写入：写前留 .bak.eureka.<ts> 备份
    func save(path: String, content: String, completion: ((Bool) -> Void)? = nil) {
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

    /// 新建全局 Claude agent（`~/.claude/agents/<slug>.md`），带 frontmatter 模板
    func createClaudeAgent(name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let slug = Self.slugify(name)
            let root = AgentDefinitionIndexer.claudeAgentsRoot()
            let file = root.appendingPathComponent(slug + ".md")
            let template = """
            ---
            name: \(slug)
            description:
            tools:
            model:
            ---

            """
            var ok = false
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// 新建全局 opencode agent（`~/.config/opencode/agents/<slug>.md`），带 opencode frontmatter 模板
    func createOpencodeAgent(name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let slug = Self.slugify(name)
            let root = OpencodePaths.agentsRoots().first
                ?? OpencodePaths.configHome().appendingPathComponent("agents", isDirectory: true)
            let file = root.appendingPathComponent(slug + ".md")
            let template = """
            ---
            description:
            mode: subagent
            model:
            ---

            """
            var ok = false
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// 新建全局 grok agent（`~/.grok/agents/<slug>.md`），带 grok frontmatter 模板
    func createGrokAgent(name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let slug = Self.slugify(name)
            let root = GrokPaths.agentsRoots().first
                ?? GrokPaths.configHome().appendingPathComponent("agents", isDirectory: true)
            let file = root.appendingPathComponent(slug + ".md")
            let template = """
            ---
            name: \(slug)
            description:
            model: inherit
            ---

            """
            var ok = false
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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

    /// 删除 agent 文件 → 废纸篓
    func deleteAgent(_ agent: AgentDefinition, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            do {
                try FileManager.default.trashItem(
                    at: URL(fileURLWithPath: agent.path), resultingItemURL: nil)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
        }
    }

    /// 启用/停用 agent：在启用区 ↔ <root>.eureka-disabled 间移动 .md 文件（可逆、非破坏）
    func setAgentEnabled(_ agent: AgentDefinition, _ enabled: Bool, completion: ((Bool) -> Void)? = nil) {
        guard agent.enabled != enabled else { completion?(true); return }
        queue.async { [weak self] in
            let fileURL = URL(fileURLWithPath: agent.path)
            let currentRoot = fileURL.deletingLastPathComponent()
            let activeRoot = agent.enabled
                ? currentRoot
                : SkillMemoryService.activeRoot(fromDisabled: currentRoot)
            let destRoot = enabled ? activeRoot : AgentDefinitionIndexer.disabledRoot(for: activeRoot)
            let dest = destRoot.appendingPathComponent(fileURL.lastPathComponent)
            var ok = false
            do {
                try FileManager.default.createDirectory(
                    at: destRoot, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: fileURL, to: dest)
                ok = true
            } catch {
                self?.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh() }
        }
    }

    // MARK: - Codex profile 读/写（config.toml 段编辑，经 ConfigFile 备份+原子写）

    func saveProfile(_ profile: CodexProfile, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var ok = false
            do {
                let toml = ConfigFile.read(self.codexConfigURL)
                let updated = CodexProfileEditor.upsert(into: toml, profile: profile)
                try ConfigFile.backupThenWrite(path: self.codexConfigURL, newContent: updated)
                ok = true
            } catch {
                self.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self.refresh() }
        }
    }

    func deleteProfile(name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            var ok = false
            do {
                let toml = ConfigFile.read(self.codexConfigURL)
                let updated = CodexProfileEditor.remove(from: toml, name: name)
                try ConfigFile.backupThenWrite(path: self.codexConfigURL, newContent: updated)
                ok = true
            } catch {
                self.report(error)
            }
            DispatchQueue.main.async { completion?(ok); self.refresh() }
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

    static func slugify(_ name: String) -> String { SkillMemoryService.slugify(name) }
    static func timestamp() -> Int { SkillMemoryService.timestamp() }
}
