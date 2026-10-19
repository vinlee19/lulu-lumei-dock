import EurekaKit
import Foundation

/// A configured MCP server (read-only index).
///
/// Secret red line: the **values** of `env` / `headers` are never read into the model at the parsing layer;
/// these fields often hold API keys. Only the key names are kept (to show "which env vars are referenced"),
/// and URLs also drop query/fragment (the query may carry a token). Index results live only in memory: not
/// in SQLite, not in the full-text index, not in cloud backup.
public struct MCPServerEntry: Equatable, Sendable, Identifiable {
    public var id: String { "\(source.rawValue):\(configPath):\(name)" }
    public var source: AgentSource
    public var name: String
    /// Transport: stdio / http / sse (an explicit config declaration wins; a url without a
    /// declaration means http)
    public var transport: String
    /// Launch command summary (command + args, truncated), for local display only
    public var commandSummary: String?
    /// Remote URL (query/fragment stripped)
    public var urlSummary: String?
    /// Key names of env / headers (**never the values**)
    public var envKeys: [String]
    /// Owning project name for project-level config (`<repo>/.mcp.json`); nil for global config
    public var projectName: String?
    public var configPath: String
    /// Enabled state: only opencode / grok configs have an `enabled` field; other sources are nil
    /// (no such semantics)
    public var enabled: Bool?

    public init(
        source: AgentSource, name: String, transport: String,
        commandSummary: String?, urlSummary: String?, envKeys: [String],
        projectName: String?, configPath: String, enabled: Bool? = nil
    ) {
        self.source = source
        self.name = name
        self.transport = transport
        self.commandSummary = commandSummary
        self.urlSummary = urlSummary
        self.envKeys = envKeys
        self.projectName = projectName
        self.configPath = configPath
        self.enabled = enabled
    }
}

/// Read-only index of MCP server configs, covering 9 sources whose config paths were verified
/// locally: claude (`~/.claude.json` top level + `<repo>/.mcp.json`), codex / grok (config.toml
/// `[mcp_servers.*]`), gemini / qwen (settings.json), cursor (`~/.cursor/mcp.json`), kimi
/// (standalone `~/.kimi-code/mcp.json`, with config.toml scanning kept as a fallback), opencode
/// (the `mcp` key of `~/.config/opencode/opencode.json`; the sibling `config.json` is a decoy with
/// an empty mcp object and is not read), zcode (cli/config.json; no user-level MCP found locally,
/// the empty read is kept). Trae's `mcp.json` sits next to the JWT and is not read (the same
/// caution as the backup red line). All best-effort: missing files / parse failures are skipped
/// silently.
public enum MCPConfigIndexer {
    /// Each source's **global** MCP config file (indexing and writing share one table so the two
    /// cannot drift). Returns nil = that source has no verified user-level MCP config convention.
    public static func globalConfigURL(
        for source: AgentSource,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        switch source {
        case .claude: return home.appendingPathComponent(".claude.json")
        case .codex: return home.appendingPathComponent(".codex/config.toml")
        case .gemini: return home.appendingPathComponent(".gemini/settings.json")
        case .cursor: return home.appendingPathComponent(".cursor/mcp.json")
        case .kimi: return home.appendingPathComponent(".kimi-code/mcp.json")
        case .qwen: return home.appendingPathComponent(".qwen/settings.json")
        case .grok: return home.appendingPathComponent(".grok/config.toml")
        case .opencode:
            return home.appendingPathComponent(".config/opencode/opencode.json")
        case .zcode: return home.appendingPathComponent(".zcode/cli/config.json")
        default: return nil
        }
    }

