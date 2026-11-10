import EurekaKit
import Foundation

/// One request/response exchange with an MCP server, whatever carries it (a stdio child process,
/// Streamable HTTP, or the 2024-11-05 HTTP+SSE transport). `MCPInspector` drives the protocol on
/// top of this and knows nothing about the transport.
public protocol MCPInspectorChannel: AnyObject {
    /// Sends one message. A request (`id` set) blocks until its response, a failure or the
    /// timeout; a notification (`id` nil) returns as soon as it is sent and its reply is ignored.
    func send(_ request: MCPInspector.Request) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure>

    /// How long to wait for the `server/discover` answer before trying `initialize` as well; nil
    /// = the channel's normal timeout. A stdio server that predates the modern era may ignore the
    /// unknown request without answering at all, so stdio keeps this short.
    var discoverTimeout: TimeInterval? { get }

    /// The spec's fallback for a server that only speaks the deprecated HTTP+SSE transport: asked
    /// after `initialize` was rejected with 400 / 404 / 405. Returns true when the channel
    /// switched transports and the request is worth repeating.
    func fallBackToLegacyTransport() -> Bool
}

public extension MCPInspectorChannel {
    var discoverTimeout: TimeInterval? { nil }
    func fallBackToLegacyTransport() -> Bool { false }
}

/// Reads what an MCP server offers — its self-description and its tool / prompt / resource
/// lists — across every published protocol revision.
///
/// Era detection follows the 2026-07-28 backward-compatibility rules: probe with
/// `server/discover`; a DiscoverResult means a modern (stateless) server; a *recognized modern
/// error* means a modern server that wants another version (retry, never fall back); anything
/// else — any other error, an HTTP rejection, silence — means a handshake-era server, so fall back
/// to `initialize`. The fallback is deliberately not keyed to one error code. A modern-only server
/// that happens to be asked `initialize` names its versions in the error, which sends us back to
/// `server/discover`.
public enum MCPInspector {
    public struct Request: Sendable {
        public var body: Data
        public var method: String
        /// JSON-RPC id of the response to wait for; nil for a notification
        public var id: Int?
        /// Value for the `MCP-Protocol-Version` header: the declared version in the modern era,
        /// the negotiated one after a handshake, nil for the handshake itself
        public var protocolVersion: String?
        /// Modern-era request (HTTP adds `Mcp-Method` and sends no session id)
        public var modern: Bool
        /// Overrides the channel's normal timeout
        public var timeout: TimeInterval?

        public init(
            body: Data, method: String, id: Int?, protocolVersion: String? = nil,
            modern: Bool = false, timeout: TimeInterval? = nil
        ) {
            self.body = body
            self.method = method
            self.id = id
            self.protocolVersion = protocolVersion
            self.modern = modern
            self.timeout = timeout
        }
    }

    public struct Reply: Sendable {
        public var data: Data
        public var contentType: String?
        /// HTTP status; nil on stdio
        public var statusCode: Int?
        public var wwwAuthenticate: String?

        public init(
            data: Data, contentType: String? = nil, statusCode: Int? = nil,
            wwwAuthenticate: String? = nil
        ) {
            self.data = data
            self.contentType = contentType
            self.statusCode = statusCode
            self.wwwAuthenticate = wwwAuthenticate
        }

        var isHTTPSuccess: Bool { statusCode.map { (200...299).contains($0) } ?? true }
    }

    public enum ChannelFailure: Error, Equatable, Sendable {
        /// No response in time; the channel is still usable
        case timedOut
        /// The other side is gone (process exited, stream closed); nothing more can be sent
        case closed(String)
        /// Could not reach the server at all (DNS, refused, offline)
        case transport(String)
    }

    public struct Inspection: Equatable, Sendable {
        public var handshake: MCPProbe.HandshakeInfo
        public var tools: [MCPProbe.ToolInfo]
        public var prompts: [MCPProbe.NamedItem]
        public var resources: [MCPProbe.NamedItem]
        /// Sum of token estimates over all tools/list page payloads (≈ the per-turn schema cost)
        public var schemaTokens: Int
        /// The server connected but its tool list could not be read; `tools` is then empty and
        /// must not be mistaken for "this server has no tools"
        public var toolsError: String?

