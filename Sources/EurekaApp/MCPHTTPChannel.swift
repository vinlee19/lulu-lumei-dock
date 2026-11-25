import EurekaIngest
import EurekaKit
import Foundation

/// `MCPInspectorChannel` over HTTP. Speaks Streamable HTTP (2025-03-26 onwards, both the
/// handshake and the stateless era) and can drop to the deprecated HTTP+SSE transport of
/// 2024-11-05 — up front when the config declares `sse`, or when the inspector asks after
/// `initialize` was rejected with 400 / 404 / 405.
///
/// The configured headers (they may carry credentials) go only to the configured URL and, on the
/// legacy transport, to a message endpoint of the **same origin**; response bodies only feed the
/// parser and are never stored or logged.
final class MCPHTTPChannel: MCPInspectorChannel {
    /// One request. tools/list of a large server over a slow link can take a while; the old 5s
    /// limit made healthy servers look like they had no tools.
    static let requestTimeout: TimeInterval = 15

    private let url: URL
    private let headers: [String: String]
    private let declaredSSE: Bool
    /// Handshake-era session id, echoed on every later request. Never sent on modern requests:
    /// 2026-07-28 has no sessions.
    private var sessionID: String?
    private var legacy: MCPLegacySSEConnection?
    private var legacyTried = false
    /// The event stream itself demanded authorization: every request reports that
    private var legacyAuthReply: MCPInspector.Reply?

    init(url: URL, headers: [String: String], declaredSSE: Bool) {
        self.url = url
        self.headers = headers
        self.declaredSSE = declaredSSE
    }

    func send(
        _ request: MCPInspector.Request
    ) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure> {
        if declaredSSE, !legacyTried { openLegacy() }
        if let legacyAuthReply { return .success(legacyAuthReply) }
        if let legacy { return legacy.send(request, headers: headers) }
        return post(request)
    }

    func fallBackToLegacyTransport() -> Bool {
        guard !legacyTried else { return false }
        openLegacy()
        return legacy != nil
    }

    func close() {
        legacy?.close()
        legacy = nil
    }

    private func openLegacy() {
        legacyTried = true
        switch MCPLegacySSEConnection.open(url: url, headers: headers) {
        case .opened(let connection):
            legacy = connection
        case .rejected(let status, let wwwAuthenticate) where status == 401 || status == 403:
            // Only meaningful when the config says this is an SSE server; as a fallback the
            // original Streamable HTTP status is the one worth reporting
            if declaredSSE {
                legacyAuthReply = MCPInspector.Reply(
                    data: Data(), statusCode: status, wwwAuthenticate: wwwAuthenticate)
            }
        case .rejected, .failed:
            break
        }
    }

    private func post(
        _ request: MCPInspector.Request
    ) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure> {
        var urlRequest = URLRequest(
            url: url, timeoutInterval: request.timeout ?? Self.requestTimeout)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = request.body
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            "application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if let version = request.protocolVersion {
            urlRequest.setValue(version, forHTTPHeaderField: "MCP-Protocol-Version")
        }
        if request.modern {
            urlRequest.setValue(request.method, forHTTPHeaderField: "Mcp-Method")
        } else if let sessionID {
            urlRequest.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
        }
        for (key, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }
        let result = MCPHTTP.perform(
            urlRequest, wait: (request.timeout ?? Self.requestTimeout) + 3)
        if case .success(let response) = result, !request.modern,
           let assigned = response.sessionID {
            sessionID = assigned
        }
        return result.map(\.reply)
    }
}

/// Blocking HTTP exchange for the MCP probe (called on a background queue)
enum MCPHTTP {
    struct Response {
        var reply: MCPInspector.Reply
        var sessionID: String?
    }

    static func perform(
        _ request: URLRequest, wait: TimeInterval
    ) -> Result<Response, MCPInspector.ChannelFailure> {
        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Response, MCPInspector.ChannelFailure> = .failure(.transport(
            URLError(.timedOut).localizedDescription))
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .failure(.transport(
                    (error as? URLError)?.localizedDescription ?? error.localizedDescription))
            } else if let http = response as? HTTPURLResponse {
                outcome = .success(Response(
                    reply: MCPInspector.Reply(
                        data: data ?? Data(),
                        contentType: http.value(forHTTPHeaderField: "Content-Type"),
                        statusCode: http.statusCode,
                        wwwAuthenticate: http.value(forHTTPHeaderField: "WWW-Authenticate")),
                    sessionID: http.value(forHTTPHeaderField: "Mcp-Session-Id")))
            } else {
                outcome = .failure(.transport(URLError(.badServerResponse).localizedDescription))
            }
            semaphore.signal()
        }
        task.resume()
        if semaphore.wait(timeout: .now() + wait) == .timedOut {
            task.cancel()
        }
        return outcome
    }
}

