import EurekaKit
import Foundation

/// The **pure logic layer** for MCP server connection checks: status classification, initialize
/// handshake response parsing, tools/list parsing and stdio command resolution. Network requests
/// are made in the app layer (MCPService), and only when the user clicks; never probed
/// automatically.
///
/// Aligned with the MCP protocol definition: a server is an endpoint that exposes tools/resources/prompts
/// after negotiating capabilities via `initialize`. So "connected" must mean **the handshake succeeded**;
/// looking only at HTTP 200 would misjudge any website as an MCP server (the v1 bug). Now a 2xx must also
/// yield a parseable `result.protocolVersion`.
public enum MCPProbe {
    /// The latest **finalized** protocol version our implementation aligns with (officially
    /// released 2026-07-28: stateless core, multi-round requests, header version negotiation).
    /// initialize reports this version and records whatever the server negotiates down to (old
    /// servers answering with an old version still connect); later requests carry the
    /// `MCP-Protocol-Version: <negotiated version>` header per spec. The classic handshake sequence
    /// stays compatible with the new spec; stateless core's single-request capability discovery is
    /// a follow-up and does not affect probe correctness.
    public static let latestProtocolVersion = "2026-07-28"

    /// The server's self-description returned by the initialize handshake (serverInfo +
    /// capabilities in the protocol definition)
    public struct HandshakeInfo: Equatable, Sendable {
        public var serverName: String?
        public var serverVersion: String?
        public var protocolVersion: String?
        /// Capability key names (tools / resources / prompts / logging…), sorted
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

        /// One-line summary (subtitle of the detail row): "v1.2 · Protocol 2025-03-26 ·
        /// Capabilities tools, prompts"
        public var summary: String {
            var parts: [String] = []
            if let version = serverVersion, !version.isEmpty { parts.append("v\(version)") }
            if let proto = protocolVersion, !proto.isEmpty { parts.append(L10n.format("Protocol %@", zhHans: "协议 %@", String(proto))) }
            if !capabilities.isEmpty {
                parts.append(L10n.format("Capabilities %@", zhHans: "能力 %@", String(capabilities.joined(separator: ", "))))
            }
            return parts.joined(separator: " · ")
        }
    }

    public enum Status: Equatable, Sendable {
        /// Handshake succeeded (2xx and the response yields a protocolVersion)
        case connected(HandshakeInfo)
        /// 2xx but the response is not an MCP initialize result: the endpoint is reachable but the
        /// URL/transport is most likely misconfigured
        case notMCP
        /// 401 / 403: credentials missing or expired; authServer = the OAuth metadata URL from
        /// WWW-Authenticate
        case unauthorized(code: Int, authServer: String?)
        /// Any other HTTP status (404/5xx…)
        case httpError(Int)
        /// Transport-level failure (offline / DNS / timeout)
        case unreachable(String)
        /// stdio: the command resolved to an executable (associated value = actual path)
        case commandFound(String)
        /// stdio: no executable found on PATH or at the absolute path
        case commandMissing

        public var label: String {
            switch self {
            case .connected: return L10n.text("Connected", zhHans: "已连接")
            case .notMCP: return L10n.text("Not an MCP endpoint", zhHans: "非 MCP 端点")
            case .unauthorized: return L10n.text("Authorization required", zhHans: "需要授权")
            case .httpError(let code): return L10n.format("Error %@", zhHans: "异常 %@", String(code))
            case .unreachable: return L10n.text("Unreachable", zhHans: "不可达")
            case .commandFound: return L10n.text("Command available", zhHans: "命令可用")
            case .commandMissing: return L10n.text("Command missing", zhHans: "命令缺失")
            }
        }

        /// Semantic color (UI mapping: ok=green / warning=gold / bad=red)
        public enum Tone: Equatable, Sendable { case ok, warning, bad }
        public var tone: Tone {
            switch self {
            case .connected, .commandFound: return .ok
            case .unauthorized, .notMCP: return .warning
            case .httpError, .unreachable, .commandMissing: return .bad
            }
        }

        /// Guidance text under the row (points to next steps when authorization is needed / the
        /// endpoint is not MCP)
        public var hint: String? {
            switch self {
            case .unauthorized(_, let authServer):
                if let authServer {
                    return L10n.format("This server uses OAuth (metadata: %@).", zhHans: "该 server 走 OAuth 授权（元数据: %@）——", String(authServer))
                        + L10n.text(" Authorize in the corresponding CLI (codex mcp login / Claude's /mcp)", zhHans: "请到对应 CLI 完成授权（codex mcp login / Claude 的 /mcp）")
                }
                return L10n.text("No OAuth metadata was published; this likely uses API key/header authentication.", zhHans: "未公布 OAuth 元数据，多半是 API key/请求头鉴权——")
                    + L10n.text(" Use “Edit headers” to enter or update the key. For OAuth-managed servers,", zhHans: "用「编辑请求头」填入或更新密钥；确为 OAuth 托管的")
                    + L10n.text(" reauthorize in the corresponding CLI (for example, /mcp in Claude Code)", zhHans: "请在对应 CLI 内重新授权（如 Claude Code 输入 /mcp）")
            case .notMCP:
                return L10n.text("The endpoint returned a non-MCP response. Check the URL (a webpage may have been entered instead of an /mcp endpoint)", zhHans: "端点返回了非 MCP 响应——检查 URL 是否正确（常见于填了网页地址而非 /mcp 端点）")
            default:
                return nil
            }
        }
    }

