import AppKit
import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaUsage
import Foundation

/// Agent config management: Claude agent definition files (`~/.claude/agents/*.md` + project level)
/// and Codex profiles (`[profiles.*]` in `~/.codex/config.toml`). The two sources differ:
/// Claude is per-file markdown (frontmatter + body), Codex is TOML tables (key-value presets).
final class AgentConfigService: ObservableObject {
    @Published private(set) var claudeAgents: [AgentDefinition] = []
    @Published private(set) var opencodeAgents: [AgentDefinition] = []
    @Published private(set) var grokAgents: [AgentDefinition] = []
    @Published private(set) var cursorAgents: [AgentDefinition] = []
    /// Agents provided by installed plugins (`~/.claude/plugins`), shown grouped by pluginName
    @Published private(set) var pluginAgents: [AgentDefinition] = []
    /// Claude Code built-in agents (static list, read-only)
    @Published private(set) var builtinAgents: [AgentDefinition] = []
    /// Kimi Code built-in subagent profiles (compiled in, read-only; no on-disk user customization
    /// convention)
    @Published private(set) var kimiBuiltinAgents: [AgentDefinition] = []
    /// ZCode subagent profiles (aggregated from run records' profileSnapshot, read-only; no
    /// definition files on disk)
    @Published private(set) var zcodeAgents: [AgentDefinition] = []
    @Published private(set) var codexProfiles: [CodexProfile] = []
    @Published private(set) var scanning = false
    /// Phase text while scanning; set to nil when done (the search field's small spinner is too
    /// inconspicuous once the list has data)
    @Published private(set) var scanPhase: String?
    /// When the last scan finished. nil = never scanned (the criterion `refresh` uses)
    @Published private(set) var lastScanAt: Date?
    @Published private(set) var lastError: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.agents", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var allAgents: [AgentDefinition] = []
    private var allOpencodeAgents: [AgentDefinition] = []
    private var allGrokAgents: [AgentDefinition] = []
    private var allCursorAgents: [AgentDefinition] = []
    private var allPluginAgents: [AgentDefinition] = []
    private var allBuiltinAgents: [AgentDefinition] = []
    private var allKimiBuiltinAgents: [AgentDefinition] = []
    private var allZcodeAgents: [AgentDefinition] = []
    private var allProfiles: [CodexProfile] = []

    private var codexConfigURL: URL { EurekaCLI.codexConfigURL }

    // MARK: - Scanning

    /// force = false: scan only if never scanned (shared by launch warm-up and the onAppear
    /// fallback; idempotent). force = true: unconditional full rescan, used only by the refresh
    /// button.
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        scanPhase = L10n.text("Scanning subagents…", zhHans: "正在扫描子代理…")
        queue.async { [weak self] in
            guard let self else { return }
            // Project-level agent roots: .claude/agents, .opencode/agents and .grok/agents under
            // each project repo root
            var claudeProjectRoots: [ProjectScopedRoot] = []
            var opencodeProjectRoots: [ProjectScopedRoot] = []
            var grokProjectRoots: [ProjectScopedRoot] = []
            var cursorProjectRoots: [ProjectScopedRoot] = []
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
                cursorProjectRoots.append(ProjectScopedRoot(
                    root: root.appendingPathComponent(".cursor/agents", isDirectory: true),
                    source: .cursor, projectName: name))
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
            let cursorAgents = AgentDefinitionIndexer.indexCursorAgents(
                systemRoot: CursorPaths.agentsRoot(),
                projectRoots: cursorProjectRoots)
            let pluginAgents = AgentDefinitionIndexer.indexPluginAgents(
                pluginsRoot: AgentDefinitionIndexer.claudePluginsRoot())
            let builtinAgents = AgentDefinitionIndexer.builtinClaudeAgents()
            let kimiBuiltins = AgentDefinitionIndexer.builtinKimiAgents()
            let zcodeAgents = AgentDefinitionIndexer.indexZcodeObservedAgents(
                agentsRoot: ZcodePaths.agentsRoot())
            let profiles = CodexProfileEditor.read(from: ConfigFile.read(self.codexConfigURL))
            DispatchQueue.main.async {
                self.allAgents = agents
                self.allOpencodeAgents = opencodeAgents
                self.allGrokAgents = grokAgents
                self.allCursorAgents = cursorAgents
                self.allPluginAgents = pluginAgents
                self.allBuiltinAgents = builtinAgents
                self.allKimiBuiltinAgents = kimiBuiltins
                self.allZcodeAgents = zcodeAgents
                self.allProfiles = profiles
                self.scanning = false
                self.scanPhase = nil
                self.lastScanAt = Date()
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
            cursorAgents = allCursorAgents
            pluginAgents = allPluginAgents
            builtinAgents = allBuiltinAgents
            kimiBuiltinAgents = allKimiBuiltinAgents
            zcodeAgents = allZcodeAgents
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
        cursorAgents = allCursorAgents.filter(matchAgent)
        pluginAgents = allPluginAgents.filter(matchAgent)
        builtinAgents = allBuiltinAgents.filter(matchAgent)
        kimiBuiltinAgents = allKimiBuiltinAgents.filter(matchAgent)
        zcodeAgents = allZcodeAgents.filter(matchAgent)
        codexProfiles = allProfiles.filter {
            [$0.name, $0.model, $0.personality, $0.reasoningEffort]
                .compactMap { $0?.lowercased() }.joined(separator: " ").contains(query)
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    // MARK: - Claude agent read/write

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Atomic write: leaves a .bak.eureka.<ts> backup before writing
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Create a global Claude agent (`~/.claude/agents/<slug>.md`) with a frontmatter template
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Create a global opencode agent (`~/.config/opencode/agents/<slug>.md`) with an opencode
    /// frontmatter template
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Create a global grok agent (`~/.grok/agents/<slug>.md`) with a grok frontmatter template
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Create a Cursor subagent `~/.cursor/agents/<slug>.md` (convention per Cursor's bundled
    /// create-subagent skill: YAML frontmatter + body as the system prompt)
    func createCursorAgent(name: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            let slug = Self.slugify(name)
            let root = CursorPaths.agentsRoot()
            let file = root.appendingPathComponent(slug + ".md")
            let template = "---\nname: \(slug)\ndescription: \n---\n\n"
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Delete the agent file → Trash
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Enable/disable an agent: moves the .md file between the enabled area ↔
    /// <root>.eureka-disabled (reversible, non-destructive)
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
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    // MARK: - Codex profile read/write (config.toml table edits, backed up + atomically written via ConfigFile)

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
            DispatchQueue.main.async { completion?(ok); self.refresh(force: true) }
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
            DispatchQueue.main.async { completion?(ok); self.refresh(force: true) }
        }
    }

    // MARK: - External open (main thread)

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    // MARK: - Utilities

    private func report(_ error: Error) {
        let message = error.localizedDescription
        DispatchQueue.main.async { self.lastError = message }
    }

    static func slugify(_ name: String) -> String { SkillMemoryService.slugify(name) }
    static func timestamp() -> Int { SkillMemoryService.timestamp() }
}
