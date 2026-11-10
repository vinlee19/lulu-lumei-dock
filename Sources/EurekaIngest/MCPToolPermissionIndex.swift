import Foundation

/// Read-only view of what each agent's own configuration says about using MCP tools: Claude Code's
/// permission rules and `.mcp.json` approvals, Codex's per-server tool lists and approval modes.
/// Nothing here is ever written back, and only these keys are read — a settings file's `env`
/// block and every other key are ignored.
///
/// Other agents have no verified per-tool configuration, so they get no status rather than a
/// guessed one.
public struct MCPToolPermissionIndex: Equatable, Sendable {
    public enum Decision: String, Sendable {
        case allowed
        case ask
        case denied
    }

    // MARK: Claude Code

    /// One `permissions.allow` / `ask` / `deny` entry that names MCP tools
    public struct ClaudeRule: Equatable, Sendable {
        public var decision: Decision
        /// The rule as written, e.g. `mcp__github__get_*`
        public var pattern: String
        public var path: String
        /// Set for rules in a project's `.claude/settings{,.local}.json`: they apply only there
        public var projectName: String?

        public init(decision: Decision, pattern: String, path: String, projectName: String? = nil) {
            self.decision = decision
            self.pattern = pattern
            self.path = path
            self.projectName = projectName
        }
    }

    /// Whether a project's `.mcp.json` server has been approved in Claude Code
    public enum ProjectServerApproval: Equatable, Sendable {
        case approved
        case rejected
        /// No answer recorded: Claude Code asks the first time the project is opened
        case unanswered
    }

    struct ClaudeApprovals: Equatable, Sendable {
        /// nil = user-level file
        var projectPath: String?
        var enableAll = false
        var enabled: Set<String> = []
        var disabled: Set<String> = []
    }

    public struct ClaudeAccess: Equatable, Sendable {
        /// Outcome of the user-level rules (they apply in every project); nil = no rule, so Claude
        /// Code asks on first use in its default mode
        public var everywhere: Decision?
        /// Every matching rule, user-level first, in evaluation order (deny, ask, allow)
        public var rules: [ClaudeRule]
    }

    // MARK: Codex

    public struct CodexServer: Equatable, Sendable {
        /// `enabled_tools`: the allow list; nil = every tool is exposed
        public var enabledTools: [String]?
        /// `disabled_tools`: applied after the allow list
        public var disabledTools: [String] = []
        /// `default_tools_approval_mode`, as written
        public var defaultApprovalMode: String?
        /// `[mcp_servers.<name>.tools.<tool>] approval_mode`, as written
        public var toolApprovalModes: [String: String] = [:]

        public init() {}
    }

    public struct CodexAccess: Equatable, Sendable {
        /// Whether Codex exposes the tool to the model at all
        public var exposed: Bool
        /// The approval mode in effect (per-tool override, else the server default), verbatim
        /// from the config; nil = Codex's own default
        public var approvalMode: String?
    }

    public private(set) var claudeRules: [ClaudeRule] = []
    private(set) var claudeApprovals: [ClaudeApprovals] = []
    /// key = lowercased server name
    public private(set) var codexServers: [String: CodexServer] = [:]

    public init() {}

    public var isEmpty: Bool { claudeRules.isEmpty && codexServers.isEmpty }

    // MARK: Loading

