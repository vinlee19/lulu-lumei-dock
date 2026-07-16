import EurekaKit
import Foundation

/// 一个 agent 定义 markdown（Claude `~/.claude/agents/<name>.md` 或 opencode `~/.config/opencode/agents/<name>.md`，
/// 均含项目级变体）。frontmatter：Claude 用 name/description/tools/model/color；
/// opencode 用 description/mode(primary|subagent|all)/model/temperature；正文为 system prompt。
/// Codex 没有同类文件（其「agent」是 config.toml 的 `[profiles.*]`）。
public struct AgentDefinition: Equatable, Sendable, Identifiable {
    public var id: String { path }
    public var source: AgentSource
    public var name: String
    public var description: String?
    public var tools: [String]     // 空 = 继承全部工具
    public var model: String?      // opus / sonnet / … 或 provider/model
    public var color: String?
    public var mode: String?       // opencode：primary / subagent / all
    public var scope: SkillScope   // 系统级 or 项目级
    public var path: String        // .md 绝对路径（内置 agent 无文件 = 空串）
    public var enabled: Bool       // 停用区（*.eureka-disabled）= false
    /// 所属插件名（`~/.claude/plugins` 下的插件 agent）；nil = 非插件
    public var pluginName: String?
    /// Claude Code 内置 agent（无磁盘文件，只读展示，随版本可能变化）
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

/// 扫描 Claude agent 定义。纯文件 IO，env 覆盖路径根，便于单测。
public enum AgentDefinitionIndexer {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// `~/.claude/agents`（env `EUREKA_CLAUDE_AGENTS` 覆盖）
    public static func claudeAgentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_AGENTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/agents", isDirectory: true)
    }

    /// 停用区：`<root>.eureka-disabled`（沿用技能约定，非破坏、可逆）
    public static func disabledRoot(for agentsRoot: URL) -> URL {
        agentsRoot.deletingLastPathComponent()
            .appendingPathComponent(agentsRoot.lastPathComponent + ".eureka-disabled", isDirectory: true)
    }

    public static func indexClaudeAgents(
        systemRoot: URL, projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: [systemRoot], source: .claude, projectRoots: projectRoots)
    }

    /// opencode agents：多个系统根（agents + agent）+ 项目 `.opencode/agents`
    public static func indexOpencodeAgents(
        systemRoots: [URL], projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: systemRoots, source: .opencode, projectRoots: projectRoots)
    }

    /// grok agents：用户 `~/.grok/agents` + 内置 `~/.grok/bundled/agents` + 项目 `.grok/agents`
    public static func indexGrokAgents(
        systemRoots: [URL], projectRoots: [ProjectScopedRoot] = []
    ) -> [AgentDefinition] {
        indexAgents(systemRoots: systemRoots, source: .grok, projectRoots: projectRoots)
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
        return result.sorted {
            ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// 扫描一个 agents 根：直属子级的 `*.md` 文件（扁平，非 <dir>/SKILL.md）
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
                name: fields["name"] ?? stem,  // opencode 无 name，文件名即 id
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

    /// `tools` 解析：支持 `a, b, c` 与 `[a, b, c]` 两种写法；nil/空 → []（继承全部）
    public static func parseToolList(_ raw: String?) -> [String] {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return [] }
        if value.first == "[" && value.last == "]" {
            value = String(value.dropFirst().dropLast())
        }
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 插件 agent（~/.claude/plugins）

    /// `~/.claude/plugins`（env `EUREKA_CLAUDE_PLUGINS` 覆盖）
    public static func claudePluginsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PLUGINS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".claude/plugins", isDirectory: true)
    }

    /// 扫描已安装插件的 agents：读 `installed_plugins.json` → 逐插件扫 `<installPath>/agents/*.md`
    /// （含停用区），每条打上 `pluginName`（插件 key `名字@市场` 取「名字」，与调用时的 `plugin:agent` 一致）。
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
        // 按 插件名 → 启用在前 → 名字 排序
        return result.sorted {
            ($0.pluginName ?? "", $0.enabled ? 0 : 1, $0.name.lowercased())
                < ($1.pluginName ?? "", $1.enabled ? 0 : 1, $1.name.lowercased())
        }
    }

    /// Claude Code 内置 agent 静态清单：无磁盘文件、只读展示，随 Claude Code 版本可能变化。
    public static func builtinClaudeAgents() -> [AgentDefinition] {
        let entries: [(name: String, description: String)] = [
            ("general-purpose", "通用多步骤任务：研究复杂问题、搜索代码、执行多步操作"),
            ("Explore", "只读代码搜索：大范围定位文件 / 符号 / 命名约定，只返回结论"),
            ("Plan", "方案设计：产出分步实现计划、识别关键文件与取舍"),
            ("claude", "通用兜底 agent（未指定类型时的默认）"),
            ("claude-code-guide", "Claude Code / Agent SDK / Claude API 使用问答"),
            ("statusline-setup", "配置状态栏（statusline）设置"),
        ]
        return entries.map { entry in
            AgentDefinition(
                source: .claude, name: entry.name, description: entry.description,
                builtin: true, path: "", enabled: true,
                sizeBytes: 0, modifiedAt: .distantPast)
        }
    }
}
