import EurekaKit
import Foundation

/// An agent definition markdown (Claude `~/.claude/agents/<name>.md` or opencode
/// `~/.config/opencode/agents/<name>.md`, both with project-level variants). Frontmatter: Claude
/// uses name/description/tools/model/color; opencode uses
/// description/mode(primary|subagent|all)/model/temperature; the body is the system prompt. Codex
/// has no equivalent file (its "agents" are `[profiles.*]` in config.toml).
public struct AgentDefinition: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    public var name: String
    public var description: String?
    public var tools: [String]     // empty = inherits all tools
    public var model: String?      // opus / sonnet / ... or provider/model
    public var color: String?
    public var mode: String?       // opencode: primary / subagent / all
    public var scope: SkillScope   // system-level or project-level
    public var path: String        // absolute .md path (built-in agents have no file = empty string)
    public var enabled: Bool       // disabled area (*.eureka-disabled) = false
    /// Owning plugin name (plugin agents under `~/.claude/plugins`); nil = not from a plugin
    public var pluginName: String?
    /// Claude Code built-in agent (no file on disk, read-only display, may change across versions)
    public var builtin: Bool
    public var sizeBytes: UInt64
    public var modifiedAt: Date

    public init(
        source: AgentSource = .claude,
        name: String, description: String?,
        tools: [String] = [], model: String? = nil, color: String? = nil,
        mode: String? = nil,
        scope: SkillScope = .system,
        pluginName: String? = nil,
        builtin: Bool = false,
        path: String, enabled: Bool,
        sizeBytes: UInt64, modifiedAt: Date
    ) {
        self.source = source
        self.name = name
        self.description = description
        self.tools = tools
        self.model = model
        self.color = color
        self.mode = mode
        self.scope = scope
        self.pluginName = pluginName
        self.builtin = builtin
        self.path = path
        self.enabled = enabled
        self.sizeBytes = sizeBytes
        self.modifiedAt = modifiedAt
    }
}