        public init(
            handshake: MCPProbe.HandshakeInfo, tools: [MCPProbe.ToolInfo] = [],
            prompts: [MCPProbe.NamedItem] = [], resources: [MCPProbe.NamedItem] = [],
            schemaTokens: Int = 0, toolsError: String? = nil
        ) {
            self.handshake = handshake
            self.tools = tools
            self.prompts = prompts
            self.resources = resources
            self.schemaTokens = schemaTokens
            self.toolsError = toolsError
        }
    }

    public enum Outcome: Equatable, Sendable {
        case inspected(Inspection)
        /// Never `.connected`
        case failed(MCPProbe.Status)
    }

    /// Which request opens the conversation. `.initialize` skips the modern probe: for a server
    /// that died on the unknown `server/discover` and is being given a second, handshake-only try.
    public enum Opening: Sendable { case discover, initialize }

    public static func inspect(
        _ channel: MCPInspectorChannel, opening: Opening = .discover
    ) -> Outcome {
        switch negotiate(channel, opening: opening) {
        case .failed(let status):
            return .failed(status)
        case .ready(let session):
            return .inspected(readLists(channel, session: session))
        }
    }

    // MARK: - Era detection and version negotiation

    private struct Session {
        var info: MCPProbe.HandshakeInfo
        /// Set in the modern era: the version every request declares
        var modernVersion: String?
        /// Header value for follow-up requests
        var headerVersion: String? { modernVersion ?? info.protocolVersion }
    }

    private enum Negotiation {
        case ready(Session)
        case failed(MCPProbe.Status)
    }

    private static func negotiate(
        _ channel: MCPInspectorChannel, opening: Opening
    ) -> Negotiation {
        var modernVersion = MCPProbe.modernProtocolVersion
        var handshakeVersion = MCPProbe.handshakeProtocolVersion
        var discoverAttempts = 0
        var initializeAttempts = 0
        var switchedTransport = false
        var step = opening
        var discoverTimeout = channel.discoverTimeout

        // Each branch either returns or moves to a step it has a bounded number of tries for
        for _ in 0..<8 {
            switch step {
            case .discover:
                discoverAttempts += 1
                let result = channel.send(Request(
                    body: MCPProbe.discoverRequestBody(version: modernVersion),
                    method: "server/discover", id: MCPProbe.RequestID.discover,
                    protocolVersion: modernVersion, modern: true, timeout: discoverTimeout))
                discoverTimeout = nil
                switch result {
                case .failure(.transport(let reason)), .failure(.closed(let reason)):
                    return .failed(.unreachable(reason))
                case .failure(.timedOut):
                    step = .initialize
                case .success(let reply):
                    if let code = reply.statusCode, code == 401 || code == 403 {
                        return .failed(classify(reply))
                    }
                    if reply.isHTTPSuccess, let info = MCPProbe.parseDiscoverResponse(
                        reply.data, contentType: reply.contentType, requested: modernVersion) {
                        return .ready(Session(
                            info: info, modernVersion: info.protocolVersion ?? modernVersion))
                    }
                    let error = MCPProbe.parseRPCError(reply.data, contentType: reply.contentType)
                    if let error, error.isRecognizedModern {
                        // A modern server: pick a version it lists, never fall back on this
                        let offered = error.supportedVersions
                            .filter { MCPProbe.isModern($0) && $0 != modernVersion }.max()
                        if let offered, discoverAttempts < 3 {
                            modernVersion = offered
                        } else if error.supportedVersions.contains(where: { !MCPProbe.isModern($0) }),
                                  initializeAttempts == 0 {
                            step = .initialize
                        } else {
                            return .failed(.unreachable(error.message ?? L10n.text(
                                "The server rejected every protocol version the probe speaks",
                                zhHans: "server 拒绝了探测支持的所有协议版本")))
                        }
                    } else {
                        step = .initialize
                    }
                }

            case .initialize:
                initializeAttempts += 1
                let result = channel.send(Request(
                    body: MCPProbe.initializeRequestBody(version: handshakeVersion),
                    method: "initialize", id: MCPProbe.RequestID.initialize))
                switch result {
                case .failure(.transport(let reason)), .failure(.closed(let reason)):
                    return .failed(.unreachable(reason))
                case .failure(.timedOut):
                    return .failed(.unreachable(L10n.text(
                        "Timed out waiting for the initialize response",
                        zhHans: "等待 initialize 响应超时")))
                case .success(let reply):
                    if reply.isHTTPSuccess, let info = MCPProbe.parseInitializeResponse(
                        reply.data, contentType: reply.contentType) {
                        _ = channel.send(Request(
                            body: MCPProbe.initializedNotificationBody(),
                            method: "notifications/initialized", id: nil,
                            protocolVersion: info.protocolVersion))
                        return .ready(Session(info: info, modernVersion: nil))
                    }
                    let error = MCPProbe.parseRPCError(reply.data, contentType: reply.contentType)
                    let supported = error?.supportedVersions ?? []
                    if let offered = supported.filter(MCPProbe.isModern).max(),
                       discoverAttempts < 3 {
                        // A modern-only server naming its versions in the initialize error
                        modernVersion = offered
                        step = .discover
                        continue
                    }
                    if let offered = supported
                        .filter({ !MCPProbe.isModern($0) && $0 != handshakeVersion }).max(),
                       initializeAttempts < 3 {
                        // A handshake-era server that rejects instead of negotiating down
                        handshakeVersion = offered
                        continue
                    }
                    if let code = reply.statusCode {
                        if [400, 404, 405].contains(code), !switchedTransport,
                           !(error?.isRecognizedModern ?? false),
                           channel.fallBackToLegacyTransport() {
                            switchedTransport = true
                            continue
                        }
                        return .failed(classify(reply))
                    }
                    return .failed(.unreachable(error?.message ?? L10n.text(
                        "The initialize response is not a valid MCP handshake",
                        zhHans: "initialize 响应不是合法 MCP 握手")))
                }
            }
        }
        return .failed(.unreachable(L10n.text(
            "Protocol version negotiation did not settle", zhHans: "协议版本协商未能收敛")))
    }

