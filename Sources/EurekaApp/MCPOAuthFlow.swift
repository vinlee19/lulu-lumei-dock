import AppKit
import EurekaIngest
import EurekaKit
import Foundation
import Network

/// MCP browser OAuth orchestration (app layer): discovery → dynamic registration → default-browser
/// authorization → loopback callback → token exchange. Pure logic lives in MCPOAuth (testable);
/// this only does network/browser/listening.
///
/// Privacy posture: everything is triggered by a user click; outbound traffic only goes to the authorization-server domain the server itself discloses;
/// the token is only handed to the caller to store in Keychain, nothing is written to any file/log here.
/// Network.framework is a system framework — the "Sparkle is the only third-party dependency" rule holds.
enum MCPOAuthFlow {
    enum FlowError: LocalizedError {
        case invalidServerURL
        case discoveryFailed
        case pkceUnsupported
        case dcrUnsupported
        case registrationFailed
        case listenerFailed
        case callbackTimeout
        case callbackDenied(String)
        case callbackInvalid
        case tokenExchangeFailed

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return L10n.text("Invalid server URL", zhHans: "server URL 无效")
            case .discoveryFailed:
                return L10n.text("Unable to discover authorization server metadata (neither OAuth AS nor OIDC Discovery responded)", zhHans: "无法发现授权服务器元数据（OAuth AS / OIDC Discovery 均无响应）")
            case .pkceUnsupported:
                return L10n.text("This authorization server does not declare PKCE support (S256 is missing from code_challenge_methods_supported); cannot continue under the MCP specification", zhHans: "该授权服务器未声明 PKCE 支持（code_challenge_methods_supported 缺 S256），按 MCP 规范拒绝继续")
            case .dcrUnsupported:
                return L10n.text("This authorization server does not support dynamic registration—enter a preregistered client_id in the “Connection & Authorization” card and try again", zhHans: "该授权服务器不支持动态注册——可在「连接与授权」卡内填入预注册 client_id 后重试")
            case .registrationFailed: return L10n.text("Dynamic registration failed (RFC 7591)", zhHans: "动态注册失败（RFC 7591）")
            case .listenerFailed: return L10n.text("Failed to start the local loopback listener", zhHans: "本机回环监听启动失败")
            case .callbackTimeout: return L10n.text("Timed out waiting for browser authorization (2 minutes)", zhHans: "等待浏览器授权超时（2 分钟）")
            case .callbackDenied(let reason): return L10n.format("Authorization denied: %@", zhHans: "授权被拒绝：%@", String(reason))
            case .callbackInvalid: return L10n.text("Invalid callback (state mismatch or missing authorization code)", zhHans: "回调无效（state 不匹配或缺少授权码）")
            case .tokenExchangeFailed: return L10n.text("Token exchange failed", zhHans: "令牌交换失败")
            }
        }
    }

    /// Runs the full flow synchronously (caller is on a background queue); progress is already
    /// delivered on main. preRegisteredClientID: a pre-registered client_id the user entered
    /// manually (registration priority #1 in the spec); when present, dynamic registration is
    /// skipped — the spec's way out when DCR isn't supported ("prompt the user").
    static func run(
        serverURL: String, headers: [String: String],
        preRegisteredClientID: String? = nil,
        progress: @escaping (String) -> Void
    ) throws -> MCPOAuth.TokenSet {
        func report(_ message: String) {
            DispatchQueue.main.async { progress(message) }
        }
        guard URL(string: serverURL) != nil else { throw FlowError.invalidServerURL }

        // (1) Discovery: an initialize probe gets the WWW-Authenticate challenge (resource_metadata
        //     + authoritative scope); with no header the spec MUST-probes the PRM well-known
        //     (path-inserted → root path); only if all fail does it fall back to the server origin
        //     as issuer
        report(L10n.text("Discovering authorization server…", zhHans: "正在发现授权服务器…"))
        let challenge = discoverChallenge(serverURL: serverURL, headers: headers)
        var metadataURLs = challenge.resourceMetadata.flatMap(URL.init(string:)).map { [$0] } ?? []
        metadataURLs += MCPOAuth.protectedResourceMetadataURLs(serverURL: serverURL)
        var issuers: [String] = []
        for url in metadataURLs {
            if let data = httpGet(url) {
                issuers = MCPOAuth.parseResourceMetadata(data)
                if !issuers.isEmpty { break }
            }
        }
        if issuers.isEmpty, let origin = MCPOAuth.origin(of: serverURL) {
            issuers = [origin]
        }
        // AS metadata: the spec MUSTs both mechanisms in order (OAuth AS metadata → OIDC Discovery)
        guard let issuer = issuers.first else { throw FlowError.discoveryFailed }
        var metadata: MCPOAuth.ASMetadata?
        for candidate in MCPOAuth.asMetadataCandidates(issuer: issuer) {
            if let data = httpGet(candidate), let parsed = MCPOAuth.parseASMetadata(data) {
                metadata = parsed
                break
            }
        }
        guard let metadata else { throw FlowError.discoveryFailed }
        // PKCE capability check (spec MUST: refuse when metadata lacks S256, to prevent downgrade
        // attacks)
        guard metadata.codeChallengeMethodsSupported.contains("S256") else {
            throw FlowError.pkceUnsupported
        }

        // (2) Start the loopback listener first to get the port (registration must carry the exact
        //     redirect_uri)
        let listener = try LoopbackListener()
        defer { listener.cancel() }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        // (3) Client registration: pre-registered client_id first (spec priority 1), otherwise
        //     dynamic registration (RFC 7591)
        let clientID: String
        if let preRegistered = preRegisteredClientID?.trimmingCharacters(in: .whitespaces),
           !preRegistered.isEmpty {
            clientID = preRegistered
        } else {
            guard let registrationEndpoint = metadata.registrationEndpoint,
                  let registrationURL = URL(string: registrationEndpoint)
            else { throw FlowError.dcrUnsupported }
            guard let registrationData = httpPost(
                    registrationURL,
                    body: MCPOAuth.registrationRequestBody(redirectURI: redirectURI),
                    contentType: "application/json"),
                  let registered = MCPOAuth.parseRegistration(registrationData)
            else { throw FlowError.registrationFailed }
            clientID = registered
        }

        // (4) Open the authorization page in the default browser (PKCE + state + resource +
        //     authoritative scope preferred)
        let verifier = MCPOAuth.generateVerifier()
        let state = MCPOAuth.generateVerifier()
        guard let authorizationURL = MCPOAuth.authorizationURL(
            endpoint: metadata.authorizationEndpoint,
            clientID: clientID, redirectURI: redirectURI,
            state: state, codeChallenge: MCPOAuth.challenge(for: verifier),
            resource: serverURL,
            scopes: MCPOAuth.selectScopes(
                challengeScopes: challenge.scopes, metadata: metadata))
        else { throw FlowError.discoveryFailed }
        report(L10n.text("Browser opened; waiting for authorization…", zhHans: "已打开浏览器，等待授权…"))
        DispatchQueue.main.async { NSWorkspace.shared.open(authorizationURL) }

        // (5) Wait for the callback (2 minutes; stray requests like favicon get a 404 from the
        //     listener, which keeps waiting)
        guard let requestHead = listener.waitForCallback(timeout: 120) else {
            throw FlowError.callbackTimeout
        }
        switch MCPOAuth.parseCallbackRequest(requestHead, expectedState: state) {
        case .code(let code):
            // (6) Exchange the token
            report(L10n.text("Exchanging token…", zhHans: "正在交换令牌…"))
            guard let tokenURL = URL(string: metadata.tokenEndpoint),
                  let tokenData = httpPost(
                      tokenURL,
                      body: MCPOAuth.tokenRequestBody(
                          code: code, redirectURI: redirectURI, clientID: clientID,
                          codeVerifier: verifier, resource: serverURL),
                      contentType: "application/x-www-form-urlencoded"),
                  let tokenSet = MCPOAuth.parseTokenResponse(
                      tokenData, tokenEndpoint: metadata.tokenEndpoint, clientID: clientID)
            else { throw FlowError.tokenExchangeFailed }
            return tokenSet
        case .denied(let reason):
            throw FlowError.callbackDenied(reason)
        case .stateMismatch, .invalid:
            throw FlowError.callbackInvalid
        }
    }

    // MARK: - Discovery helpers

    /// Send one initialize to the server and take the full WWW-Authenticate challenge from the 401
    /// (resource_metadata URL + authoritative scope parameter)
    private static func discoverChallenge(
        serverURL: String, headers: [String: String]
    ) -> MCPProbe.Challenge {
        guard let url = URL(string: serverURL) else { return MCPProbe.Challenge() }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.httpBody = MCPProbe.initializeRequestBody()
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let semaphore = DispatchSemaphore(value: 0)
        var header: String?
        URLSession.shared.dataTask(with: request) { _, response, _ in
            header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "WWW-Authenticate")
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 10)
        return MCPProbe.parseChallenge(header)
    }

    // MARK: - HTTP (blocking, only used on background queues)

    private static func httpGet(_ url: URL) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return perform(request)
    }

    private static func httpPost(_ url: URL, body: Data, contentType: String) -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return perform(request)
    }

    private static func perform(_ request: URLRequest) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                result = data
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 12)
        return result
    }
}

