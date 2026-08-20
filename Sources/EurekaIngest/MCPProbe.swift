import Foundation

/// MCP server 连接检测的**纯逻辑层**：状态分类、initialize 握手响应解析、
/// tools/list 解析与 stdio 命令解析。网络请求在 app 层（MCPService）发起——
/// 且只在用户点击时发起，绝不自动探测。
///
/// 与 MCP 协议定义对齐：server = 经 `initialize` 协商能力后暴露 tools/resources/prompts
/// 的端点。所以"已连接"必须以**握手成功**为准 —— 只看 HTTP 200 会把任意网站误判为
/// MCP server（v1 的毛病），现在 2xx 还要能解析出 `result.protocolVersion` 才算。
public enum MCPProbe {
    /// 我们实现所对齐的最新**定稿**协议版本（2026-07-28 尚为 release candidate，不追）。
    /// initialize 报此版本，server 协商回落什么就记录什么；后续请求按规范带
    /// `MCP-Protocol-Version: <协商版本>` 头。
    public static let latestProtocolVersion = "2025-11-25"

    /// initialize 握手取回的 server 自述（协议定义里的 serverInfo + capabilities）
    public struct HandshakeInfo: Equatable, Sendable {
        public var serverName: String?
        public var serverVersion: String?
        public var protocolVersion: String?
        /// capabilities 的键名（tools / resources / prompts / logging…），排序后
        public var capabilities: [String]

        public init(
            serverName: String? = nil, serverVersion: String? = nil,
            protocolVersion: String? = nil, capabilities: [String] = []
        ) {
            self.serverName = serverName
            self.serverVersion = serverVersion
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
        }

        /// 一行摘要（详情行副标题用）："v1.2 · 协议 2025-03-26 · 能力 tools, prompts"
        public var summary: String {
            var parts: [String] = []
            if let version = serverVersion, !version.isEmpty { parts.append("v\(version)") }
            if let proto = protocolVersion, !proto.isEmpty { parts.append("协议 \(proto)") }
            if !capabilities.isEmpty {
                parts.append("能力 \(capabilities.joined(separator: ", "))")
            }
            return parts.joined(separator: " · ")
        }
    }

    public enum Status: Equatable, Sendable {
        /// 握手成功（2xx 且响应解析出 protocolVersion）
        case connected(HandshakeInfo)
        /// 2xx 但响应不是 MCP initialize 结果——端点可达但多半配错了 URL/传输方式
        case notMCP
        /// 401 / 403：凭证缺失或过期；authServer = WWW-Authenticate 里的 OAuth 元数据地址
        case unauthorized(code: Int, authServer: String?)
        /// 其它 HTTP 状态（404/5xx…）
        case httpError(Int)
        /// 传输层失败（断网 / DNS / 超时）
        case unreachable(String)
        /// stdio：命令已解析到可执行文件（关联值 = 实际路径）
        case commandFound(String)
        /// stdio：PATH 与绝对路径都找不到可执行文件
        case commandMissing

        public var label: String {
            switch self {
            case .connected: return "已连接"
            case .notMCP: return "非 MCP 端点"
            case .unauthorized: return "需要授权"
            case .httpError(let code): return "异常 \(code)"
            case .unreachable: return "不可达"
            case .commandFound: return "命令可用"
            case .commandMissing: return "命令缺失"
            }
        }

        /// 语义色（UI 映射：ok=绿 / warning=金 / bad=红）
        public enum Tone: Equatable, Sendable { case ok, warning, bad }
        public var tone: Tone {
            switch self {
            case .connected, .commandFound: return .ok
            case .unauthorized, .notMCP: return .warning
            case .httpError, .unreachable, .commandMissing: return .bad
            }
        }

        /// 行下引导文案（需要授权 / 非 MCP 端点时给动线）
        public var hint: String? {
            switch self {
            case .unauthorized(_, let authServer):
                if let authServer {
                    return "该 server 走 OAuth 授权（元数据: \(authServer)）——"
                        + "请到对应 CLI 完成授权（codex mcp login / Claude 的 /mcp）"
                }
                return "未公布 OAuth 元数据，多半是 API key/请求头鉴权——"
                    + "用「编辑请求头」填入或更新密钥；确为 OAuth 托管的"
                    + "请在对应 CLI 内重新授权（如 Claude Code 输入 /mcp）"
            case .notMCP:
                return "端点返回了非 MCP 响应——检查 URL 是否正确（常见于填了网页地址而非 /mcp 端点）"
            default:
                return nil
            }
        }
    }