    public static func load(
        projectRoots: [(root: URL, name: String)] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> MCPToolPermissionIndex {
        let fm = FileManager.default
        var index = MCPToolPermissionIndex()
        func claude(_ url: URL, project: (root: URL, name: String)?) {
            guard let data = fm.contents(atPath: url.path) else { return }
            index.addClaudeSettings(
                data, path: url.path, projectName: project?.name,
                projectPath: project?.root.path)
        }
        claude(home.appendingPathComponent(".claude/settings.json"), project: nil)
        for project in projectRoots {
            claude(project.root.appendingPathComponent(".claude/settings.json"), project: project)
            claude(
                project.root.appendingPathComponent(".claude/settings.local.json"),
                project: project)
        }
        if let data = fm.contents(atPath: home.appendingPathComponent(".codex/config.toml").path),
           let text = String(data: data, encoding: .utf8) {
            index.codexServers = parseCodexConfig(text)
        }
        return index
    }

    /// Adds one Claude Code settings file. Rules that Claude Code itself skips are skipped here
    /// too: an `mcp__` rule with parentheses, and an allow rule whose glob is not anchored behind
    /// a literal `mcp__<server>__` prefix (`mcp__*` auto-approves nothing).
    public mutating func addClaudeSettings(
        _ data: Data, path: String, projectName: String? = nil, projectPath: String? = nil
    ) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        let permissions = root["permissions"] as? [String: Any]
        for (key, decision) in [("deny", Decision.denied), ("ask", .ask), ("allow", .allowed)] {
            for pattern in (permissions?[key] as? [String]) ?? []
            where Self.isUsableRule(pattern, decision: decision) {
                claudeRules.append(ClaudeRule(
                    decision: decision, pattern: pattern, path: path, projectName: projectName))
            }
        }
        var approvals = ClaudeApprovals(projectPath: projectPath)
        approvals.enableAll = (root["enableAllProjectMcpServers"] as? Bool) ?? false
        approvals.enabled = Set((root["enabledMcpjsonServers"] as? [String]) ?? [])
        approvals.disabled = Set((root["disabledMcpjsonServers"] as? [String]) ?? [])
        if approvals.enableAll || !approvals.enabled.isEmpty || !approvals.disabled.isEmpty {
            claudeApprovals.append(approvals)
        }
    }

    static func isUsableRule(_ pattern: String, decision: Decision) -> Bool {
        guard pattern.hasPrefix("mcp__"), !pattern.contains("("), !pattern.contains(")")
        else { return false }
        guard decision == .allowed, let star = pattern.firstIndex(of: "*") else { return true }
        // mcp__<server>__<glob>: the server segment must be literal
        let rest = pattern.dropFirst(5)
        guard let separator = rest.range(of: "__") else { return false }
        return separator.upperBound <= star
    }

    // MARK: Queries

    /// Claude Code names an MCP tool `mcp__<server>__<tool>`, with every character outside
    /// `A-Z a-z 0-9 _ -` replaced by `_`
    public static func claudeToolName(server: String, tool: String) -> String {
        "mcp__\(normalize(server))__\(normalize(tool))"
    }