    public static func index(
        projectRoots: [(root: URL, name: String)] = [],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [MCPServerEntry] {
        let fm = FileManager.default
        var entries: [MCPServerEntry] = []

        func json(
            _ url: URL?, source: AgentSource,
            container: String = "mcpServers", projectName: String? = nil
        ) {
            guard let url, let data = fm.contents(atPath: url.path) else { return }
            entries += parseJSONServers(
                data, source: source, configPath: url.path,
                container: container, projectName: projectName)
        }
        func toml(_ url: URL?, source: AgentSource) {
            guard let url, let data = fm.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { return }
            entries += parseTOMLServers(text, source: source, configPath: url.path)
        }

        // claude global: top-level mcpServers in ~/.claude.json (per-project entries under the
        // projects subtree are not collected, matching the ctx estimate); project level:
        // <repo>/.mcp.json
        json(globalConfigURL(for: .claude, home: home), source: .claude)
        for (root, name) in projectRoots {
            json(root.appendingPathComponent(".mcp.json"), source: .claude, projectName: name)
            // cursor's project-level convention <repo>/.cursor/mcp.json (documented, same shape as
            // user level)
            json(root.appendingPathComponent(".cursor/mcp.json"),
                 source: .cursor, projectName: name)
        }
        toml(globalConfigURL(for: .codex, home: home), source: .codex)
        json(globalConfigURL(for: .gemini, home: home), source: .gemini)
        json(globalConfigURL(for: .cursor, home: home), source: .cursor)
        // kimi's MCP lives in a standalone mcp.json (verified locally); if config.toml really has
        // [mcp.*] sections, they are still picked up as a fallback
        json(globalConfigURL(for: .kimi, home: home), source: .kimi)
        toml(home.appendingPathComponent(".kimi-code/config.toml"), source: .kimi)
        json(globalConfigURL(for: .qwen, home: home), source: .qwen)
        toml(globalConfigURL(for: .grok, home: home), source: .grok)
        json(globalConfigURL(for: .opencode, home: home), source: .opencode, container: "mcp")
        json(globalConfigURL(for: .zcode, home: home), source: .zcode)

        return entries.sorted {
            ($0.name.lowercased(), $0.source.rawValue, $0.configPath)
                < ($1.name.lowercased(), $1.source.rawValue, $1.configPath)
        }
    }

    // MARK: - JSON (mcpServers: claude/gemini/cursor/kimi/qwen/zcode/project-level .mcp.json;
    //               mcp: opencode, dialect differences below)

    public static func parseJSONServers(
        _ data: Data, source: AgentSource, configPath: String,
        container: String = "mcpServers", projectName: String? = nil
    ) -> [MCPServerEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root[container] as? [String: Any] else { return [] }
        return servers.sorted { $0.key < $1.key }.map { name, value in
            let dict = value as? [String: Any] ?? [:]
            // command: a string (mainstream) or an array (opencode's local form, executable + args)
            var command = dict["command"] as? String
            var args = (dict["args"] as? [Any])?.compactMap { $0 as? String } ?? []
            if command == nil, let array = dict["command"] as? [Any] {
                let parts = array.compactMap { $0 as? String }
                command = parts.first
                args = Array(parts.dropFirst())
            }
            let url = (dict["url"] as? String)
                ?? (dict["httpUrl"] as? String)
                ?? (dict["serverUrl"] as? String)
            // Secret red line: env / environment / headers yield key names only
            var keys: [String] = []
            if let env = dict["env"] as? [String: Any] { keys += env.keys }
            if let env = dict["environment"] as? [String: Any] { keys += env.keys }
            if let headers = dict["headers"] as? [String: Any] { keys += headers.keys }
            return MCPServerEntry(
                source: source,
                name: name,
                transport: transport(declared: (dict["type"] as? String)
                    ?? (dict["transport"] as? String), url: url),
                commandSummary: summarize(command: command, args: args),
                urlSummary: url.map(stripQuery),
                envKeys: keys.sorted(),
                projectName: projectName,
                configPath: configPath,
                enabled: dict["enabled"] as? Bool)
        }
    }

    // MARK: - TOML ([mcp_servers.<name>]: codex; [mcp.<name>]: kimi convention, parsed conservatively)

    /// Line-level parsing with no TOML dependency (same technique as CodexProfileEditor's
    /// `[profiles.*]`). Subsections like `[mcp_servers.<name>.env]` belong to the same server, and
    /// within them **only key names are collected, never values**; an `args = [` array written
    /// across lines is joined (the real shape seen in grok's config), and the array is dropped if a
    /// section header or EOF arrives before it closes; multi-line tables are still not joined
    /// (best-effort: better to miss a summary than misread a secret).
    public static func parseTOMLServers(
        _ text: String, source: AgentSource, configPath: String
    ) -> [MCPServerEntry] {
        var order: [String] = []
        var command: [String: String] = [:]
        var args: [String: [String]] = [:]
        var url: [String: String] = [:]
        var envKeys: [String: Set<String>] = [:]
        var enabled: [String: Bool] = [:]
        var current: String?
        var inSecretSubsection = false
        var inIgnoredSubsection = false
        /// Multi-line array collection state: while `args = [` is unclosed, keep consuming lines
        /// until a `]` appears outside quotes
        var pendingArray: (name: String, buffer: String)?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Collecting a multi-line array: whole-line comments are skipped (allowed inside
            // arrays); a section header means the previous array was malformed and unclosed, so
            // give up collecting rather than swallow the section, and let the line fall through to
            // normal header handling
            if var pending = pendingArray {
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    pendingArray = nil
                } else {
                    let merged = pending.buffer.isEmpty
                        ? line : pending.buffer + " " + line
                    if tomlArrayClosed(merged) {
                        args[pending.name] = inlineArrayStrings(merged)
                        pendingArray = nil
                    } else {
                        pendingArray = (pending.name, merged)
                    }
                    continue
                }
            }
            if line.hasPrefix("[") {
                current = nil
                inSecretSubsection = false
                inIgnoredSubsection = false
                guard line.hasSuffix("]") else { continue }
                let inner = String(line.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespaces)
                let parts = inner.split(separator: ".").map {
                    unquote(String($0).trimmingCharacters(in: .whitespaces))
                }
                guard parts.count >= 2,
                      parts[0] == "mcp_servers" || parts[0] == "mcp" else { continue }
                let name = parts[1]
                if !order.contains(name) { order.append(name) }
                current = name
                // Two kinds of subsection: `.env` / `.headers` are secret sections → collect key
                // names only; other subsections (codex was seen with per-tool `.tools.<tool>`
                // toggles) → ignore entirely, so a key like `enabled = false` is not mislabeled as
                // a "referenced secret key".
                inSecretSubsection = parts.count >= 3
                    && (parts[2] == "env" || parts[2] == "headers")
                inIgnoredSubsection = parts.count >= 3 && !inSecretSubsection
                continue
            }
            guard let name = current, !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            if inIgnoredSubsection { continue }
            let key = unquote(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            if inSecretSubsection {
                envKeys[name, default: []].insert(key)
                continue  // values are never read
            }
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            switch key {
            case "command": command[name] = unquote(value)
            case "url": url[name] = unquote(value)
            case "args":
                if tomlArrayClosed(value) {
                    args[name] = inlineArrayStrings(value)
                } else {
                    // Start of a multi-line array (newline after `args = [`): enter collection
                    // state to consume the following lines
                    pendingArray = (name, value)
                }
            case "enabled": enabled[name] = value.lowercased().hasPrefix("t")  // true/false literal
            case "env", "headers":
                envKeys[name, default: []].formUnion(inlineTableKeys(value))
            default: break
            }
        }
        return order.map { name in
            MCPServerEntry(
                source: source,
                name: name,
                transport: transport(declared: nil, url: url[name]),
                commandSummary: summarize(command: command[name], args: args[name] ?? []),
                urlSummary: url[name].map(stripQuery),
                envKeys: envKeys[name, default: []].sorted(),
                projectName: nil,
                configPath: configPath,
                enabled: enabled[name])
        }
    }

    // MARK: - Private helpers

    private static func transport(declared: String?, url: String?) -> String {
        if let declared = declared?.lowercased(), !declared.isEmpty {
            switch declared {
            case "streamable-http", "remote": return "http"  // opencode's remote normalizes to http
            case "local": return "stdio"                     // opencode's local normalizes to stdio
            default: return declared
            }
        }
        return url == nil ? "stdio" : "http"
    }

    private static func summarize(command: String?, args: [String]) -> String? {
        guard let command, !command.isEmpty else { return nil }
        let joined = ([command] + args).joined(separator: " ")
        return joined.count > 160 ? String(joined.prefix(160)) + "…" : joined
    }

    /// Strips query and fragment from a URL (they may carry a token)
    private static func stripQuery(_ url: String) -> String {
        String(url.prefix { $0 != "?" && $0 != "#" })
    }

    private static func unquote(_ text: String) -> String {
        var value = text
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote)
            && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Single-line inline table `{ A = "x", B = "y" }` → key names (only the left of `=`; values
    /// are never touched)
    private static func inlineTableKeys(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("}") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").compactMap { pair in
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let key = unquote(String(pair[..<eq]).trimmingCharacters(in: .whitespaces))
            return key.isEmpty ? nil : key
        }
    }

    /// Single-line array `["-y", "pkg"]` → string elements (the multi-line form is joined by the
    /// caller before it gets here)
    private static func inlineArrayStrings(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("[") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("]") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    /// Whether an array literal is closed: only a `]` outside quotes counts (a `]` inside quotes is
    /// element content); an escaped `\"` inside quotes does not flip the quote state. A best-effort
    /// scan, enough for the string-array form of args.
    private static func tomlArrayClosed(_ value: String) -> Bool {
        var inString = false
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            switch character {
            case "\\" where inString: escaped = true
            case "\"": inString.toggle()
            case "]" where !inString: return true
            default: break
            }
        }
        return false
    }
}