    // MARK: - Status classification (single entry point, pure and testable)

    /// 2xx → parse the handshake (success connected / failure notMCP); 401/403 → needs
    /// authorization (with OAuth metadata); everything else is reported as an error.
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

    /// initialize response → handshake info (supports both plain JSON and text/event-stream
    /// payloads). If `result.protocolVersion` cannot be parsed, it is judged "not MCP".
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

    /// Display info for a single tool (2025-11-25: title / description / annotations /
    /// outputSchema)
    public struct ToolInfo: Equatable, Sendable {
        public var name: String
        public var title: String?
        public var description: String?
        /// annotations.readOnlyHint (an untrusted hint, display only)
        public var readOnly: Bool?
        /// annotations.destructiveHint
        public var destructive: Bool?
        /// Whether a structured output schema is declared
        public var hasOutputSchema: Bool
        /// Parameter names from inputSchema.properties (required ones get a `*` suffix; names only,
        /// schema bodies are not stored)
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

    /// Generic entry for prompts/resources (name + description; nothing else is read)
    public struct NamedItem: Equatable, Sendable {
        public var name: String
        public var description: String?

        public init(name: String, description: String? = nil) {
            self.name = name
            self.description = description
        }
    }

    /// tools/list response → tool list (with title/description/annotations) + pagination cursor;
    /// returns nil on parse failure. A non-empty `nextCursor` means there is another page
    /// (2025-11-25 pagination semantics); the caller follows it.
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

    /// List parsing shared by resources/list and prompts/list (`result.<key>[].{name,description}`
    /// + cursor). Only names and descriptions are taken; bodies/URIs are never read (minimal
    ///   privacy surface).
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

    /// A Streamable HTTP response may be SSE: take the first `data:` line; plain JSON is returned
    /// as-is. Public so the app layer can reuse it (the tools/list schema text feeds token
    /// estimation).
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

    /// Parsed WWW-Authenticate challenge from a 401/403 (RFC 9728 + RFC 6750). `scopes` comes from
    /// the challenge's `scope` parameter, which the spec makes the **authoritative** scope source;
    /// authorization requests should prefer it over the AS metadata's scopes_supported.
    public struct Challenge: Equatable, Sendable {
        public var resourceMetadata: String?
        public var scopes: [String]

        public init(resourceMetadata: String? = nil, scopes: [String] = []) {
            self.resourceMetadata = resourceMetadata
            self.scopes = scopes
        }
    }

    /// The OAuth metadata URL in WWW-Authenticate (the MCP authorization spec uses RFC 9728's
    /// `resource_metadata` parameter; older implementations have also been seen using
    /// authorization_uri / as_uri)
    public static func parseWWWAuthenticate(_ header: String?) -> String? {
        guard let header else { return nil }
        for param in ["resource_metadata", "authorization_uri", "as_uri"] {
            if let value = challengeParameter(param, in: header) { return value }
        }
        return nil
    }

    /// Full challenge parsing: metadata URL + scope parameter (space-separated, multi-valued)
    public static func parseChallenge(_ header: String?) -> Challenge {
        let scopeText = header.flatMap { challengeParameter("scope", in: $0) } ?? ""
        return Challenge(
            resourceMetadata: parseWWWAuthenticate(header),
            scopes: scopeText.split(separator: " ").map(String.init))
    }

    /// Value of a single challenge parameter (quoted or bare)
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

    // MARK: - stdio command resolution

    /// stdio command resolution: absolute/relative paths are checked directly; a bare command is
    /// looked up as an executable directory by directory along PATH. This function is **pure
    /// syscalls and spawns no process**; it only judges reachability. Actually launching the
    /// process to read its capability list is `MCPStdioProbe`'s job (since v2.8, and only when the
    /// user clicks "Re-check").
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

    // MARK: - Request bodies (JSON-RPC 2.0)

    /// MCP `initialize` probe request body (reports the latest finalized version; records whatever
    /// the server negotiates down to)
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

    /// Handshake-complete notification (the spec requires sending it before other requests; a
    /// notification without an id)
    public static func initializedNotificationBody() -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// tools/list request body (a non-empty cursor fetches the next page)
    public static func toolsListRequestBody(cursor: String? = nil) -> Data {
        listRequestBody(method: "tools/list", id: 2, cursor: cursor)
    }

    /// resources/list request body (only for counting, so the first page is enough)
    public static func resourcesListRequestBody(cursor: String? = nil) -> Data {
        listRequestBody(method: "resources/list", id: 3, cursor: cursor)
    }

    /// prompts/list request body (only for counting, so the first page is enough)
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
