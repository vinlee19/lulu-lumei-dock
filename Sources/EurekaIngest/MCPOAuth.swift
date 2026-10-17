import CryptoKit
import Foundation

/// The **pure logic layer** for MCP browser OAuth authorization (MCP authorization spec = OAuth 2.1
/// public client): RFC 9728 resource metadata → RFC 8414 authorization server discovery → RFC 7591
/// dynamic registration → PKCE (RFC 7636) authorization code + loopback callback → token
/// exchange/refresh. Network, browser and loopback listener live in the app layer (MCPOAuthFlow);
/// everything here is unit-testable.
///
/// Boundary: the obtained token only serves Eureka's own probes (connection check / tools/list),
/// is stored in the Keychain, and is **never written into any CLI's credential store**.
public enum MCPOAuth {
    /// Authorization server metadata (RFC 8414 / OIDC Discovery share field names, so one parser
    /// handles both)
    public struct ASMetadata: Equatable, Sendable {
        public var issuer: String?
        public var authorizationEndpoint: String
        public var tokenEndpoint: String
        public var registrationEndpoint: String?
        public var scopesSupported: [String]
        /// PKCE capability declaration. Spec (2025-11-25): if absent, PKCE is treated as
        /// unsupported and the client **MUST** refuse to continue (OIDC documents likewise must
        /// carry this field to be MCP-compatible).
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

    /// Obtained tokens + the context needed to refresh (JSON-encoded as a whole and stored in the
    /// Keychain, one item per server)
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
        /// Rejected on the authorization page (error=access_denied etc.)
        case denied(String)
        /// state mismatch (possibly a forged callback; discarded)
        case stateMismatch
        /// Not a callback request (e.g. the browser also requesting /favicon.ico)
        case invalid
    }

    // MARK: - Discovery (RFC 9728 / RFC 8414)

    /// Resource metadata → list of authorization servers (authorization_servers)
    public static func parseResourceMetadata(_ data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let servers = root["authorization_servers"] as? [String] else { return [] }
        return servers
    }

    /// issuer → RFC 8414 well-known URL (when the issuer has a path, well-known is inserted before
    /// the path)
    public static func wellKnownASMetadataURL(issuer: String) -> URL? {
        wellKnown(issuer: issuer, suffix: "oauth-authorization-server", pathInsertion: true)
    }

    /// AS metadata discovery candidates (the 2025-11-25 spec MUST try both mechanisms in priority
    /// order): issuer with a path → (1) OAuth AS metadata (path insertion) (2) OIDC Discovery (path
    /// insertion)
    /// (3) OIDC Discovery (path appended); issuer without a path → (1) OAuth (2) OIDC.
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
        // Path-appended is a third candidate only for issuers with a path; without one it equals
        // (2), so dedup suffices
        if let oidcAppend = wellKnown(
            issuer: issuer, suffix: "openid-configuration", pathInsertion: false),
            !urls.contains(oidcAppend) {
            urls.append(oidcAppend)
        }
        return urls
    }

    /// PRM well-known probe URLs when a 401 has no WWW-Authenticate metadata (RFC 9728; the spec
    /// MUST fall back): path insertion (`/.well-known/oauth-protected-resource/<path>`) → root
    /// path. If the server URL has no path, the root path is the only candidate.
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

    /// Shared well-known builder: pathInsertion = true puts the issuer path after the well-known
    /// segment (RFC 8414 style); false appends it to the end of the path (traditional OIDC style).
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

    /// Scope selection strategy (2025-11-25): the challenge `scope` parameter is authoritative →
    /// then scopes_supported
    /// → if neither, omit the scope parameter (leave it to the AS/user on the consent page).
    public static func selectScopes(
        challengeScopes: [String], metadata: ASMetadata?
    ) -> [String] {
        if !challengeScopes.isEmpty { return challengeScopes }
        return metadata?.scopesSupported ?? []
    }

    /// server URL → origin (spec fallback without resource metadata: AS = the server's own origin)
    public static func origin(of urlText: String) -> String? {
        guard let url = URL(string: urlText), let scheme = url.scheme,
              let host = url.host else { return nil }
        let portPart = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(portPart)"
    }

    // MARK: - PKCE (RFC 7636, S256)

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

    // MARK: - Dynamic registration (RFC 7591, public client)

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

    // MARK: - Authorization URL

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

    // MARK: - Loopback callback parsing (HTTP request line)

    /// `GET /callback?code=..&state=.. HTTP/1.1` → result; any state mismatch is discarded
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

    // MARK: - Token exchange / refresh (application/x-www-form-urlencoded)

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

    // MARK: - TokenSet ↔ Keychain string (JSON, dates as epoch seconds)

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