    /// HTTP reply → status, never `.connected` (a 2xx reaching here already failed to parse)
    private static func classify(_ reply: Reply) -> MCPProbe.Status {
        let status = MCPProbe.classify(
            statusCode: reply.statusCode ?? 0, body: nil, contentType: reply.contentType,
            wwwAuthenticate: reply.wwwAuthenticate)
        if case .connected = status { return .notMCP }
        return status
    }

    // MARK: - Lists

    private static func readLists(
        _ channel: MCPInspectorChannel, session: Session
    ) -> Inspection {
        let modernVersion = session.modernVersion
        var inspection = Inspection(handshake: session.info)

        /// One list page. `.failure` carries a reason fit to show the user.
        func page<T>(
            method: String, id: Int, body: Data, parse: (Data, String?) -> T?
        ) -> Result<(T, Reply), ListFailure> {
            let result = channel.send(Request(
                body: body, method: method, id: id,
                protocolVersion: session.headerVersion, modern: modernVersion != nil))
            switch result {
            case .failure(.timedOut):
                return .failure(ListFailure(L10n.format(
                    "%@ timed out", zhHans: "%@ 超时", method)))
            case .failure(.closed(let reason)), .failure(.transport(let reason)):
                return .failure(ListFailure(reason))
            case .success(let reply):
                if MCPProbe.resultType(reply.data, contentType: reply.contentType)
                    == "input_required" {
                    return .failure(ListFailure(L10n.format(
                        "%@ needs interactive input the probe cannot give",
                        zhHans: "%@ 需要探测无法提供的交互输入", method)))
                }
                if reply.isHTTPSuccess, let parsed = parse(reply.data, reply.contentType) {
                    return .success((parsed, reply))
                }
                if let message = MCPProbe.parseRPCError(
                    reply.data, contentType: reply.contentType)?.message {
                    return .failure(ListFailure(message))
                }
                if let code = reply.statusCode, !reply.isHTTPSuccess {
                    return .failure(ListFailure(L10n.format(
                        "%1$@ returned HTTP %2$@", zhHans: "%1$@ 返回 HTTP %2$@",
                        method, String(code))))
                }
                return .failure(ListFailure(L10n.format(
                    "The %@ response could not be read", zhHans: "%@ 的响应无法解析", method)))
            }
        }

        // tools/list follows nextCursor (guardrails: ≤20 pages and ≤1000 tools)
        var cursor: String?
        for pageIndex in 0..<20 {
            let result = page(
                method: "tools/list", id: MCPProbe.RequestID.toolsList,
                body: MCPProbe.toolsListRequestBody(cursor: cursor, modernVersion: modernVersion)
            ) { MCPProbe.parseToolsList($0, contentType: $1) }
            guard case .success(let (parsed, reply)) = result else {
                // A server that never declared the tools capability is allowed to refuse; a
                // failure after the first page keeps what was read
                if pageIndex == 0, session.info.capabilities.contains("tools"),
                   case .failure(let failure) = result {
                    inspection.toolsError = failure.reason
                }
                break
            }
            inspection.tools += parsed.tools
            let payload = MCPProbe.extractJSONPayload(reply.data, contentType: reply.contentType)
            inspection.schemaTokens += payload
                .map { TokenEstimator.estimate(String(decoding: $0, as: UTF8.self)) } ?? 0
            cursor = parsed.nextCursor
            guard cursor != nil, inspection.tools.count < 1000 else { break }
        }

        // prompts / resources: only asked when declared, first page (the cache caps them anyway)
        if session.info.capabilities.contains("prompts"),
           case .success(let (parsed, _)) = page(
               method: "prompts/list", id: MCPProbe.RequestID.promptsList,
               body: MCPProbe.promptsListRequestBody(modernVersion: modernVersion),
               parse: { MCPProbe.parseNamedList($0, contentType: $1, key: "prompts") }) {
            inspection.prompts = parsed.items
        }
        if session.info.capabilities.contains("resources"),
           case .success(let (parsed, _)) = page(
               method: "resources/list", id: MCPProbe.RequestID.resourcesList,
               body: MCPProbe.resourcesListRequestBody(modernVersion: modernVersion),
               parse: { MCPProbe.parseNamedList($0, contentType: $1, key: "resources") }) {
            inspection.resources = parsed.items
        }
        return inspection
    }

