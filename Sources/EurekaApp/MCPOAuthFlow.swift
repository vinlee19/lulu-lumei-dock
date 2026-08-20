import AppKit
import EurekaIngest
import Foundation
import Network

/// MCP 浏览器 OAuth 授权编排（app 层）：发现 → 动态注册 → 默认浏览器授权 →
/// 回环回调 → token 交换。纯逻辑在 MCPOAuth（可测）；这里只做网络/浏览器/监听。
///
/// 隐私姿态：全部由用户点击触发；出网仅指向该 server 自己披露的授权服务器域名；
/// token 只交给调用方存 Keychain，这里不落任何文件/日志。
/// Network.framework 是系统框架——"Sparkle 唯一第三方依赖"纪律不破。
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
            case .invalidServerURL: return "server URL 无效"
            case .discoveryFailed:
                return "无法发现授权服务器元数据（OAuth AS / OIDC Discovery 均无响应）"
            case .pkceUnsupported:
                return "该授权服务器未声明 PKCE 支持（code_challenge_methods_supported "
                    + "缺 S256），按 MCP 规范拒绝继续"
            case .dcrUnsupported:
                return "该授权服务器不支持动态注册——"
                    + "可在「连接与授权」卡内填入预注册 client_id 后重试"
            case .registrationFailed: return "动态注册失败（RFC 7591）"
            case .listenerFailed: return "本机回环监听启动失败"
            case .callbackTimeout: return "等待浏览器授权超时（2 分钟）"
            case .callbackDenied(let reason): return "授权被拒绝：\(reason)"
            case .callbackInvalid: return "回调无效（state 不匹配或缺少授权码）"
            case .tokenExchangeFailed: return "令牌交换失败"
            }
        }
    }

    /// 同步执行完整流程（调用方在后台队列上）；progress 已回主线程。
    /// preRegisteredClientID：用户手动填入的预注册 client_id（规范注册优先级第一位），
    /// 有则跳过动态注册——DCR 不被支持时的规范出口（"prompt the user"）。
    static func run(
        serverURL: String, headers: [String: String],
        preRegisteredClientID: String? = nil,
        progress: @escaping (String) -> Void
    ) throws -> MCPOAuth.TokenSet {
        func report(_ message: String) {
            DispatchQueue.main.async { progress(message) }
        }
        guard URL(string: serverURL) != nil else { throw FlowError.invalidServerURL }

        // ① 发现：initialize 探测拿 WWW-Authenticate 质询（resource_metadata + 权威
        //    scope）；无 header 时按规范 MUST 试探 PRM well-known（路径插入式 → 根路径）；
        //    全败才回退 server origin 作为 issuer
        report("正在发现授权服务器…")
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
        // AS 元数据：规范 MUST 双机制按序（OAuth AS 元数据 → OIDC Discovery）
        guard let issuer = issuers.first else { throw FlowError.discoveryFailed }
        var metadata: MCPOAuth.ASMetadata?
        for candidate in MCPOAuth.asMetadataCandidates(issuer: issuer) {
            if let data = httpGet(candidate), let parsed = MCPOAuth.parseASMetadata(data) {
                metadata = parsed
                break
            }
        }
        guard let metadata else { throw FlowError.discoveryFailed }
        // PKCE 能力校验（规范 MUST：元数据缺 S256 即拒绝，防降级攻击）
        guard metadata.codeChallengeMethodsSupported.contains("S256") else {
            throw FlowError.pkceUnsupported
        }

        // ② 先起回环监听拿端口（注册必须带准确的 redirect_uri）
        let listener = try LoopbackListener()
        defer { listener.cancel() }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        // ③ 客户端注册：预注册 client_id 优先（规范优先级①），否则动态注册（RFC 7591）
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

        // ④ 默认浏览器打开授权页（PKCE + state + resource + 权威 scope 优先）
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
        report("已打开浏览器，等待授权…")
        DispatchQueue.main.async { NSWorkspace.shared.open(authorizationURL) }

        // ⑤ 等回调（2 分钟；favicon 之类的杂请求由监听器自行 404 并继续等）
        guard let requestHead = listener.waitForCallback(timeout: 120) else {
            throw FlowError.callbackTimeout
        }
        switch MCPOAuth.parseCallbackRequest(requestHead, expectedState: state) {
        case .code(let code):
            // ⑥ 换 token
            report("正在交换令牌…")
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

    // MARK: - 发现辅助

    /// 对 server 发一次 initialize，取 401 的 WWW-Authenticate 完整质询
    /// （resource_metadata 地址 + 权威 scope 参数）
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

    // MARK: - HTTP（阻塞式，只在后台队列使用）

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

/// 一次性回环 HTTP 监听：只绑 127.0.0.1、随机端口；`/callback` 之外的请求
/// （浏览器顺手要的 /favicon.ico）回 404 并继续等待；命中回调即回"授权完成"页并收工。
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
        // handler 在全部属性初始化后再挂（init 里捕获 self 的编译约束）；
        // 浏览器还没打开，此刻不可能已有回调连接。
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
                    + "text-align:center;padding-top:120px\"><h2>授权完成</h2>"
                    + "<p>请回到 Eureka，重新「检测连接」即可。</p></body></html>"
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