    static func normalize(_ name: String) -> String {
        String(name.unicodeScalars.map { scalar -> Character in
            let ok = (scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)))
                || scalar == "_" || scalar == "-"
            return ok ? Character(scalar) : "_"
        })
    }

    public func claudeAccess(server: String, tool: String) -> ClaudeAccess {
        let name = Self.claudeToolName(server: server, tool: tool)
        let serverName = "mcp__\(Self.normalize(server))"
        let order: [Decision: Int] = [.denied: 0, .ask: 1, .allowed: 2]
        let matching = claudeRules
            .filter { $0.pattern == serverName || Self.glob($0.pattern, matches: name) }
            .enumerated()
            .sorted { lhs, rhs in
                let l = (lhs.element.projectName == nil ? 0 : 1, order[lhs.element.decision] ?? 3)
                let r = (rhs.element.projectName == nil ? 0 : 1, order[rhs.element.decision] ?? 3)
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
        // deny, then ask, then allow: the first match in that order decides
        let everywhere = matching.first { $0.projectName == nil }?.decision
        return ClaudeAccess(everywhere: everywhere, rules: matching)
    }

    /// Approval of a project `.mcp.json` server. A rejection in any applicable file wins.
    ///
    /// `userLevelOnly` is for decisions that act on the answer (auto-probing) rather than
    /// display it: files under `<repo>/.claude/` can be committed by the repo's author, who
    /// could approve their own server, so only `~/.claude/settings.json` may grant there.
    /// Rejections still count from every file — they can only restrict.
    public func claudeProjectServerApproval(
        server: String, projectPath: String, userLevelOnly: Bool = false
    ) -> ProjectServerApproval {
        let applicable = claudeApprovals.filter {
            $0.projectPath == nil || $0.projectPath == projectPath
        }
        if applicable.contains(where: { $0.disabled.contains(server) }) { return .rejected }
        let granting = userLevelOnly ? applicable.filter { $0.projectPath == nil } : applicable
        if granting.contains(where: { $0.enableAll || $0.enabled.contains(server) }) {
            return .approved
        }
        return .unanswered
    }

    public func codexAccess(server: String, tool: String) -> CodexAccess? {
        guard let config = codexServers[server.lowercased()] else { return nil }
        var exposed = config.enabledTools.map { $0.contains(tool) } ?? true
        if config.disabledTools.contains(tool) { exposed = false }
        return CodexAccess(
            exposed: exposed,
            approvalMode: config.toolApprovalModes[tool] ?? config.defaultApprovalMode)
    }

    /// `*` matches any run of characters; everything else is literal
    static func glob(_ pattern: String, matches text: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return pattern == text }
        var rest = Substring(text)
        for (index, part) in parts.enumerated() {
            if index == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if index == parts.count - 1 {
                return rest.hasSuffix(part)
            } else if !part.isEmpty {
                guard let range = rest.range(of: part) else { return false }
                rest = rest[range.upperBound...]
            }
        }
        return true
    }

    // MARK: Codex config.toml (line-level, no TOML dependency)

    /// Reads `[mcp_servers.<name>]` `enabled_tools` / `disabled_tools` /
    /// `default_tools_approval_mode` and `[mcp_servers.<name>.tools.<tool>]` `approval_mode`.
    /// Arrays may span lines. Nothing else in the file is looked at.
    public static func parseCodexConfig(_ text: String) -> [String: CodexServer] {
        var servers: [String: CodexServer] = [:]
        var server: String?
        var tool: String?
        var pending: (key: String, buffer: String)?

        func assign(_ key: String, _ value: String) {
            guard let server else { return }
            var config = servers[server] ?? CodexServer()
            if let tool {
                if key == "approval_mode", let mode = strings(in: value).first {
                    config.toolApprovalModes[tool] = mode
                }
            } else {
                switch key {
                case "enabled_tools": config.enabledTools = strings(in: value)
                case "disabled_tools": config.disabledTools = strings(in: value)
                case "default_tools_approval_mode":
                    config.defaultApprovalMode = strings(in: value).first
                default: return
                }
            }
            servers[server] = config
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if var open = pending {
                if line.hasPrefix("[") && !line.hasPrefix("[\"") && line.hasSuffix("]")
                    && isHeader(line) {
                    pending = nil  // malformed array: drop it, treat this line as a header
                } else {
                    open.buffer += " " + line
                    if arrayClosed(open.buffer) {
                        assign(open.key, open.buffer)
                        pending = nil
                    } else {
                        pending = open
                    }
                    continue
                }
            }
            if line.isEmpty || line.hasPrefix("#") { continue }
            if isHeader(line) {
                let keys = dottedKeys(String(line.dropFirst().dropLast()))
                server = nil
                tool = nil
                guard keys.first == "mcp_servers", keys.count >= 2 else { continue }
                if keys.count == 2 {
                    server = keys[1].lowercased()
                } else if keys.count == 4, keys[2] == "tools" {
                    server = keys[1].lowercased()
                    tool = keys[3]
                }
                continue
            }
            guard server != nil, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("["), !arrayClosed(value) {
                pending = (key, value)
            } else {
                assign(key, value)
            }
        }
        return servers
    }

    private static func isHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && !line.hasPrefix("[[") && line.hasSuffix("]") && !line.contains("=")
    }

    /// Splits `a."b.c".d` on dots outside quotes, unquoting each key
    private static func dottedKeys(_ text: String) -> [String] {
        var keys: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "." {
                keys.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        keys.append(current.trimmingCharacters(in: .whitespaces))
        return keys
    }

    /// Every quoted string in a TOML value (a scalar yields one, an array several)
    private static func strings(in value: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if let open = quote {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\", open == "\"" {
                    escaped = true
                } else if character == open {
                    result.append(current)
                    current = ""
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                break
            }
        }
        return result
    }

    /// A `]` outside quotes closes the array
    private static func arrayClosed(_ value: String) -> Bool {
        var quote: Character?
        var escaped = false
        for character in value {
            if let open = quote {
                if escaped { escaped = false }
                else if character == "\\", open == "\"" { escaped = true }
                else if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "]" {
                return true
            }
        }
        return false
    }
}
