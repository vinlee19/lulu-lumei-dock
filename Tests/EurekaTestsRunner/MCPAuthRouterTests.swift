import EurekaIngest
import Foundation

func mcpAuthRouterTests(_ t: TestRunner) {
    t.suite("MCPAuthRouter（鉴权方式识别路由）")

    t.test("stdio：env 键名 → 环境变量路由；无 env → open（规范：stdio 凭证取自环境）") {
        try expectEqual(
            MCPAuthRouter.route(
                transport: "stdio", headerKeys: [], envKeys: ["NOTION_TOKEN"],
                snapshotScheme: nil, hasToken: false),
            .envKeys(keys: ["NOTION_TOKEN"]))
        try expectEqual(
            MCPAuthRouter.route(
                transport: "stdio", headerKeys: [], envKeys: [],
                snapshotScheme: nil, hasToken: false),
            .open)
    }

    t.test("remote：显式鉴权请求头压过一切（含已持令牌）→ staticHeader") {
        try expectEqual(
            MCPAuthRouter.route(
                transport: "http", headerKeys: ["Authorization", "Accept"], envKeys: [],
                snapshotScheme: "oauth", hasToken: true),
            .staticHeader(keys: ["Authorization"]),
            "配置了显式 Authorization 的 server，动线是编辑请求头，不是浏览器")
        // 鉴权类键名的大小写与后缀识别
        try expect(MCPAuthRouter.isAuthHeaderKey("X-API-Key"))
        try expect(MCPAuthRouter.isAuthHeaderKey("x-goog-api-key"))
        try expect(MCPAuthRouter.isAuthHeaderKey("X-Auth-Token"))
        try expect(!MCPAuthRouter.isAuthHeaderKey("Accept"))
        try expect(!MCPAuthRouter.isAuthHeaderKey("Content-Type"))
    }

    t.test("remote：OAuth 信号（快照 oauth / 已持令牌）→ 浏览器授权") {
        try expectEqual(
            MCPAuthRouter.route(
                transport: "http", headerKeys: [], envKeys: [],
                snapshotScheme: "oauth", hasToken: false),
            .oauthBrowser)
        try expectEqual(
            MCPAuthRouter.route(
                transport: "sse", headerKeys: [], envKeys: [],
                snapshotScheme: nil, hasToken: true),
            .oauthBrowser, "已持令牌即走 OAuth 路由（无需再等快照）")
    }

    t.test("remote：401 无 OAuth 元数据 → staticHeader(空键)＝待填密钥；裸连即通 → open；无信号 → unknown") {
        try expectEqual(
            MCPAuthRouter.route(
                transport: "http", headerKeys: [], envKeys: [],
                snapshotScheme: "header-or-key", hasToken: false),
            .staticHeader(keys: []))
        try expectEqual(
            MCPAuthRouter.route(
                transport: "http", headerKeys: [], envKeys: [],
                snapshotScheme: "none", hasToken: false),
            .open)
        try expectEqual(
            MCPAuthRouter.route(
                transport: "http", headerKeys: [], envKeys: [],
                snapshotScheme: nil, hasToken: false),
            .unknown)
    }

    t.test("scheme 折算：探测状态 → 快照 authScheme（落盘供重启后路由）") {
        let info = MCPProbe.HandshakeInfo(protocolVersion: "2025-11-25")
        try expectEqual(
            MCPAuthRouter.scheme(for: .connected(info), usedToken: true, hadExplicitAuth: false),
            "oauth")
        try expectEqual(
            MCPAuthRouter.scheme(for: .connected(info), usedToken: false, hadExplicitAuth: true),
            "header-or-key")
        try expectEqual(
            MCPAuthRouter.scheme(for: .connected(info), usedToken: false, hadExplicitAuth: false),
            "none")
        try expectEqual(
            MCPAuthRouter.scheme(
                for: .unauthorized(code: 401, authServer: "https://as.example"),
                usedToken: false, hadExplicitAuth: false),
            "oauth")
        try expectEqual(
            MCPAuthRouter.scheme(
                for: .unauthorized(code: 401, authServer: nil),
                usedToken: false, hadExplicitAuth: true),
            "header-or-key")
        try expect(
            MCPAuthRouter.scheme(for: .unreachable("超时"), usedToken: false,
                hadExplicitAuth: false) == nil,
            "不可达/异常不产生鉴权判断（保留上次快照的判断由调用方决定）")
    }
}
