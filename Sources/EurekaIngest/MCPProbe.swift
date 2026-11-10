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
    /// The protocol has two eras and the probe speaks both (`MCPInspector` picks one per server):
    ///
    /// - **Modern** (2026-07-28 onwards): stateless. There is no handshake and no session; every
    ///   request carries its protocol version and client capabilities in `params._meta`, and
    ///   `server/discover` replaces `initialize`.
    /// - **Handshake** (2024-11-05 … 2025-11-25): `initialize` negotiates a version (the server
    ///   answers with its own when it does not support ours), then `notifications/initialized`,
    ///   then requests carrying the negotiated `MCP-Protocol-Version` header (2025-06-18+).
    ///
    /// Fields grew across revisions (tool annotations 2025-03-26; `title` / `outputSchema`
    /// 2025-06-18; `serverInfo.description` 2025-11-25), so every parser here treats them as
    /// optional and never rejects a response for lacking one.
    public static let modernProtocolVersion = "2026-07-28"
    /// The newest handshake-era revision; what `initialize` offers
    public static let handshakeProtocolVersion = "2025-11-25"
    /// The latest revision the probe aligns with
    public static let latestProtocolVersion = modernProtocolVersion

    /// A revision at or after the stateless redesign (revisions are ISO dates, so string order is
    /// date order)
    public static func isModern(_ version: String) -> Bool {
        version >= modernProtocolVersion
    }

    /// The server's self-description returned by the initialize handshake (serverInfo +
    /// capabilities in the protocol definition)
    public struct HandshakeInfo: Equatable, Sendable {
        public var serverName: String?
        public var serverVersion: String?
        public var protocolVersion: String?
        /// Capability key names (tools / resources / prompts / logging…), sorted
        public var capabilities: [String]
        /// `serverInfo.title`: the human-readable display name (2025-06-18+)
        public var serverTitle: String?
        /// `result.instructions`: the server's own description of what it offers and how to use
        /// it. Untrusted text from the server; display only.
        public var instructions: String?

        public init(
            serverName: String? = nil, serverVersion: String? = nil,
            protocolVersion: String? = nil, capabilities: [String] = [],
            serverTitle: String? = nil, instructions: String? = nil
        ) {
            self.serverName = serverName
            self.serverVersion = serverVersion
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.serverTitle = serverTitle
            self.instructions = instructions
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
            capabilities: capabilities,
            serverTitle: nonBlank(serverInfo?["title"] as? String),
            instructions: nonBlank(result["instructions"] as? String))
    }

    /// `server/discover` response → handshake info (modern era). `requested` is the version the
    /// request declared, which is what later requests keep using. nil when the response is not a
    /// DiscoverResult (`result.supportedVersions` is its distinguishing field).
    public static func parseDiscoverResponse(
        _ data: Data, contentType: String?, requested: String
    ) -> HandshakeInfo? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let supported = result["supportedVersions"] as? [String], !supported.isEmpty
        else { return nil }
        let meta = result["_meta"] as? [String: Any]
        let serverInfo = (meta?["io.modelcontextprotocol/serverInfo"] as? [String: Any])
            ?? (result["serverInfo"] as? [String: Any])
        let capabilities = (result["capabilities"] as? [String: Any])?.keys.sorted() ?? []
        return HandshakeInfo(
            serverName: serverInfo?["name"] as? String,
            serverVersion: serverInfo?["version"] as? String,
            protocolVersion: supported.contains(requested) ? requested : supported.max(),
            capabilities: capabilities,
            serverTitle: nonBlank(serverInfo?["title"] as? String),
            instructions: nonBlank(result["instructions"] as? String))
    }

    /// A JSON-RPC error as far as version negotiation cares
    public struct RPCError: Equatable, Sendable {
        public var code: Int?
        public var message: String?
        /// `error.data.supported`: the revisions the server says it speaks. Sent with
        /// `UnsupportedProtocolVersion` (-32022) by modern servers and, by convention, with
        /// -32602 by handshake-era ones.
        public var supportedVersions: [String]

        /// The codes only a modern server uses (HeaderMismatch, MissingRequiredClientCapability,
        /// UnsupportedProtocolVersion). The spec forbids keying the legacy fallback on any one
        /// code, so everything outside this set means "not recognizably modern".
        public var isRecognizedModern: Bool {
            guard let code else { return false }
            return (-32022 ... -32020).contains(code)
        }
    }

    public static func parseRPCError(_ data: Data, contentType: String?) -> RPCError? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        let supported = ((error["data"] as? [String: Any])?["supported"] as? [String]) ?? []
        return RPCError(
            code: error["code"] as? Int,
            message: nonBlank(error["message"] as? String),
            supportedVersions: supported)
    }

    /// `result.resultType` (2026-07-28). Absent means "complete" — that is how every earlier
    /// revision answers.
    public static func resultType(_ data: Data, contentType: String?) -> String {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let type = result["resultType"] as? String
        else { return "complete" }
        return type
    }

    private static func nonBlank(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// One input parameter of a tool (name / JSON type / required / description). The schema body
    /// itself is still never kept.
    public struct ParamInfo: Equatable, Sendable {
        public var name: String
        /// `type` from the property schema; a union is joined with " | "; nil when undeclared
        public var type: String?
        public var required: Bool
        public var description: String?

        public init(
            name: String, type: String? = nil, required: Bool = false,
            description: String? = nil
        ) {
            self.name = name
            self.type = type
            self.required = required
            self.description = description
        }
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
        /// The same parameters with type and description, sorted by name
        public var paramDetails: [ParamInfo]

        public init(
            name: String, title: String? = nil, description: String? = nil,
            readOnly: Bool? = nil, destructive: Bool? = nil, hasOutputSchema: Bool = false,
            params: [String] = [], paramDetails: [ParamInfo] = []
        ) {
            self.name = name
            self.title = title
            self.description = description
            self.readOnly = readOnly
            self.destructive = destructive
            self.hasOutputSchema = hasOutputSchema
            self.params = params
            self.paramDetails = paramDetails
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
            let properties = (schema?["properties"] as? [String: Any]) ?? [:]
            let params = properties.keys.sorted()
                .map { required.contains($0) ? $0 + "*" : $0 }
            let paramDetails = properties.keys.sorted().map { key -> ParamInfo in
                let property = properties[key] as? [String: Any]
                let type = (property?["type"] as? String)
                    ?? (property?["type"] as? [String])?.joined(separator: " | ")
                return ParamInfo(
                    name: key, type: type, required: required.contains(key),
                    description: nonBlank(property?["description"] as? String))
            }
            return ToolInfo(
                name: name,
                title: tool["title"] as? String,
                description: tool["description"] as? String,
                readOnly: annotations?["readOnlyHint"] as? Bool,
                destructive: annotations?["destructiveHint"] as? Bool,
                hasOutputSchema: tool["outputSchema"] != nil,
                params: params, paramDetails: paramDetails)
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

    /// A Streamable HTTP response may be SSE: plain JSON is returned as-is; from an event stream
    /// the first event that is a JSON-RPC **response** (carries `result` or `error`) wins, because
    /// a server may send notifications or its own requests on the stream before answering. With
    /// no such event the first one is returned, so callers still see what arrived. A 2025-03-26
    /// batch (a JSON array) is reduced to its first response the same way. Public so the app layer
    /// can reuse it (the tools/list schema text feeds token estimation).
    public static func extractJSONPayload(_ data: Data, contentType: String?) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let isSSE = (contentType?.lowercased().contains("text/event-stream") ?? false)
            || text.hasPrefix("event:") || text.hasPrefix("data:")
        guard isSSE else { return firstResponse(inBatch: data) ?? data }
        var parser = MCPSSEParser()
        let events = parser.feed(data) + parser.finish()
        var first: Data?
        for event in events where !event.data.isEmpty {
            let json = Data(event.data.utf8)
            let candidate = firstResponse(inBatch: json) ?? json
            if first == nil { first = candidate }
            if isResponse(candidate) { return candidate }
        }
        return first
    }

    private static func isResponse(_ json: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any]
        else { return false }
        return root["result"] != nil || root["error"] != nil
    }

    /// JSON-RPC batching existed only in 2025-03-26: a batch body is an array of messages
    private static func firstResponse(inBatch json: Data) -> Data? {
        guard json.first(where: { !$0.isASCIIWhitespace }) == UInt8(ascii: "["),
              let batch = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]],
              let response = batch.first(where: { $0["result"] != nil || $0["error"] != nil })
        else { return nil }
        return try? JSONSerialization.data(withJSONObject: response)
    }

    /// `error.message` of a JSON-RPC error response, for telling the user why a list call failed
    public static func parseErrorMessage(_ data: Data, contentType: String?) -> String? {
        guard let payload = extractJSONPayload(data, contentType: contentType),
              let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
              let error = root["error"] as? [String: Any]
        else { return nil }
        return nonBlank(error["message"] as? String)
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
        workingDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("/") {
            var expanded = (trimmed as NSString).expandingTildeInPath
            // A relative path in a project-scoped config is relative to that project
            if !expanded.hasPrefix("/"), let workingDirectory {
                expanded = workingDirectory.appendingPathComponent(expanded).standardizedFileURL.path
            }
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

    /// JSON-RPC ids the probe uses, one per method (pagination reuses the method's id: requests
    /// are strictly sequential)
    public enum RequestID {
        public static let initialize = 1
        public static let toolsList = 2
        public static let resourcesList = 3
        public static let promptsList = 4
        public static let discover = 10
    }

    private static let clientInfo: [String: Any] = ["name": "eureka-probe", "version": "1.0"]

    /// The per-request metadata every modern request must carry (protocol version and client
    /// capabilities are required, client info is recommended)
    private static func modernMeta(_ version: String) -> [String: Any] {
        [
            "io.modelcontextprotocol/protocolVersion": version,
            "io.modelcontextprotocol/clientInfo": clientInfo,
            "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        ]
    }

    /// `server/discover` (modern era): the single request that replaces the handshake
    public static func discoverRequestBody(version: String = modernProtocolVersion) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": RequestID.discover,
            "method": "server/discover",
            "params": ["_meta": modernMeta(version)],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// MCP `initialize` request body (handshake era). Offers the newest handshake revision by
    /// default; the server answers with whatever it negotiates down to.
    public static func initializeRequestBody(
        version: String = handshakeProtocolVersion
    ) -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": RequestID.initialize,
            "method": "initialize",
            "params": [
                "protocolVersion": version,
                "capabilities": [String: Any](),
                "clientInfo": clientInfo,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// Handshake-complete notification (the spec requires sending it before other requests; a
    /// notification without an id). Handshake era only.
    public static func initializedNotificationBody() -> Data {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    /// tools/list request body (a non-empty cursor fetches the next page). `modernVersion` set =
    /// modern era: the request carries `_meta`; nil = handshake era, no `_meta`.
    public static func toolsListRequestBody(
        cursor: String? = nil, modernVersion: String? = nil
    ) -> Data {
        listRequestBody(
            method: "tools/list", id: RequestID.toolsList, cursor: cursor,
            modernVersion: modernVersion)
    }

    /// resources/list request body (only for counting, so the first page is enough)
    public static func resourcesListRequestBody(
        cursor: String? = nil, modernVersion: String? = nil
    ) -> Data {
        listRequestBody(
            method: "resources/list", id: RequestID.resourcesList, cursor: cursor,
            modernVersion: modernVersion)
    }

    /// prompts/list request body (only for counting, so the first page is enough)
    public static func promptsListRequestBody(
        cursor: String? = nil, modernVersion: String? = nil
    ) -> Data {
        listRequestBody(
            method: "prompts/list", id: RequestID.promptsList, cursor: cursor,
            modernVersion: modernVersion)
    }

    private static func listRequestBody(
        method: String, id: Int, cursor: String?, modernVersion: String?
    ) -> Data {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
        ]
        var params: [String: Any] = [:]
        if let cursor { params["cursor"] = cursor }
        if let modernVersion { params["_meta"] = modernMeta(modernVersion) }
        if !params.isEmpty { payload["params"] = params }
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }
}

private extension UInt8 {
    var isASCIIWhitespace: Bool { self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D }
}
