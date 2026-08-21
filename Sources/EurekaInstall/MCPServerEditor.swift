import Foundation

/// MCP server 的**完整定义**（含 env / headers 的值）。
///
/// ⚠️ 完整保真只允许存在于内存：值只在"读源配置 → 写目标配置"之间中转，
/// 不落库、不进日志、不上云、不进 UI —— 展示层一律走 MCPConfigIndexer 的键名版。
public struct MCPServerDefinition: Equatable {
    public enum Transport: Equatable {
        case stdio
        case remote
    }

    public var name: String
    public var transport: Transport
    public var command: String?
    public var args: [String]
    public var env: [String: String]
    public var url: String?
    public var headers: [String: String]
    public var timeout: Int?

    public init(
        name: String, transport: Transport,
        command: String? = nil, args: [String] = [], env: [String: String] = [:],
        url: String? = nil, headers: [String: String] = [:], timeout: Int? = nil
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.env = env
        self.url = url
        self.headers = headers
        self.timeout = timeout
    }
}

public enum MCPEditError: Error, LocalizedError, Equatable {
    /// 目标配置里已有同名 server（一律不覆盖，与技能传播同一规矩）
    case alreadyExists(String)
    /// remove / read 时目标里没有这个 server
    case notFound(String)
    /// 定义不完整（stdio 缺 command / remote 缺 url），或含无法安全写入的字符
    case invalidDefinition(String)
    /// 目标格式未实勘，拒绝写入（如远程 server → TOML 目标）
    case unsupportedTarget(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyExists(let name): return "已存在同名 server「\(name)」，不覆盖"
        case .notFound(let name): return "没有找到 server「\(name)」"
        case .invalidDefinition(let detail): return "定义不完整：\(detail)"
        case .unsupportedTarget(let detail): return detail
        }
    }
}

/// JSON 方言：同一 mcpServers 语义在各家的字段差异（本机实勘）。
public enum MCPJSONStyle {
    /// claude / qwen：显式 `type`（stdio / http）
    case typed
    /// gemini / cursor / kimi：无 `type`，靠字段推断；remote 支持 `timeout`
    case plain
    /// opencode：`type` local/remote、command 是数组（含可执行）、env 叫 `environment`、带 `enabled`
    case opencode
}

/// MCP server 配置的读写引擎（纯文本进出，零依赖，可单测）。
///
/// JSON 侧的 parse/serialize 契约与 `ClaudeHooksInstaller` 逐字节一致
/// （空文件 → 空对象；`.prettyPrinted + .sortedKeys + .withoutEscapingSlashes` + 尾换行；
/// 整文件重排是既有契约）。TOML 侧照 `CodexProfileEditor` 的段落手术：
/// 行级读写、绝不重排整个文件、EOF 追加规范化、段名引号规则一致。
/// 所有守卫先于任何改动 —— 抛错即表示"原文件未动"。
public enum MCPServerEditor {
    // MARK: - JSON（claude / gemini / cursor / kimi / qwen / opencode）

    /// 把 server 写入 `container`（"mcpServers" 或 opencode 的 "mcp"）。
    /// 容器缺失则创建；容器存在但不是对象 → foreignConfig（绝不覆盖看不懂的形态）。
    public static func upsertJSON(
        into json: String, definition: MCPServerDefinition,
        container: String, style: MCPJSONStyle
    ) throws -> String {
        try validate(definition)
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard servers[definition.name] == nil else {
            throw MCPEditError.alreadyExists(definition.name)
        }
        servers[definition.name] = encode(definition, style: style)
        root[container] = servers
        return try serialize(root)
    }

    public static func removeJSON(
        from json: String, name: String, container: String
    ) throws -> String {
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard servers[name] != nil else { throw MCPEditError.notFound(name) }
        servers.removeValue(forKey: name)
        // 容器保留（空对象是各家配置的常态，如 kimi 的 mcp.json），比删键更少惊喜
        root[container] = servers
        return try serialize(root)
    }

    /// 读出完整定义（含 env/headers 值）。对三种 JSON 方言做宽容解码：
    /// command 既可能是字符串也可能是数组（opencode），env 也接受 `environment`。
    public static func readDefinitionJSON(
        _ json: String, name: String, container: String
    ) throws -> MCPServerDefinition {
        let root = try parse(json)
        let servers = try serversDict(in: root, container: container)
        guard let entry = servers[name] as? [String: Any] else {
            throw MCPEditError.notFound(name)
        }
        return decodeEntry(name: name, dict: entry)
    }

