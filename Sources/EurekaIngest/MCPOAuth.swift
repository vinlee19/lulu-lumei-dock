import CryptoKit
import Foundation

/// MCP 浏览器 OAuth 授权的**纯逻辑层**（MCP 授权规范 = OAuth 2.1 公共客户端）：
/// RFC 9728 资源元数据 → RFC 8414 授权服务器发现 → RFC 7591 动态注册 →
/// PKCE（RFC 7636）授权码 + 回环回调 → token 交换/刷新。
/// 网络、浏览器与回环监听在 app 层（MCPOAuthFlow）；这里全部可单测。
///
/// 边界：换来的 token 只服务 Eureka 自己的探测（检测连接 / tools/list），
/// 存 Keychain，**绝不写入任何 CLI 的凭证存储**。
public enum MCPOAuth {
    /// 授权服务器元数据（RFC 8414 / OIDC Discovery 字段名相同，一套解析通吃）
    public struct ASMetadata: Equatable, Sendable {
        public var issuer: String?
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopesSupported: [String]
        /// PKCE 能力声明。规范（2025-11-25）：缺失即视为不支持 PKCE，
        /// 客户端 **MUST** 拒绝继续（OIDC 文档同样要求带上此字段才算 MCP 兼容）。
        public var codeChallengeMethodsSupported: [String]

        public init(
            issuer: String? = nil, authorizationEndpoint: String, tokenEndpoint: String,
            registrationEndpoint: String? = nil, scopesSupported: [String] = [],
            codeChallengeMethodsSupported: [String] = []
        ) {
            self.issuer = issuer
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.registrationEndpoint = registrationEndpoint
            self.scopesSupported = scopesSupported
            self.codeChallengeMethodsSupported = codeChallengeMethodsSupported
        }
    }

    /// 换到的令牌 + 刷新所需上下文（整体 JSON 编码后存 Keychain，一处一条）
    public struct TokenSet: Equatable, Codable, Sendable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresIn: Int?
        public var tokenEndpoint: String
        public var clientID: String
        public var obtainedAt: Date