/// One-shot loopback HTTP listener: binds only 127.0.0.1 on a random port; requests other than
/// `/callback` (like the /favicon.ico the browser asks for along the way) get a 404 and it keeps
/// waiting; on a callback hit it serves the "authorization complete" page and finishes.
private final class LoopbackListener {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.vinlee.eureka.mcp.oauth-listener")
    private let callbackSemaphore = DispatchSemaphore(value: 0)
    private var callbackHead: String?
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let listener = try? NWListener(using: parameters) else {
            throw MCPOAuthFlow.FlowError.listenerFailed
        }
        self.listener = listener

        let readySemaphore = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { readySemaphore.signal() }
            if case .failed = state { readySemaphore.signal() }
        }
        listener.start(queue: queue)
        _ = readySemaphore.wait(timeout: .now() + 5)
        guard let port = listener.port?.rawValue else {
            listener.cancel()
            throw MCPOAuthFlow.FlowError.listenerFailed
        }
        self.port = port
        // The handler is attached after all properties are initialized (compiler constraint on
        // capturing self in init); the browser hasn't opened yet, so no callback connection can
        // exist at this point.
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    func waitForCallback(timeout: TimeInterval) -> String? {
        _ = callbackSemaphore.wait(timeout: .now() + timeout)
        return callbackHead
    }

    func cancel() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let isCallback = head.hasPrefix("GET /callback")
            let body = isCallback
                ? "<html><meta charset=\"utf-8\"><body style=\"font-family:-apple-system;"
                    + "text-align:center;padding-top:120px\"><h2>"
                    + L10n.text("Authorization Complete", zhHans: "授权完成")
                    + "</h2><p>"
                    + L10n.text("Return to Eureka and run “Test Connection” again.", zhHans: "请回到 Eureka，重新「检测连接」即可。")
                    + "</p></body></html>"
                : "not found"
            let status = isCallback ? "200 OK" : "404 Not Found"
            let bodyData = Data(body.utf8)
            let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(bodyData.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(response.utf8) + bodyData,
                completion: .contentProcessed { _ in connection.cancel() })
            if isCallback {
                self.callbackHead = head
                self.callbackSemaphore.signal()
            }
        }
    }
}