    // MARK: - 状态分类（唯一入口，纯函数可测）

    /// 2xx → 解析握手（成功 connected / 失败 notMCP）；401/403 → 需授权（附 OAuth 元数据）；
    /// 其余按异常报。
    public static func classify(
        statusCode: Int, body: Data? = nil, contentType: String? = nil,
        wwwAuthenticate: String? = nil
    ) -> Status {
        switch statusCode {
        case 200...299:
            if let body, let info = parseInitializeResponse(body, contentType: contentType) {
                return .connected(info)
            }
            return .notMCP
        case 401, 403:
            return .unauthorized(
                code: statusCode, authServer: parseWWWAuthenticate(wwwAuthenticate))
        default:
            return .httpError(statusCode)
        }
    }

    /// initialize 响应 → 握手信息（支持纯 JSON 与 text/event-stream 两种载荷）。
    /// 解析不出 `result.protocolVersion` 即判定"不是 MCP"。
    public static func parseInitializeResponse(
        _ data: Data, contentType: String?
    ) -> HandshakeInfo? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let protocolVersion = result["protocolVersion"] as? String
        else { return nil }
        let serverInfo = result["serverInfo"] as? [String: Any]
        let capabilities = (result["capabilities"] as? [String: Any])?.keys.sorted() ?? []
        return HandshakeInfo(
            serverName: serverInfo?["name"] as? String,
            serverVersion: serverInfo?["version"] as? String,
            protocolVersion: protocolVersion,
            capabilities: capabilities)
    }

    /// 单个 tool 的展示信息（2025-11-25：title / description / annotations / outputSchema）
    public struct ToolInfo: Equatable, Sendable {
        public var name: String
        public var title: String?
        public var description: String?
        /// annotations.readOnlyHint（不可信提示，仅作展示）
        public var readOnly: Bool?
        /// annotations.destructiveHint
        public var destructive: Bool?
        /// 是否声明了结构化输出 schema
        public var hasOutputSchema: Bool
        /// inputSchema.properties 的参数名（必填的带 `*` 后缀；只取名字，不存 schema 正文）
        public var params: [String]

        public init(
            name: String, title: String? = nil, description: String? = nil,
            readOnly: Bool? = nil, destructive: Bool? = nil, hasOutputSchema: Bool = false,
            params: [String] = []
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.readOnly = readOnly
            self.destructive = destructive
            self.hasOutputSchema = hasOutputSchema
            self.params = params
        }
    }

    /// prompts/resources 的通用条目（名字 + 描述，别的一概不读）
    public struct NamedItem: Equatable, Sendable {
        public var name: String
        public var description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    /// tools/list 响应 → 工具清单（含 title/描述/注解）+ 分页游标；解析失败返回 nil。
    /// `nextCursor` 非空说明还有下一页（2025-11-25 分页语义），调用方跟随之。
    public static func parseToolsList(
        _ data: Data, contentType: String?
    ) -> (tools: [ToolInfo], nextCursor: String?)? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]]
        else { return nil }
        let parsed = tools.compactMap { tool -> ToolInfo? in
            guard let name = tool["name"] as? String else { return nil }
            let annotations = tool["annotations"] as? [String: Any]
            let schema = tool["inputSchema"] as? [String: Any]
            let required = Set((schema?["required"] as? [String]) ?? [])
            let params = ((schema?["properties"] as? [String: Any])?.keys.sorted() ?? [])
                .map { required.contains($0) ? $0 + "*" : $0 }
            return ToolInfo(
                name: name,
                title: tool["title"] as? String,
                description: tool["description"] as? String,
                readOnly: annotations?["readOnlyHint"] as? Bool,
                destructive: annotations?["destructiveHint"] as? Bool,
                hasOutputSchema: tool["outputSchema"] != nil,
                params: params)
        }
        return (parsed, result["nextCursor"] as? String)
    }

    /// resources/list、prompts/list 共用的清单解析（`result.<key>[].{name,description}`
    /// + 游标）。只取名字与描述——正文/URI 一概不读（隐私面最小化）。
    public static func parseNamedList(
        _ data: Data, contentType: String?, key: String
    ) -> (items: [NamedItem], nextCursor: String?)? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let items = result[key] as? [[String: Any]]
        else { return nil }
        let parsed = items.compactMap { item -> NamedItem? in
            guard let name = item["name"] as? String else { return nil }
            return NamedItem(name: name, description: item["description"] as? String)
        }
        return (parsed, result["nextCursor"] as? String)
    }

    /// Streamable HTTP 的响应可能是 SSE：取第一条 `data:` 行；纯 JSON 原样返回。
    /// 公开给 app 层复用（tools/list 的 schema 文本要拿去做 token 估算）。
    public static func extractJSONPayload(_ data: Data, contentType: String?) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let isSSE = (contentType?.lowercased().contains("text/event-stream") ?? false)
            || text.hasPrefix("event:") || text.hasPrefix("data:")
        guard isSSE else { return data }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("data:") {
                let json = trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces)
                return Data(json.utf8)
            }
        }
        return nil
    }

    /// 401/403 的 WWW-Authenticate 质询解析结果（RFC 9728 + RFC 6750）。
    /// `scopes` 来自质询的 `scope` 参数——规范定其为**权威** scope 来源，
    /// 授权请求应优先于 AS 元数据的 scopes_supported 使用之。
    public struct Challenge: Equatable, Sendable {
        public var resourceMetadata: String?
        public var scopes: [String]

        public init(resourceMetadata: String? = nil, scopes: [String] = []) {
            self.resourceMetadata = resourceMetadata
            self.scopes = scopes
        }
    }

    /// WWW-Authenticate 里的 OAuth 元数据地址（MCP 授权规范用 RFC 9728 的
    /// `resource_metadata` 参数；旧实现也见过 authorization_uri / as_uri）
    public static func parseWWWAuthenticate(_ header: String?) -> String? {
        guard let header else { return nil }
        for param in ["resource_metadata", "authorization_uri", "as_uri"] {
            if let value = challengeParameter(param, in: header) { return value }
        }
        return nil
    }

    /// 完整质询解析：元数据地址 + scope 参数（空格分隔多值）
    public static func parseChallenge(_ header: String?) -> Challenge {
        let scopeText = header.flatMap { challengeParameter("scope", in: $0) } ?? ""
        return Challenge(
            resourceMetadata: parseWWWAuthenticate(header),
            scopes: scopeText.split(separator: " ").map(String.init))
    }

    /// 质询里单个参数取值（带引号或裸值皆可）
    private static func challengeParameter(_ name: String, in header: String) -> String? {
        guard !header.isEmpty, let range = header.range(of: name + "=") else { return nil }
        var rest = String(header[range.upperBound...])
        if rest.hasPrefix("\"") {
            rest = String(rest.dropFirst())
            if let end = rest.firstIndex(of: "\"") { return String(rest[..<end]) }
            return nil
        }
        if let value = rest.split(separator: ",").first {
            return String(value).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    // MARK: - stdio 命令解析

    /// stdio 命令解析：绝对/相对路径直接查；裸命令按 PATH 逐目录找可执行文件。
    /// 本函数**纯 syscall，不 spawn 进程**——只判可达性。真正启动进程读取能力清单
    /// 的是 `MCPStdioProbe`（v2.8 起，仅在用户点击「重新检测」时发生）。
    public static func resolveCommand(
        _ command: String,
        pathVariable: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            let expanded = (trimmed as NSString).expandingTildeInPath
            return fileManager.isExecutableFile(atPath: expanded) ? expanded : nil
        }
        for dir in pathVariable.split(separator: ":") where !dir.isEmpty {
            let candidate = URL(fileURLWithPath: String(dir))
                .appendingPathComponent(trimmed).path
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 请求体（JSON-RPC 2.0）

    /// MCP `initialize` 探测请求体（报最新定稿版本，server 协商回落什么记什么）
    public static func initializeRequestBody() -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": latestProtocolVersion,
                "capabilities": [:],
                "clientInfo": ["name": "eureka-probe", "version": "1.0"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// 握手完成通知（规范要求在其它请求前发送；无 id 的通知）
    public static func initializedNotificationBody() -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// tools/list 请求体（cursor 非空即取下一页）
    public static func toolsListRequestBody(cursor: String? = nil) -> Data {
        listRequestBody(method: "tools/list", id: 2, cursor: cursor)
    }

    /// resources/list 请求体（只为计数，取第一页即可）
    public static func resourcesListRequestBody(cursor: String? = nil) -> Data {
        listRequestBody(method: "resources/list", id: 3, cursor: cursor)
    }

    /// prompts/list 请求体（只为计数，取第一页即可）
    public static func promptsListRequestBody(cursor: String? = nil) -> Data {
        listRequestBody(method: "prompts/list", id: 4, cursor: cursor)
    }

    private static func listRequestBody(method: String, id: Int, cursor: String?) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        if let cursor {
            payload["params"] = ["cursor": cursor]
        }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}