        public init(
            accessToken: String, refreshToken: String? = nil, expiresIn: Int? = nil,
            tokenEndpoint: String, clientID: String, obtainedAt: Date
        ) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
            self.tokenEndpoint = tokenEndpoint
            self.clientID = clientID
            self.obtainedAt = obtainedAt
        }
    }

    public enum CallbackResult: Equatable, Sendable {
        case code(String)
        /// 授权页拒绝（error=access_denied 等）
        case denied(String)
        /// state 不匹配（可能是伪造回调，丢弃）
        case stateMismatch
        /// 不是回调请求（如浏览器顺手请求 /favicon.ico）
        case invalid
    }

    // MARK: - 发现（RFC 9728 / RFC 8414）

    /// 资源元数据 → 授权服务器列表（authorization_servers）
    public static func parseResourceMetadata(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["authorization_servers"] as? [String] else { return [] }
        return servers
    }

    /// issuer → RFC 8414 well-known 地址（issuer 带路径时 well-known 插在路径前）
    public static func wellKnownASMetadataURL(issuer: String) -> URL? {
        wellKnown(issuer: issuer, suffix: "oauth-authorization-server", pathInsertion: true)
    }

    /// AS 元数据发现候选（2025-11-25 规范 MUST 双机制按优先序尝试）：
    /// 带路径 issuer → ① OAuth AS 元数据（路径插入）② OIDC Discovery（路径插入）
    /// ③ OIDC Discovery（路径追加）；无路径 issuer → ① OAuth ② OIDC。
    public static func asMetadataCandidates(issuer: String) -> [URL] {
        var urls: [URL] = []
        if let oauth = wellKnown(
            issuer: issuer, suffix: "oauth-authorization-server", pathInsertion: true) {
            urls.append(oauth)
        }
        if let oidcInsert = wellKnown(
            issuer: issuer, suffix: "openid-configuration", pathInsertion: true) {
            urls.append(oidcInsert)
        }
        // 路径追加式仅对带路径 issuer 是第三候选；无路径时与②同址，去重即可
        if let oidcAppend = wellKnown(
            issuer: issuer, suffix: "openid-configuration", pathInsertion: false),
            !urls.contains(oidcAppend) {
            urls.append(oidcAppend)
        }
        return urls
    }

    /// 401 无 WWW-Authenticate 元数据时的 PRM well-known 试探地址（RFC 9728，
    /// 规范 MUST 回退）：路径插入式（`/.well-known/oauth-protected-resource/<path>`）
    /// → 根路径。server URL 无路径时只有根路径一个候选。
    public static func protectedResourceMetadataURLs(serverURL: String) -> [URL] {
        var urls: [URL] = []
        if let insertion = wellKnown(
            issuer: serverURL, suffix: "oauth-protected-resource", pathInsertion: true) {
            urls.append(insertion)
        }
        if let base = URL(string: serverURL), base.path != "/", !base.path.isEmpty,
           let origin = origin(of: serverURL),
           let root = URL(string: "\(origin)/.well-known/oauth-protected-resource") {
            urls.append(root)
        }
        return urls
    }

    /// well-known 构造共用体：pathInsertion = true 把 issuer 路径插到 well-known 段后
    /// （RFC 8414 式），false 追加到路径末尾（OIDC 传统式）。
    private static func wellKnown(
        issuer: String, suffix: String, pathInsertion: Bool
    ) -> URL? {
        guard let base = URL(string: issuer), let scheme = base.scheme,
              let host = base.host else { return nil }
        let portPart = base.port.map { ":\($0)" } ?? ""
        let path = base.path == "/" ? "" : base.path
        if pathInsertion {
            return URL(string: "\(scheme)://\(host)\(portPart)/.well-known/\(suffix)\(path)")
        }
        return URL(string: "\(scheme)://\(host)\(portPart)\(path)/.well-known/\(suffix)")
    }

    public static func parseASMetadata(_ data: Data) -> ASMetadata? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let authorization = root["authorization_endpoint"] as? String,
              let token = root["token_endpoint"] as? String else { return nil }
        return ASMetadata(
            issuer: root["issuer"] as? String,
            authorizationEndpoint: authorization,
            tokenEndpoint: token,
            registrationEndpoint: root["registration_endpoint"] as? String,
            scopesSupported: root["scopes_supported"] as? [String] ?? [],
            codeChallengeMethodsSupported:
                root["code_challenge_methods_supported"] as? [String] ?? [])
    }

    /// scope 选择策略（2025-11-25）：质询 `scope` 参数是权威 → 其次 scopes_supported
    /// → 全无则省略 scope 参数（交给 AS/用户在同意页决定）。
    public static func selectScopes(
        challengeScopes: [String], metadata: ASMetadata?
    ) -> [String] {
        if !challengeScopes.isEmpty { return challengeScopes }
        return metadata?.scopesSupported ?? []
    }

    /// server URL → origin（无资源元数据时按规范回退：AS = server 自己的 origin）
    public static func origin(of urlText: String) -> String? {
        guard let url = URL(string: urlText), let scheme = url.scheme,
              let host = url.host else { return nil }
        let portPart = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portPart)"
    }

    // MARK: - PKCE（RFC 7636，S256）

    public static func generateVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 48)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return base64URL(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - 动态注册（RFC 7591，公共客户端）

    public static func registrationRequestBody(redirectURI: String) -> Data {
        let payload: [String: Any] = [
            "client_name": "Eureka",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
    }

    public static func parseRegistration(_ data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return root["client_id"] as? String
    }

    // MARK: - 授权 URL

    public static func authorizationURL(
        endpoint: String, clientID: String, redirectURI: String,
        state: String, codeChallenge: String, resource: String?, scopes: [String]
    ) -> URL? {
        guard var components = URLComponents(string: endpoint) else { return nil }
        var items = components.queryItems ?? []
        items += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        if let resource {
            items.append(URLQueryItem(name: "resource", value: resource))  // RFC 8707
        }
        if !scopes.isEmpty {
            items.append(URLQueryItem(name: "scope", value: scopes.joined(separator: " ")))
        }
        components.queryItems = items
        return components.url
    }

    // MARK: - 回环回调解析（HTTP 请求首行）

    /// `GET /callback?code=..&state=.. HTTP/1.1` → 结果；state 不符一律丢弃
    public static func parseCallbackRequest(
        _ requestHead: String, expectedState: String
    ) -> CallbackResult {
        let normalized = requestHead.replacingOccurrences(of: "\r\n", with: "\n")
        guard let firstLine = normalized.split(separator: "\n").first else { return .invalid }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        let target = String(parts[1])
        guard target.hasPrefix("/callback"),
              let components = URLComponents(string: target) else { return .invalid }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        if let error = value("error") {
            return .denied(value("error_description") ?? error)
        }
        guard let code = value("code") else { return .invalid }
        guard value("state") == expectedState else { return .stateMismatch }
        return .code(code)
    }

    // MARK: - token 交换 / 刷新（application/x-www-form-urlencoded）

    public static func tokenRequestBody(
        code: String, redirectURI: String, clientID: String,
        codeVerifier: String, resource: String?
    ) -> Data {
        var pairs: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("client_id", clientID),
            ("code_verifier", codeVerifier),
        ]
        if let resource { pairs.append(("resource", resource)) }
        return formEncode(pairs)
    }

    public static func refreshRequestBody(
        refreshToken: String, clientID: String, resource: String?
    ) -> Data {
        var pairs: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", clientID),
        ]
        if let resource { pairs.append(("resource", resource)) }
        return formEncode(pairs)
    }

    public static func parseTokenResponse(
        _ data: Data, tokenEndpoint: String, clientID: String, now: Date = Date()
    ) -> TokenSet? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = root["access_token"] as? String else { return nil }
        return TokenSet(
            accessToken: access,
            refreshToken: root["refresh_token"] as? String,
            expiresIn: root["expires_in"] as? Int,
            tokenEndpoint: tokenEndpoint,
            clientID: clientID,
            obtainedAt: now)
    }

    // MARK: - TokenSet ↔ Keychain 字符串（JSON，日期按 epoch 秒）

    public static func encodeTokenSet(_ set: TokenSet) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(set) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeTokenSet(_ text: String) -> TokenSet? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(TokenSet.self, from: Data(text.utf8))
    }

    static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let body = pairs.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
