import EurekaIngest
import Foundation

func mcpOAuthTests(_ t: TestRunner) {
    t.suite("MCPOAuth（浏览器授权纯逻辑）")

    t.test("PKCE：RFC 7636 附录 B 已知向量 + verifier 不重复") {
        try expectEqual(
            MCPOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let one = MCPOAuth.generateVerifier()
        let two = MCPOAuth.generateVerifier()
        try expect(one != two, "verifier 必须随机")
        try expect(one.count >= 43, "RFC 7636 要求 43-128 字符")
        try expect(!one.contains("+") && !one.contains("/") && !one.contains("="),
            "必须是 base64url 无填充")
    }

    t.test("资源元数据（RFC 9728）→ 授权服务器列表") {
        let json = #"{"resource":"https://mcp.notion.com/mcp","authorization_servers":["https://mcp.notion.com"]}"#
        try expectEqual(
            MCPOAuth.parseResourceMetadata(Data(json.utf8)), ["https://mcp.notion.com"])
        try expectEqual(MCPOAuth.parseResourceMetadata(Data("{}".utf8)), [])
    }

    t.test("AS 元数据（RFC 8414）：三端点 + scopes；well-known 地址构造（含路径 issuer）") {
        let json = """
        {"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize",
         "token_endpoint":"https://auth.example/token",
         "registration_endpoint":"https://auth.example/register",
         "scopes_supported":["read","write"]}
        """
        let metadata = MCPOAuth.parseASMetadata(Data(json.utf8))
        try expectEqual(metadata?.authorizationEndpoint, "https://auth.example/authorize")
        try expectEqual(metadata?.tokenEndpoint, "https://auth.example/token")
        try expectEqual(metadata?.registrationEndpoint, "https://auth.example/register")
        try expectEqual(metadata?.scopesSupported ?? [], ["read", "write"])
        // 缺 token_endpoint → nil
        try expect(MCPOAuth.parseASMetadata(
            Data(#"{"authorization_endpoint":"https://x/a"}"#.utf8)) == nil)

        try expectEqual(
            MCPOAuth.wellKnownASMetadataURL(issuer: "https://auth.example")?.absoluteString,
            "https://auth.example/.well-known/oauth-authorization-server")
        // issuer 带路径：well-known 插在路径前（RFC 8414）
        try expectEqual(
            MCPOAuth.wellKnownASMetadataURL(issuer: "https://auth.example/tenant1")?.absoluteString,
            "https://auth.example/.well-known/oauth-authorization-server/tenant1")
        try expectEqual(
            MCPOAuth.origin(of: "https://mcp.notion.com/mcp"), "https://mcp.notion.com")
    }

    t.test("AS 发现候选（2025-11-25 MUST 双机制按序）：OAuth → OIDC 插入 → OIDC 追加") {
        // 带路径 issuer：三候选
        try expectEqual(
            MCPOAuth.asMetadataCandidates(issuer: "https://auth.example/tenant1")
                .map(\.absoluteString),
            ["https://auth.example/.well-known/oauth-authorization-server/tenant1",
             "https://auth.example/.well-known/openid-configuration/tenant1",
             "https://auth.example/tenant1/.well-known/openid-configuration"])
        // 无路径 issuer：两候选（追加式与插入式同址，去重）
        try expectEqual(
            MCPOAuth.asMetadataCandidates(issuer: "https://auth.example")
                .map(\.absoluteString),
            ["https://auth.example/.well-known/oauth-authorization-server",
             "https://auth.example/.well-known/openid-configuration"])
    }

    t.test("PRM well-known 试探（401 无 header 的 MUST 回退）：路径插入 → 根路径") {
        try expectEqual(
            MCPOAuth.protectedResourceMetadataURLs(serverURL: "https://mcp.example.com/mcp")
                .map(\.absoluteString),
            ["https://mcp.example.com/.well-known/oauth-protected-resource/mcp",
             "https://mcp.example.com/.well-known/oauth-protected-resource"])
        try expectEqual(
            MCPOAuth.protectedResourceMetadataURLs(serverURL: "https://mcp.example.com")
                .map(\.absoluteString),
            ["https://mcp.example.com/.well-known/oauth-protected-resource"])
    }

    t.test("OIDC 文档同套解析 + PKCE 能力字段 + scope 选择策略") {
        // OIDC Discovery 文档字段名与 RFC 8414 相同，一套解析通吃
        let oidc = """
        {"issuer":"https://auth.example","authorization_endpoint":"https://auth.example/authorize",
         "token_endpoint":"https://auth.example/token",
         "code_challenge_methods_supported":["S256","plain"],
         "scopes_supported":["openid","mcp"]}
        """
        let metadata = MCPOAuth.parseASMetadata(Data(oidc.utf8))
        try expectEqual(metadata?.codeChallengeMethodsSupported ?? [], ["S256", "plain"])
        // 缺 code_challenge_methods_supported → 空数组（Flow 层据此拒绝，防 PKCE 降级）
        let noPKCE = MCPOAuth.parseASMetadata(Data(
            #"{"authorization_endpoint":"https://x/a","token_endpoint":"https://x/t"}"#.utf8))
        try expectEqual(noPKCE?.codeChallengeMethodsSupported ?? ["解析失败"], [])

        // scope 三优先级：质询权威 → scopes_supported → 全无省略
        try expectEqual(
            MCPOAuth.selectScopes(challengeScopes: ["files:read"], metadata: metadata),
            ["files:read"], "质询 scope 是权威来源")
        try expectEqual(
            MCPOAuth.selectScopes(challengeScopes: [], metadata: metadata),
            ["openid", "mcp"])
        try expectEqual(MCPOAuth.selectScopes(challengeScopes: [], metadata: nil), [])
    }

    t.test("动态注册（RFC 7591）：公共客户端请求体 + client_id 解析") {
        let body = MCPOAuth.registrationRequestBody(
            redirectURI: "http://127.0.0.1:49152/callback")
        let root = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        try expectEqual(root?["client_name"] as? String, "Eureka")
        try expectEqual(root?["token_endpoint_auth_method"] as? String, "none",
            "公共客户端，无 secret")
        try expectEqual(
            (root?["redirect_uris"] as? [String]) ?? [], ["http://127.0.0.1:49152/callback"])

        try expectEqual(
            MCPOAuth.parseRegistration(Data(#"{"client_id":"abc123"}"#.utf8)), "abc123")
        try expect(MCPOAuth.parseRegistration(Data("{}".utf8)) == nil)
    }

    t.test("授权 URL：PKCE/state/resource/redirect_uri 参数齐全") {
        let url = MCPOAuth.authorizationURL(
            endpoint: "https://auth.example/authorize",
            clientID: "abc", redirectURI: "http://127.0.0.1:49152/callback",
            state: "st8", codeChallenge: "chlg",
            resource: "https://mcp.notion.com/mcp", scopes: ["read", "write"])
        let components = URLComponents(url: try requireValue(url), resolvingAgainstBaseURL: false)
        func value(_ name: String) -> String? {
            components?.queryItems?.first { $0.name == name }?.value
        }
        try expectEqual(value("response_type"), "code")
        try expectEqual(value("client_id"), "abc")
        try expectEqual(value("code_challenge"), "chlg")
        try expectEqual(value("code_challenge_method"), "S256")
        try expectEqual(value("state"), "st8")
        try expectEqual(value("resource"), "https://mcp.notion.com/mcp")
        try expectEqual(value("scope"), "read write")
    }

    t.test("回环回调解析：正常 / state 不符 / 拒绝 / favicon 杂请求") {
        let ok = MCPOAuth.parseCallbackRequest(
            "GET /callback?code=xyz&state=st8 HTTP/1.1\r\nHost: 127.0.0.1\r\n",
            expectedState: "st8")
        try expectEqual(ok, .code("xyz"))

        try expectEqual(
            MCPOAuth.parseCallbackRequest(
                "GET /callback?code=xyz&state=WRONG HTTP/1.1", expectedState: "st8"),
            .stateMismatch, "state 不匹配必须丢弃（防伪造回调）")

        try expectEqual(
            MCPOAuth.parseCallbackRequest(
                "GET /callback?error=access_denied&error_description=user%20denied HTTP/1.1",
                expectedState: "st8"),
            .denied("user denied"))

        try expectEqual(
            MCPOAuth.parseCallbackRequest("GET /favicon.ico HTTP/1.1", expectedState: "st8"),
            .invalid)
    }

    t.test("token 交换/刷新请求体 + 响应解析 + Keychain 编解码 round-trip") {
        let body = MCPOAuth.tokenRequestBody(
            code: "xyz", redirectURI: "http://127.0.0.1:1/callback",
            clientID: "abc", codeVerifier: "ver", resource: "https://s/mcp")
        let text = String(decoding: body, as: UTF8.self)
        try expect(text.contains("grant_type=authorization_code"))
        try expect(text.contains("code_verifier=ver"))
        try expect(text.contains("redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcallback"),
            "form-urlencoded 必须转义")

        let refresh = String(decoding: MCPOAuth.refreshRequestBody(
            refreshToken: "rt", clientID: "abc", resource: nil), as: UTF8.self)
        try expect(refresh.contains("grant_type=refresh_token"))

        let response = #"{"access_token":"at","refresh_token":"rt","expires_in":3600}"#
        let set = MCPOAuth.parseTokenResponse(
            Data(response.utf8), tokenEndpoint: "https://auth/token", clientID: "abc",
            now: Date(timeIntervalSince1970: 1_700_000_000))
        try expectEqual(set?.accessToken, "at")
        try expectEqual(set?.refreshToken, "rt")
        try expectEqual(set?.expiresIn, 3600)

        let encoded = try requireValue(MCPOAuth.encodeTokenSet(try requireValue(set)))
        try expect(!encoded.isEmpty)
        let decoded = MCPOAuth.decodeTokenSet(encoded)
        try expectEqual(decoded, set, "Keychain 字符串必须无损 round-trip")
    }
}

/// 简易 unwrap（本 harness 无 XCTUnwrap）
private func requireValue<T>(_ value: T?) throws -> T {
    guard let value else { throw ExpectationError(description: "unexpected nil") }
    return value
}
