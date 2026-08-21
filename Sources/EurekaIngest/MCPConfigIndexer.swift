import EurekaKit
import Foundation

/// 一个已配置的 MCP server（只读索引）。
///
/// 密钥红线：`env` / `headers` 的**值**在解析层就不读入模型 —— 这些字段常放 API key。
/// 这里只保留键名列表（用于展示"引用了哪些环境变量"），URL 也去掉 query/fragment
/// （query 可能带 token）。索引结果只驻内存：不进 SQLite、不进全文索引、不进云备份。
public struct MCPServerEntry: Equatable, Sendable, Identifiable {
    public var id: String { "\(source.rawValue):\(configPath):\(name)" }
    public var source: AgentSource
    public var name: String
    /// 传输方式：stdio / http / sse（配置显式声明优先；有 url 无声明按 http）
    public var transport: String
    /// 启动命令摘要（command + args，截断），仅本地展示
    public var commandSummary: String?
    /// 远端地址（已去掉 query/fragment）
    public var urlSummary: String?
    /// env / headers 的键名（**绝不含值**）
    public var envKeys: [String]
    /// 项目级配置（`<repo>/.mcp.json`）归属的项目名；全局配置为 nil
    public var projectName: String?
    public var configPath: String
    /// 启停状态：仅 opencode / grok 的配置有 `enabled` 字段；其余源为 nil（无此语义）
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

/// MCP server 配置的只读索引，覆盖 9 个实勘过配置路径的源：
/// claude（`~/.claude.json` 顶层 + `<repo>/.mcp.json`）、codex / grok（config.toml
/// `[mcp_servers.*]`）、gemini / qwen（settings.json）、cursor（`~/.cursor/mcp.json`）、
/// kimi（独立 `~/.kimi-code/mcp.json`，config.toml 扫描保留兜底）、opencode
/// （`~/.config/opencode/opencode.json` 的 `mcp` 键；同目录 `config.json` 是 mcp
/// 空对象的诱饵，不读）、zcode（cli/config.json，实勘无用户级 MCP，保留空读）。
/// Trae 的 `mcp.json` 与 JWT 同目录，不读（与备份红线同源的谨慎）。
/// 全部 best-effort：文件缺失/解析失败安静跳过。
public enum MCPConfigIndexer {
    /// 各源的**全局** MCP 配置文件（索引与写入共用同一张表，避免两处口径漂移）。
    /// 返回 nil = 该源没有已实勘的用户级 MCP 配置约定。
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

        // claude 全局：~/.claude.json 顶层 mcpServers（projects 子树里的按项目文件口径不收，
        // 与 ctx 估算同口径）；项目级：<repo>/.mcp.json
        json(globalConfigURL(for: .claude, home: home), source: .claude)
        for (root, name) in projectRoots {
            json(root.appendingPathComponent(".mcp.json"), source: .claude, projectName: name)
            // cursor 的项目级约定 <repo>/.cursor/mcp.json（文档化约定，与用户级同构）
            json(root.appendingPathComponent(".cursor/mcp.json"),
                 source: .cursor, projectName: name)
        }
        toml(globalConfigURL(for: .codex, home: home), source: .codex)
        json(globalConfigURL(for: .gemini, home: home), source: .gemini)
        json(globalConfigURL(for: .cursor, home: home), source: .cursor)
        // kimi 的 MCP 在独立 mcp.json（实勘）；config.toml 里若真出现 [mcp.*] 段照样兜底
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

    // MARK: - JSON（mcpServers：claude/gemini/cursor/kimi/qwen/zcode/项目级 .mcp.json；
    //               mcp：opencode，方言差异见下）

    public static func parseJSONServers(
        _ data: Data, source: AgentSource, configPath: String,
        container: String = "mcpServers", projectName: String? = nil
    ) -> [MCPServerEntry] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root[container] as? [String: Any] else { return [] }
        return servers.sorted { $0.key < $1.key }.map { name, value in
            let dict = value as? [String: Any] ?? [:]
            // command：字符串（主流）或数组（opencode 的 local 形态，含可执行 + 参数）
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
            // 密钥红线：env / environment / headers 只取键名
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

    // MARK: - TOML（[mcp_servers.<name>]：codex；[mcp.<name>]：kimi 约定，保守解析）

    /// 行级解析，不引 TOML 依赖（与 CodexProfileEditor 的 `[profiles.*]` 手法同源）。
    /// `[mcp_servers.<name>.env]` 之类的子段归属同一 server，且段内**只收键名不读值**；
    /// `args = [` 换行书写的多行数组跨行拼接（grok 实勘的真实形态），遇段头或 EOF
    /// 未闭合则放弃该数组；多行表仍不拼接（best-effort，宁可漏摘要也不误读密钥）。
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
        /// 多行数组收集态：`args = [` 未闭合时持续吃行直到引号外出现 `]`
        var pendingArray: (name: String, buffer: String)?

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 多行数组收集中：整行注释跳过（数组内允许注释）；段头 = 上个数组畸形
            // 未闭合，放弃收集防吞段，该行落回正常段头处理
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
                // 子段分两类：`.env` / `.headers` 是密钥段 → 只收键名；
                // 其它子段（实勘 codex 有 `.tools.<tool>` 逐工具开关）→ 整段忽略，
                // 别把 `enabled = false` 这种键错标成"引用密钥键"。
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
                continue  // 值绝不读取
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
                    // 多行数组开头（`args = [` 后换行）：进收集态吃后续行
                    pendingArray = (name, value)
                }
            case "enabled": enabled[name] = value.lowercased().hasPrefix("t")  // true/false 字面量
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

    // MARK: - 私有小工具

    private static func transport(declared: String?, url: String?) -> String {
        if let declared = declared?.lowercased(), !declared.isEmpty {
            switch declared {
            case "streamable-http", "remote": return "http"  // opencode 的 remote 归一到 http
            case "local": return "stdio"                     // opencode 的 local 归一到 stdio
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

    /// URL 去掉 query 与 fragment（可能带 token）
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

    /// 单行内联表 `{ A = "x", B = "y" }` → 键名（只取 `=` 左侧，值不经手）
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

    /// 单行数组 `["-y", "pkg"]` → 字符串元素（多行形态由调用方拼接后再进来）
    private static func inlineArrayStrings(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("[") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("]") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    /// 数组字面量是否已闭合：引号外的 `]` 才算（引号内的 `]` 是元素内容）；
    /// 引号内的 `\"` 转义不翻转引号态。best-effort 扫描，够覆盖 args 的字符串数组形态。
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