    /// 编辑既有 server（**合并而非重编码**）：条目必须已存在；写入建模字段、
    /// 已置空的建模字段删除，**未建模键原样保留** —— 尤其 opencode 的 `enabled`
    /// 绝不在编辑时被翻转/覆盖（只有该键原本不存在且方言要求时才补写）。
    public static func updateJSON(
        in json: String, definition: MCPServerDefinition,
        container: String, style: MCPJSONStyle
    ) throws -> String {
        try validate(definition)
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard var entry = servers[definition.name] as? [String: Any] else {
            throw MCPEditError.notFound(definition.name)
        }
        // 建模字段全集先清后写（stdio ↔ remote 的切换也随之处理干净）；enabled 不在清单里
        let modeled = ["type", "command", "args", "env", "environment",
                       "headers", "url", "httpUrl", "serverUrl", "timeout"]
        for key in modeled { entry.removeValue(forKey: key) }
        for (key, value) in encode(definition, style: style) {
            if key == "enabled", entry["enabled"] != nil { continue }  // 保留原启停状态
            entry[key] = value
        }
        servers[definition.name] = entry
        root[container] = servers
        return try serialize(root)
    }

    /// 解析用户粘贴的 JSON 片段（README 常见的 `{"mcpServers": {…}}`；也接受
    /// opencode 的 `{"mcp": {…}}` 或顶层直接就是 server 映射的裁剪片段）。
    /// 解析失败/无内容返回空数组，绝不抛错 —— 表单实时反馈用。
    public static func parsePasted(_ text: String) -> [MCPServerDefinition] {
        guard let root = try? parse(text), !root.isEmpty else { return [] }
        let container = (root["mcpServers"] as? [String: Any])
            ?? (root["mcp"] as? [String: Any])
            ?? root
        return container.sorted { $0.key < $1.key }.compactMap { name, value in
            guard let dict = value as? [String: Any] else { return nil }
            let definition = decodeEntry(name: name, dict: dict)
            // 空壳（既无命令也无地址）不算 server —— 顶层裁剪片段里常混着别的键
            guard definition.command != nil || definition.url != nil else { return nil }
            return definition
        }
    }