/// The 2024-11-05 HTTP+SSE transport: a GET opens a long-lived event stream whose first event,
/// `endpoint`, names the URI to POST messages to; responses come back as `message` events on the
/// stream, matched to requests by JSON-RPC id.
final class MCPLegacySSEConnection: NSObject, URLSessionDataDelegate {
    enum OpenResult {
        case opened(MCPLegacySSEConnection)
        /// The GET was answered with a non-2xx status
        case rejected(status: Int, wwwAuthenticate: String?)
        /// Not an event stream, no `endpoint` event in time, an endpoint on another origin, or a
        /// transport error
        case failed
    }

    private let origin: URL
    private let condition = NSCondition()
    private var parser = MCPSSEParser()
    private var endpoint: URL?
    private var responses: [String: Data] = [:]
    private var finished = false
    private var rejection: (Int, String?)?
    private var session: URLSession?
    private var task: URLSessionDataTask?

    private init(origin: URL) {
        self.origin = origin
    }

    static func open(
        url: URL, headers: [String: String], timeout: TimeInterval = 8
    ) -> OpenResult {
        let connection = MCPLegacySSEConnection(origin: url)
        let configuration = URLSessionConfiguration.ephemeral
        // The stream idles between messages; the per-request waits below bound everything
        configuration.timeoutIntervalForRequest = 120
        let session = URLSession(
            configuration: configuration, delegate: connection, delegateQueue: nil)
        var request = URLRequest(url: url)
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let task = session.dataTask(with: request)
        connection.session = session
        connection.task = task
        task.resume()

        let deadline = Date().addingTimeInterval(timeout)
        connection.condition.lock()
        while connection.endpoint == nil, !connection.finished, Date() < deadline {
            connection.condition.wait(until: deadline)
        }
        let opened = connection.endpoint != nil
        let rejection = connection.rejection
        connection.condition.unlock()
        if opened { return .opened(connection) }
        connection.close()
        if let (status, wwwAuthenticate) = rejection {
            return .rejected(status: status, wwwAuthenticate: wwwAuthenticate)
        }
        return .failed
    }

    func close() {
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func send(
        _ request: MCPInspector.Request, headers: [String: String]
    ) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure> {
        condition.lock()
        let endpoint = self.endpoint
        if let id = request.id { responses.removeValue(forKey: "\(id)") }
        condition.unlock()
        guard let endpoint else {
            return .failure(.closed(L10n.text(
                "The event stream is closed", zhHans: "事件流已关闭")))
        }
        let timeout = request.timeout ?? MCPHTTPChannel.requestTimeout
        var post = URLRequest(url: endpoint, timeoutInterval: timeout)
        post.httpMethod = "POST"
        post.httpBody = request.body
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (key, value) in headers { post.setValue(value, forHTTPHeaderField: key) }
        switch MCPHTTP.perform(post, wait: timeout + 3) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let response):
            let status = response.reply.statusCode ?? 0
            // The POST is only an acknowledgement (202); anything else is the answer itself
            guard (200...299).contains(status) else { return .success(response.reply) }
        }
        guard let id = request.id else {
            return .success(MCPInspector.Reply(data: Data(), statusCode: 202))
        }
        let key = "\(id)"
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while responses[key] == nil, !finished, Date() < deadline {
            condition.wait(until: deadline)
        }
        if let data = responses.removeValue(forKey: key) {
            return .success(MCPInspector.Reply(
                data: data, contentType: "application/json", statusCode: 200))
        }
        return finished
            ? .failure(.closed(L10n.text("The event stream closed", zhHans: "事件流已断开")))
            : .failure(.timedOut)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            return
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if (200...299).contains(http.statusCode), contentType.contains("text/event-stream") {
            completionHandler(.allow)
            return
        }
        condition.lock()
        if !(200...299).contains(http.statusCode) {
            rejection = (http.statusCode, http.value(forHTTPHeaderField: "WWW-Authenticate"))
        }
        finished = true
        condition.broadcast()
        condition.unlock()
        completionHandler(.cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        condition.lock()
        defer { condition.unlock() }
        for event in parser.feed(data) {
            switch event.name {
            case "endpoint":
                guard endpoint == nil else { continue }
                let text = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
                if let resolved = URL(string: text, relativeTo: origin)?.absoluteURL,
                   Self.sameOrigin(resolved, origin) {
                    endpoint = resolved
                } else {
                    // Credentials must not follow a server-supplied URL to another host
                    finished = true
                }
                condition.broadcast()
            case "message":
                let json = Data(event.data.utf8)
                guard let root = (try? JSONSerialization.jsonObject(with: json))
                        as? [String: Any],
                      root["result"] != nil || root["error"] != nil,
                      let id = (root["id"] as? Int).map(String.init) ?? (root["id"] as? String)
                else { continue }
                responses[id] = json
                condition.broadcast()
            default:
                continue
            }
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
    ) {
        condition.lock()
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ url: URL) -> Int {
            url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        }
        return a.scheme?.lowercased() == b.scheme?.lowercased()
            && a.host?.lowercased() == b.host?.lowercased()
            && port(a) == port(b)
    }
}