    private struct ListFailure: Error {
        var reason: String
        init(_ reason: String) { self.reason = reason }
    }
}

public extension MCPToolCacheEntry {
    /// Longest instructions text kept (bytes of UTF-8, cut on a character boundary)
    static let instructionsLimit = 8 * 1024
    static let toolDescriptionLimit = 2000
    static let listDescriptionLimit = 200
    static let listItemLimit = 100

    /// Inspection → cache entry. Descriptions are truncated, lists capped, and neither schema
    /// bodies nor any config value ever enter the cache. When the tool list could not be read,
    /// the lists of `previous` are kept (a failed refresh must not erase a good one) and
    /// `toolsError` says why they are not fresh.
    init(inspection: MCPInspector.Inspection, previous: MCPToolCacheEntry?, now: Date) {
        let info = inspection.handshake
        func summarize(_ items: [MCPProbe.NamedItem]?) -> [MCPNamedSummary]? {
            items.map { list in
                list.prefix(Self.listItemLimit).map {
                    MCPNamedSummary(
                        name: $0.name,
                        description: $0.description.map {
                            String($0.prefix(Self.listDescriptionLimit))
                        })
                }
            }
        }
        let prompts = info.capabilities.contains("prompts") ? inspection.prompts : nil
        let resources = info.capabilities.contains("resources") ? inspection.resources : nil
        self.init(
            toolCount: inspection.tools.count,
            toolNames: inspection.tools.map(\.name),
            schemaTokens: inspection.schemaTokens,
            serverVersion: info.serverVersion,
            protocolVersion: info.protocolVersion,
            capabilities: info.capabilities,
            tools: inspection.tools.map { tool in
                MCPToolSummary(
                    name: tool.name,
                    title: tool.title,
                    description: tool.description.map {
                        String($0.prefix(Self.toolDescriptionLimit))
                    },
                    readOnly: tool.readOnly,
                    destructive: tool.destructive,
                    hasOutputSchema: tool.hasOutputSchema ? true : nil,
                    params: tool.params.isEmpty ? nil : tool.params,
                    paramDetails: tool.paramDetails.isEmpty ? nil : tool.paramDetails.map {
                        MCPToolParamSummary(
                            name: $0.name, type: $0.type, required: $0.required,
                            description: $0.description.map {
                                String($0.prefix(Self.listDescriptionLimit))
                            })
                    })
            },
            resourceCount: resources?.count,
            promptCount: prompts?.count,
            prompts: summarize(prompts),
            resources: summarize(resources),
            serverName: info.serverName,
            serverTitle: info.serverTitle,
            instructions: info.instructions.map(Self.capped),
            toolsError: inspection.toolsError,
            measuredAt: now)
        if inspection.toolsError != nil, let previous {
            toolCount = previous.toolCount
            toolNames = previous.toolNames
            schemaTokens = previous.schemaTokens
            tools = previous.tools
        }
    }

    private static func capped(_ text: String) -> String {
        guard text.utf8.count > instructionsLimit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: instructionsLimit)
        while String.Index(end, within: text) == nil { end = text.utf8.index(before: end) }
        return String(text[..<end]) + "…"
    }
}