    /// 「快速安装」解析：一个输入框通吃命令 / URL / JSON（对照 ZCode 的快速安装页签）。
    /// - `{…}` 开头 → 按 JSON 片段解析（可多个 server）；
    /// - `http(s)://…` → 远程 server，名称从域名派生（`mcp.notion.com` → notion）；
    /// - 其余 → 本地命令行，名称从包名派生（`npx -y chrome-devtools-mcp@latest` →
    ///   chrome-devtools-mcp；`@upstash/context7-mcp` → context7-mcp）。
    /// 解析失败/空输入返回空数组，绝不抛错 —— 表单实时预览用。
    public static func parseQuickInput(_ text: String) -> [MCPServerDefinition] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.hasPrefix("{") { return parsePasted(trimmed) }

        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return [] }

        if first.hasPrefix("http://") || first.hasPrefix("https://") {
            guard let url = URL(string: first) else { return [] }
            return [MCPServerDefinition(
                name: deriveName(fromURL: url),
                transport: .remote,
                url: first)]
        }
        // 命令行：首 token 是可执行，其余是参数；多行输入只取第一行的语义（换行当空白拆）
        return [MCPServerDefinition(
            name: deriveName(fromCommand: first, args: Array(tokens.dropFirst())),
            transport: .stdio,
            command: first,
            args: Array(tokens.dropFirst()))]
    }

    /// 域名 → server 名：去掉 `mcp.` 前缀后取第一段（`mcp.notion.com` → notion，
    /// `example.com` → example）；解析不出就退回 "remote-mcp"
    static func deriveName(fromURL url: URL) -> String {
        guard var host = url.host, !host.isEmpty else { return "remote-mcp" }
        if host.hasPrefix("mcp.") { host = String(host.dropFirst(4)) }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        let slug = sanitizeName(label)
        return slug.isEmpty ? "remote-mcp" : slug
    }

    /// 命令行 → server 名：优先取含 "mcp" 的非 flag 参数（多为包名），
    /// 否则第一个非 flag 参数，否则命令本身；再剥 npm 版本后缀与 scope/路径前缀。
    static func deriveName(fromCommand command: String, args: [String]) -> String {
        let candidates = args.filter { !$0.hasPrefix("-") }
        let picked = candidates.first { $0.lowercased().contains("mcp") }
            ?? candidates.first
            ?? command
        let slug = sanitizeName(stripPackageDecorations(picked))
        return slug.isEmpty ? "mcp-server" : slug
    }

    /// `@scope/name@1.2` → name；`some/path/binary` → binary；`pkg@latest` → pkg
    private static func stripPackageDecorations(_ token: String) -> String {
        var name = token
        if name.hasPrefix("@"), let slash = name.firstIndex(of: "/") {
            name = String(name[name.index(after: slash)...])  // 去 npm scope
        }
        if let at = name.lastIndex(of: "@"), at != name.startIndex {
            name = String(name[..<at])  // 去版本后缀
        }
        if let slash = name.lastIndex(of: "/") {
            name = String(name[name.index(after: slash)...])  // 取路径末段
        }
        return name
    }

    /// 名称清洗成各家都认的 slug：字母/数字/-/_ 之外一律折成 -
    private static func sanitizeName(_ text: String) -> String {
        var slug = String(text.map {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-"
        })
        while slug.contains("--") { slug = slug.replacingOccurrences(of: "--", with: "-") }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 三方言通吃的条目解码（readDefinitionJSON / parsePasted 共用）
    private static func decodeEntry(name: String, dict entry: [String: Any]) -> MCPServerDefinition {
        var command: String?
        var args: [String] = []
        if let text = entry["command"] as? String {
            command = text
            args = (entry["args"] as? [Any])?.compactMap { $0 as? String } ?? []
        } else if let array = entry["command"] as? [Any] {
            let parts = array.compactMap { $0 as? String }
            command = parts.first
            args = Array(parts.dropFirst())
        }
        var env: [String: String] = [:]
        for key in ["env", "environment"] {
            for (envKey, value) in (entry[key] as? [String: Any]) ?? [:] {
                env[envKey] = stringValue(value)
            }
        }
        var headers: [String: String] = [:]
        for (key, value) in (entry["headers"] as? [String: Any]) ?? [:] {
            headers[key] = stringValue(value)
        }
        let url = (entry["url"] as? String)
            ?? (entry["httpUrl"] as? String)
            ?? (entry["serverUrl"] as? String)
        return MCPServerDefinition(
            name: name,
            transport: url == nil ? .stdio : .remote,
            command: command, args: args, env: env,
            url: url, headers: headers,
            timeout: entry["timeout"] as? Int)
    }

    /// 启停（JSON 方言，实证仅 opencode 有 enabled 语义）：只改 enabled 一个键，
    /// 其余字段原样保留。
    public static func setEnabledJSON(
        in json: String, name: String, container: String, enabled: Bool
    ) throws -> String {
        var root = try parse(json)
        var servers = try serversDict(in: root, container: container)
        guard var entry = servers[name] as? [String: Any] else {
            throw MCPEditError.notFound(name)
        }
        entry["enabled"] = enabled
        servers[name] = entry
        root[container] = servers
        return try serialize(root)
    }

    /// 启停（TOML 方言，实证 codex / grok 有 enabled 键）：主段内原位改写
    /// `enabled = …` 行（没有就补在段末），其余行原样保留。
    public static func setEnabledTOML(
        in toml: String, name: String, enabled: Bool
    ) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        guard let main = sectionRange(in: lines, name: name, subsection: nil) else {
            throw MCPEditError.notFound(name)
        }
        let rendered = "enabled = \(enabled)"
        var replaced = false
        for index in (main.lowerBound + 1)..<main.upperBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = unquote(String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces))
            if key == "enabled" {
                lines[index] = rendered
                replaced = true
                break
            }
        }
        if !replaced {
            // 补在段末（跳过段尾空行，与 updateTOML 的补写位置一致）
            var insertAt = main.upperBound
            while insertAt > main.lowerBound + 1,
                  lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                insertAt -= 1
            }
            lines.insert(rendered, at: insertAt)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - TOML（codex / grok 的 [mcp_servers.<name>]）

    /// 追加 `[mcp_servers.<name>]` 段（+ 可选 `.env` 子段 / 远程鉴权键）。
    /// 远程形态已实勘（本机 codex config.toml）：`url` 键即启用远程 server；
    /// `Authorization` 请求头 → `bearer_token`（官方字段，运行时以 Bearer 方案发送）。
    /// 其它请求头需要 `http_headers`，形态未实勘 → 拒写防造废配置（grok 无远程证据，由
    /// MCPService.installBlockReason 在矩阵层继续拒绝）。
    public static func upsertTOML(
        into toml: String, definition: MCPServerDefinition
    ) throws -> String {
        try validate(definition)
        try guardRemoteHeadersForTOML(definition)
        if definition.transport == .stdio, definition.command == nil {
            throw MCPEditError.invalidDefinition("stdio server 缺少 command")
        }
        let existing = sectionRanges(in: toml.components(separatedBy: "\n"))
        if existing.keys.contains(definition.name) {
            throw MCPEditError.alreadyExists(definition.name)
        }
        // 值不能带换行/控制字符：行级 TOML 写不了多行字符串，宁可拒绝也不写坏文件
        for value in [definition.command ?? "", definition.url ?? ""] + definition.args
            + definition.env.keys + definition.env.values + definition.headers.values {
            if value.contains("\n") || value.contains("\r") {
                throw MCPEditError.invalidDefinition("值包含换行，无法安全写入 TOML")
            }
        }

        var lines = toml.isEmpty ? [] : toml.components(separatedBy: "\n")
        // EOF 追加规范化（照 CodexProfileEditor）：去尾部空行 → 一个空行分隔 → 段落
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        if !lines.isEmpty { lines.append("") }
        lines.append(headerLine(name: definition.name))
        if definition.transport == .remote {
            lines.append("url = \"\(escape(definition.url ?? ""))\"")
            if let token = authorizationBearerToken(of: definition) {
                lines.append("bearer_token = \"\(escape(token))\"")
            }
        } else {
            lines.append("command = \"\(escape(definition.command ?? ""))\"")
            if !definition.args.isEmpty {
                let items = definition.args.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                lines.append("args = [\(items)]")
            }
            if !definition.env.isEmpty {
                lines.append("")
                lines.append(headerLine(name: definition.name, subsection: "env"))
                for key in definition.env.keys.sorted() {
                    lines.append("\(key) = \"\(escape(definition.env[key] ?? ""))\"")
                }
            }
        }
        var result = lines.joined(separator: "\n")
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }

    /// 远程定义装进 TOML 目标的鉴权边界：只认 `Authorization`（→ bearer_token）；
    /// 其它请求头需要 `http_headers`，形态未实勘 → 拒绝（新建与编辑共用）。
    private static func guardRemoteHeadersForTOML(
        _ definition: MCPServerDefinition
    ) throws {
        guard definition.transport == .remote else { return }
        if let extra = definition.headers.keys
            .first(where: { $0.lowercased() != "authorization" }) {
            throw MCPEditError.unsupportedTarget(
                "该目标对自定义请求头（\(extra)）的写法未验证，暂只支持 Authorization（bearer_token）")
        }
    }

    /// `Authorization` 头值 → bearer_token 值：JSON 侧常带 "Bearer " 前缀，
    /// codex 的 bearer_token 运行时自带 Bearer 方案，去前缀防双重拼接
    private static func authorizationBearerToken(
        of definition: MCPServerDefinition
    ) -> String? {
        guard let value = definition.headers
            .first(where: { $0.key.lowercased() == "authorization" })?.value else { return nil }
        if value.lowercased().hasPrefix("bearer ") { return String(value.dropFirst(7)) }
        return value
    }

    /// 编辑既有 TOML server（**原位改写**，段落位置不动）：主段内重写 command/args/url/
    /// bearer_token（未识别键如 `enabled`、注释原样保留——照 CodexProfileEditor.upsert 的
    /// 段内手法）；env 三形态：已有 `.env` 子段 → 整体重写子段体（置空则删子段）；只有内联
    /// `env = {…}` → 重写该行；两者皆无且 env 非空 → 主段末补内联行。`.tools.*` 等其它子段
    /// 原样不动。与 upsert 不同：已是 remote 的条目允许改 url（stdio-only 限制只针对新建）。
    public static func updateTOML(
        in toml: String, definition: MCPServerDefinition
    ) throws -> String {
        try validate(definition)
        try guardRemoteHeadersForTOML(definition)
        for value in [definition.command ?? "", definition.url ?? ""] + definition.args
            + definition.env.keys + definition.env.values {
            if value.contains("\n") || value.contains("\r") {
                throw MCPEditError.invalidDefinition("值包含换行，无法安全写入 TOML")
            }
        }
        var lines = toml.components(separatedBy: "\n")
        guard sectionRange(in: lines, name: definition.name, subsection: nil) != nil else {
            throw MCPEditError.notFound(definition.name)
        }

        // Pass A：.env 子段（先做——它在主段之后，改主段体不影响它的定位反之则影响）
        var hasEnvSubsection = false
        if let envRange = sectionRange(in: lines, name: definition.name, subsection: "env") {
            if definition.env.isEmpty {
                var start = envRange.lowerBound
                if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                    start -= 1
                }
                lines.removeSubrange(start..<envRange.upperBound)
            } else {
                hasEnvSubsection = true
                let body = definition.env.keys.sorted().map {
                    "\($0) = \"\(escape(definition.env[$0] ?? ""))\""
                }
                lines.replaceSubrange((envRange.lowerBound + 1)..<envRange.upperBound, with: body)
            }
        }

        // Pass B：主段体重写（Pass A 可能移动过行号，重新定位）
        guard let main = sectionRange(in: lines, name: definition.name, subsection: nil) else {
            throw MCPEditError.notFound(definition.name)
        }
        func managedLine(_ key: String) -> String? {
            switch key {
            case "command":
                return definition.command.map { "command = \"\(escape($0))\"" }
            case "args":
                guard !definition.args.isEmpty else { return nil }
                let items = definition.args.map { "\"\(escape($0))\"" }.joined(separator: ", ")
                return "args = [\(items)]"
            case "url":
                guard definition.transport == .remote else { return nil }
                return definition.url.map { "url = \"\(escape($0))\"" }
            case "bearer_token":
                guard definition.transport == .remote else { return nil }
                return authorizationBearerToken(of: definition)
                    .map { "bearer_token = \"\(escape($0))\"" }
            case "env":
                // 子段是权威时不写内联；env 置空也不写
                guard !hasEnvSubsection, !definition.env.isEmpty else { return nil }
                let pairs = definition.env.keys.sorted().map {
                    "\($0) = \"\(escape(definition.env[$0] ?? ""))\""
                }.joined(separator: ", ")
                return "env = { \(pairs) }"
            default:
                return nil
            }
        }
        let managedKeys = ["command", "args", "url", "bearer_token", "env"]
        var newBody: [String] = []
        var written = Set<String>()
        for line in lines[(main.lowerBound + 1)..<main.upperBound] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") {
                let key = unquote(String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces))
                if managedKeys.contains(key) {
                    // 改：写新值；置空/被子段接管：删行
                    if !written.contains(key), let rendered = managedLine(key) {
                        newBody.append(rendered)
                    }
                    written.insert(key)
                    continue
                }
            }
            newBody.append(line)  // 未建模键（enabled 等）/ 注释 / 空行原样保留
        }
        // 段内原来没有的建模键补写在段末（跳过末尾空行之前）
        var insertAt = newBody.count
        while insertAt > 0,
              newBody[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            insertAt -= 1
        }
        for key in managedKeys where !written.contains(key) {
            if let rendered = managedLine(key) {
                newBody.insert(rendered, at: insertAt)
                insertAt += 1
            }
        }
        lines.replaceSubrange((main.lowerBound + 1)..<main.upperBound, with: newBody)
        return lines.joined(separator: "\n")
    }

    /// 删除 `[mcp_servers.<name>]` 及其**全部子段**（`.env` / `.tools.*`，实勘 codex 有后者），
    /// 每段顺带吃掉前导空行（照 CodexProfileEditor.remove 的空行规矩）。
    public static func removeTOML(from toml: String, name: String) throws -> String {
        var lines = toml.components(separatedBy: "\n")
        var removedAny = false
        while let range = firstSectionRange(in: lines, matching: name) {
            var start = range.lowerBound
            if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                start -= 1
            }
            lines.removeSubrange(start..<range.upperBound)
            removedAny = true
        }
        guard removedAny else { throw MCPEditError.notFound(name) }
        return lines.joined(separator: "\n")
    }

    /// 读出完整定义（含 env 值）：command / args / url + inline `env = {…}` 与 `.env` 子段。
    public static func readDefinitionTOML(
        _ toml: String, name: String
    ) throws -> MCPServerDefinition {
        var command: String?
        var args: [String] = []
        var url: String?
        var env: [String: String] = [:]
        var headers: [String: String] = [:]
        var found = false
        var inMain = false
        var inEnvSub = false
        /// 多行数组收集态（与 MCPConfigIndexer 同手法）：`args = [` 未闭合时吃行到 `]`
        var pendingArgs: String?

        for rawLine in toml.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if let buffer = pendingArgs {
                if line.hasPrefix("#") { continue }
                if line.hasPrefix("[") {
                    pendingArgs = nil  // 畸形未闭合：放弃，落回段头处理
                } else {
                    let merged = buffer.isEmpty ? line : buffer + " " + line
                    if arrayLiteralClosed(merged) {
                        args = inlineArrayStrings(merged)
                        pendingArgs = nil
                    } else {
                        pendingArgs = merged
                    }
                    continue
                }
            }
            if line.hasPrefix("[") {
                inMain = false
                inEnvSub = false
                guard let path = headerPath(line) else { continue }
                guard path.count >= 2, path[0] == "mcp_servers", path[1] == name else { continue }
                found = true
                if path.count == 2 {
                    inMain = true
                } else if path.count == 3, path[2] == "env" {
                    inEnvSub = true
                }
                continue
            }
            guard inMain || inEnvSub, !line.isEmpty, !line.hasPrefix("#"),
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = unquote(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            if inEnvSub {
                env[key] = unquote(value)
                continue
            }
            switch key {
            case "command": command = unquote(value)
            case "url": url = unquote(value)
            case "args":
                if arrayLiteralClosed(value) {
                    args = inlineArrayStrings(value)
                } else {
                    pendingArgs = value
                }
            case "bearer_token":
                // 运行时以 Bearer 方案发送 → 读回时补全 Authorization 头值，
                // 探测与编辑表单即可按 HTTP 语义直接使用（round-trip 稳定）
                headers["Authorization"] = "Bearer \(unquote(value))"
            case "env":
                for (envKey, envValue) in inlineTablePairs(value) { env[envKey] = envValue }
            default: break
            }
        }
        guard found else { throw MCPEditError.notFound(name) }
        return MCPServerDefinition(
            name: name,
            transport: url == nil ? .stdio : .remote,
            command: command, args: args, env: env, url: url, headers: headers)
    }

    // MARK: - JSON 私有（parse/serialize 契约照 ClaudeHooksInstaller）

    /// 公开供测试与表单预览复用（契约与 ClaudeHooksInstaller.parse 一致）
    public static func parse(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let dict = object as? [String: Any]
        else { throw InstallError.invalidJSON }
        return dict
    }

    public static func serialize(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    private static func serversDict(
        in root: [String: Any], container: String
    ) throws -> [String: Any] {
        guard let value = root[container] else { return [:] }
        guard let servers = value as? [String: Any] else {
            throw InstallError.foreignConfig(
                "配置里的 \(container) 字段不是对象，无法识别。为避免覆盖看不懂的内容，不做任何改动。")
        }
        return servers
    }

    private static func validate(_ definition: MCPServerDefinition) throws {
        let name = definition.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw MCPEditError.invalidDefinition("名称不能为空") }
        switch definition.transport {
        case .stdio:
            guard let command = definition.command,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPEditError.invalidDefinition("stdio server 缺少 command")
            }
        case .remote:
            guard let url = definition.url,
                  !url.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw MCPEditError.invalidDefinition("远程 server 缺少 URL")
            }
        }
    }

    /// 各方言的字段投影（空集合不写，保持配置干净）
    public static func encode(_ definition: MCPServerDefinition, style: MCPJSONStyle) -> [String: Any] {
        var entry: [String: Any] = [:]
        switch (style, definition.transport) {
        case (.typed, .stdio):
            entry["type"] = "stdio"
            entry["command"] = definition.command ?? ""
            if !definition.args.isEmpty { entry["args"] = definition.args }
            if !definition.env.isEmpty { entry["env"] = definition.env }
        case (.typed, .remote):
            entry["type"] = "http"
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
        case (.plain, .stdio):
            entry["command"] = definition.command ?? ""
            if !definition.args.isEmpty { entry["args"] = definition.args }
            if !definition.env.isEmpty { entry["env"] = definition.env }
        case (.plain, .remote):
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
            if let timeout = definition.timeout { entry["timeout"] = timeout }
        case (.opencode, .stdio):
            entry["type"] = "local"
            entry["command"] = [definition.command ?? ""] + definition.args
            if !definition.env.isEmpty { entry["environment"] = definition.env }
            entry["enabled"] = true
        case (.opencode, .remote):
            entry["type"] = "remote"
            entry["url"] = definition.url ?? ""
            if !definition.headers.isEmpty { entry["headers"] = definition.headers }
            entry["enabled"] = true
        }
        return entry
    }

    private static func stringValue(_ value: Any) -> String {
        if let text = value as? String { return text }
        return "\(value)"
    }

    // MARK: - TOML 私有（段落手术规则照 CodexProfileEditor）

    /// 段头 → 路径分量（`[mcp_servers."my name".env]` → ["mcp_servers","my name","env"]）。
    /// 与索引器同款限制：引号段名内含 `.` 会被误拆（实勘无此形态，best-effort）。
    private static func headerPath(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else { return nil }
        let inner = trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
        guard !inner.isEmpty else { return nil }
        return inner.split(separator: ".").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }
    }

    /// 全部 `[mcp_servers.<name>]` 主段（不含子段）的名字 → 行号
    private static func sectionRanges(in lines: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count == 2,
                  path[0] == "mcp_servers" else { continue }
            if result[path[1]] == nil { result[path[1]] = index }
        }
        return result
    }

    /// 定位主段（subsection = nil）或指定子段（如 "env"）的 [段头, 下一段头) 行区间
    private static func sectionRange(
        in lines: [String], name: String, subsection: String?
    ) -> Range<Int>? {
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count >= 2,
                  path[0] == "mcp_servers", path[1] == name else { continue }
            let matches = subsection == nil
                ? path.count == 2
                : (path.count == 3 && path[2] == subsection)
            guard matches else { continue }
            var end = index + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end += 1
            }
            return index..<end
        }
        return nil
    }

    /// 第一个属于该 server 的段（主段或任意子段）的 [段头, 下一段头) 行区间
    private static func firstSectionRange(
        in lines: [String], matching name: String
    ) -> Range<Int>? {
        for (index, line) in lines.enumerated() {
            guard let path = headerPath(line), path.count >= 2,
                  path[0] == "mcp_servers", path[1] == name else { continue }
            var end = index + 1
            while end < lines.count,
                  !lines[end].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                end += 1
            }
            return index..<end
        }
        return nil
    }

    private static func headerLine(name: String, subsection: String? = nil) -> String {
        let bare = name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        let segment = bare && !name.isEmpty ? name : "\"\(escape(name))\""
        let suffix = subsection.map { ".\($0)" } ?? ""
        return "[mcp_servers.\(segment)\(suffix)]"
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func unquote(_ text: String) -> String {
        var value = text
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote)
            && value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }

    /// 单行数组 `["-y", "pkg"]` → 元素（多行形态由调用方拼接后再进来）
    private static func inlineArrayStrings(_ value: String) -> [String] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("[") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("]") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").map {
            unquote(String($0).trimmingCharacters(in: .whitespaces))
        }.filter { !$0.isEmpty }
    }

    /// 数组字面量是否已闭合：引号外的 `]` 才算（引号内是元素内容）；
    /// 引号内 `\"` 转义不翻转引号态。与 MCPConfigIndexer 的同款手法（模块不互相依赖）
    private static func arrayLiteralClosed(_ value: String) -> Bool {
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

    /// 单行内联表 `{ A = "x", B = "y" }` → 键值对（这里**要**值：传播需要完整定义）
    private static func inlineTablePairs(_ value: String) -> [(String, String)] {
        var inner = value.trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("{") else { return [] }
        inner = String(inner.dropFirst())
        if inner.hasSuffix("}") { inner = String(inner.dropLast()) }
        return inner.split(separator: ",").compactMap { piece in
            let pair = String(piece)
            guard let eq = pair.firstIndex(of: "=") else { return nil }
            let key = unquote(String(pair[..<eq]).trimmingCharacters(in: .whitespaces))
            let val = unquote(String(pair[pair.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces))
            return key.isEmpty ? nil : (key, val)
        }
    }
}