/// Scans Claude agent definitions. Pure file IO; env overrides the path roots for unit tests.
public enum AgentDefinitionIndexer {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.claude/agents` (overridden by env `EUREKA_CLAUDE_AGENTS`)
    public static func claudeAgentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_AGENTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/agents", isDirectory: true)
    }

    /// Disabled area: `<root>.eureka-disabled` (follows the skill convention; non-destructive,
    /// reversible)
    public static func disabledRoot(for agentsRoot: URL) -> URL {
        agentsRoot.deletingLastPathComponent()
            .appendingPathComponent(agentsRoot.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }

    public static func indexClaudeAgents(
        systemRoot: URL, projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: [systemRoot], source: .claude, projectRoots: projectRoots)
    }

    /// opencode agents: several system roots (agents + agent) + project `.opencode/agents`
    public static func indexOpencodeAgents(
        systemRoots: [URL], projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: systemRoots, source: .opencode, projectRoots: projectRoots)
    }

    /// grok agents: user `~/.grok/agents` + bundled `~/.grok/bundled/agents` + project
    /// `.grok/agents`
    public static func indexGrokAgents(
        systemRoots: [URL], projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: systemRoots, source: .grok, projectRoots: projectRoots)
    }

    /// Cursor subagents: `~/.cursor/agents/<name>.md` and `<repo>/.cursor/agents/<name>.md`
    /// (convention per Cursor's own create-subagent skill: YAML frontmatter + body as the system
    /// prompt, same shape as Claude's agents/*.md, so the same scan is reused directly)
    public static func indexCursorAgents(
        systemRoot: URL, projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: [systemRoot], source: .cursor, projectRoots: projectRoots)
    }

    private static func indexAgents(
        systemRoots: [URL], source: AgentSource, projectRoots: [ProjectScopedRoot]
    ) -> [AgentDefinition] {
        var result: [AgentDefinition] = []
        for root in systemRoots {
            result += scanAgentRoot(root, source: source, enabled: true, scope: .system)
            result += scanAgentRoot(
                disabledRoot(for: root), source: source, enabled: false, scope: .system)
        }
        for project in projectRoots {
            let scope = SkillScope.project(project.projectName)
            result += scanAgentRoot(project.root, source: source, enabled: true, scope: scope)
            result += scanAgentRoot(
                disabledRoot(for: project.root), source: source, enabled: false, scope: scope)
        }
        // Keep one entry per path (system-level scanned first → wins): when a project root overlaps
        // a system root the same .md is scanned twice, and AgentDefinition.id = path, so duplicate
        // ids would leave hollow cells in the SwiftUI grid.
        var seenPaths = Set<String>()
        result = result.filter { seenPaths.insert($0.path).inserted }
        return result.sorted {
            ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Scans one agents root: direct-child `*.md` files (flat, not <dir>/SKILL.md)
    static func scanAgentRoot(
        _ root: URL, source: AgentSource = .claude, enabled: Bool, scope: SkillScope
    ) -> [AgentDefinition] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var result: [AgentDefinition] = []
        for file in files where file.pathExtension.lowercased() == "md" {
            let stem = file.deletingPathExtension().lastPathComponent
            if stem.hasPrefix(".") { continue }
            let values = try? file.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let fields = SkillMemoryIndexer.parseFrontmatterFields(
                SkillMemoryIndexer.readHead(file) ?? "")
            result.append(AgentDefinition(
                source: source,
                name: fields["name"] ?? stem,  // opencode has no name; the file name is the id
                description: fields["description"].flatMap { $0.isEmpty ? nil : $0 },
                tools: parseToolList(fields["tools"]),
                model: fields["model"].flatMap { $0.isEmpty ? nil : $0 },
                color: fields["color"].flatMap { $0.isEmpty ? nil : $0 },
                mode: fields["mode"].flatMap { $0.isEmpty ? nil : $0 },
                scope: scope,
                path: file.path,
                enabled: enabled,
                sizeBytes: UInt64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate ?? .distantPast))
        }
        return result
    }

    /// Parses `tools`: supports both `a, b, c` and `[a, b, c]`; nil/empty → [] (inherits all)
    public static func parseToolList(_ raw: String?) -> [String] {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return [] }
        if value.first == "[" && value.last == "]" {
            value = String(value.dropFirst().dropLast())
        }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Plugin agents (~/.claude/plugins)

    /// `~/.claude/plugins` (overridden by env `EUREKA_CLAUDE_PLUGINS`)
    public static func claudePluginsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PLUGINS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/plugins", isDirectory: true)
    }

    /// Scans installed plugins' agents: reads `installed_plugins.json` → scans each plugin's
    /// `<installPath>/agents/*.md` (including the disabled area), tagging each with `pluginName`
    /// (the "name" part of the plugin key `name@marketplace`, matching `plugin:agent` at call
    /// time).
    public static func indexPluginAgents(pluginsRoot: URL) -> [AgentDefinition] {
        let installedURL = pluginsRoot.appendingPathComponent("installed_plugins.json")
        guard let data = try? Data(contentsOf: installedURL),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        var result: [AgentDefinition] = []
        for (key, value) in plugins {
            let pluginName = key.split(separator: "@").first.map(String.init) ?? key
            guard let installs = value as? [[String: Any]] else { continue }
            for install in installs {
                guard let installPath = install["installPath"] as? String, !installPath.isEmpty
                else { continue }
                let agentsRoot = URL(fileURLWithPath: installPath, isDirectory: true)
                    .appendingPathComponent("agents", isDirectory: true)
                var group = scanAgentRoot(agentsRoot, source: .claude, enabled: true, scope: .system)
                group += scanAgentRoot(
                    disabledRoot(for: agentsRoot), source: .claude, enabled: false, scope: .system)
                for index in group.indices { group[index].pluginName = pluginName }
                result += group
            }
        }
        // Sort by plugin name → enabled first → name
        return result.sorted {
            ($0.pluginName ?? "", $0.enabled ? 0 : 1, $0.name.lowercased())
                < ($1.pluginName ?? "", $1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Static list of Claude Code built-in agents: no files on disk, read-only display, may change
    /// across Claude Code versions.
    public static func builtinClaudeAgents() -> [AgentDefinition] {
        let entries: [(name: String, description: String)] = [
            ("general-purpose", L10n.text("General multi-step tasks: research complex problems, search code, and perform multiple operations", zhHans: "通用多步骤任务：研究复杂问题、搜索代码、执行多步操作")),
            ("Explore", L10n.text("Read-only code search: locate files / symbols / naming conventions and return findings", zhHans: "只读代码搜索：大范围定位文件 / 符号 / 命名约定，只返回结论")),
            ("Plan", L10n.text("Plan design: produce implementation steps, identify key files and tradeoffs", zhHans: "方案设计：产出分步实现计划、识别关键文件与取舍")),
            ("claude", L10n.text("General-purpose fallback agent (default when no type is specified)", zhHans: "通用兜底 agent（未指定类型时的默认）")),
            ("claude-code-guide", L10n.text("Help with Claude Code / Agent SDK / Claude API", zhHans: "Claude Code / Agent SDK / Claude API 使用问答")),
            ("statusline-setup", L10n.text("Configure statusline settings", zhHans: "配置状态栏（statusline）设置")),
        ]
        return entries.map { entry in
            AgentDefinition(
                source: .claude, name: entry.name, description: entry.description,
                builtin: true, path: "", enabled: true,
                sizeBytes: 0, modifiedAt: .distantPast)
        }
    }

    /// ZCode subagent profiles: built into the CLI binary with no definition files on disk, but
    /// every spawned subagent writes its `profileSnapshot` (name/description/tools/color) into the
    /// run record `~/.zcode/cli/agents/<sess>/agent_*/metadata.json` → aggregate the snapshots
    /// actually observed for display (only profiles that have run are listed; no guessing at a
    /// static list). For the same profileId the latest snapshot wins.
    public static func indexZcodeObservedAgents(agentsRoot: URL) -> [AgentDefinition] {
        let fm = FileManager.default
        let sessionDirs = (try? fm.contentsOfDirectory(
            at: agentsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        // profileId → (snapshot definition, observed time); the latest is kept per id
        var latest: [String: (definition: AgentDefinition, observedAt: Date)] = [:]
        for sessionDir in sessionDirs {
            let agentDirs = (try? fm.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in agentDirs where dir.lastPathComponent.hasPrefix("agent_") {
                let metaURL = dir.appendingPathComponent("metadata.json")
                guard let data = try? Data(contentsOf: metaURL),
                      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let profile = root["profileSnapshot"] as? [String: Any]
                else { continue }
                let name = (profile["name"] as? String)
                    ?? (root["profileId"] as? String) ?? "subagent"
                let key = (root["profileId"] as? String) ?? name
                let observedAt = ZcodeRolloutDecoder.parseISO(root["createdAt"] as? String)
                    ?? .distantPast
                if let existing = latest[key], existing.observedAt >= observedAt { continue }
                latest[key] = (AgentDefinition(
                    source: .zcode,
                    name: name,
                    description: (profile["description"] as? String)
                        .flatMap { $0.isEmpty ? nil : $0 },
                    tools: (profile["tools"] as? [String]) ?? [],
                    color: (profile["color"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                    builtin: true, path: "", enabled: true,
                    sizeBytes: 0, modifiedAt: observedAt), observedAt)
            }
        }
        return latest.values.map(\.definition)
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    /// Static list of Kimi Code built-in subagent profiles: compiled into the CLI binary
    /// (profile/default/*.yaml), and there's no on-disk convention for user-defined agents →
    /// read-only display, may change across Kimi Code versions.
    public static func builtinKimiAgents() -> [AgentDefinition] {
        let entries: [(name: String, description: String)] = [
            ("coder", L10n.text("Default coding subagent (AgentSwarm default): write / edit code / run commands", zhHans: "默认编码子代理（AgentSwarm 缺省类型）：写码 / 改码 / 跑命令")),
            ("explore", L10n.text("Read-only exploration: search and read code without making changes", zhHans: "只读探索：搜索与阅读代码，不做修改")),
            ("plan", L10n.text("Planning: produce an implementation plan (for plan mode)", zhHans: "规划：产出实现计划（plan mode 配套）")),
            ("agent", L10n.text("General agent profile (extends base for other types)", zhHans: "通用 agent profile（其余类型的 extends 基底）")),
        ]
        return entries.map { entry in
            AgentDefinition(
                source: .kimi, name: entry.name, description: entry.description,
                builtin: true, path: "", enabled: true,
                sizeBytes: 0, modifiedAt: .distantPast)
        }
    }
}
