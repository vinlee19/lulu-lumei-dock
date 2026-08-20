import Foundation

/// MCP server 鉴权方式的**识别与动线路由**（纯逻辑，v2.7）。
///
/// 依据：MCP 授权规范只覆盖 HTTP 传输的 OAuth 2.1；stdio 规范原文明确
/// "SHOULD NOT follow this specification, and instead retrieve credentials from
/// the environment"——所以浏览器授权只对 OAuth 类 remote server 有意义，
/// 静态请求头密钥的正确动线是「编辑请求头」，stdio 的是「编辑环境变量」。
/// 恒显「在浏览器中授权」会把 API key 类用户引向必然失败的发现流程。
///
/// 信号来源（全部零网络）：配置形态（headers/env 键名）+ 上次探测快照折算的
/// authScheme（"oauth" / "header-or-key" / "none"，探测时落盘、重启不丢）。
public enum MCPAuthRoute: Equatable, Sendable {
    /// OAuth 2.1：401 公布过 OAuth 元数据，或 Eureka 已持有令牌 → 浏览器授权
    case oauthBrowser
    /// 静态请求头密钥（keys = 命中的鉴权类键名；空 = 探测判定需要密钥但尚未配置）
    case staticHeader(keys: [String])
    /// stdio 环境变量密钥（keys = env 键名）
    case envKeys(keys: [String])
    /// 无鉴权材料且（若检测过）裸连即通 → 不显示任何授权 UI
    case open
    /// remote 且无任何信号（未检测过）→ 引导先检测；浏览器授权降为次要动作
    case unknown
}

public enum MCPAuthRouter {
    /// 鉴权类请求头键名（大小写不敏感）：authorization / *-api-key / *-token / *-key…
    public static func isAuthHeaderKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        if lowered == "authorization" || lowered == "proxy-authorization" { return true }
        for suffix in ["-api-key", "-key", "-token", "-secret", "-auth"]
        where lowered.hasSuffix(suffix) { return true }
        return ["apikey", "api-key", "token", "x-auth"].contains(lowered)
    }

    /// 五路分类。优先级：显式请求头 > OAuth 信号 > 探测判定 > 未知。
    /// - transport: "stdio" 或 remote（http/sse…）
    /// - snapshotScheme: 上次探测快照的 authScheme（未检测过为 nil）
    /// - hasToken: Eureka 是否已持有该 server 的 OAuth 令牌
    public static func route(
        transport: String, headerKeys: [String], envKeys: [String],
        snapshotScheme: String?, hasToken: Bool
    ) -> MCPAuthRoute {
        if transport == "stdio" {
            return envKeys.isEmpty ? .open : .envKeys(keys: envKeys)
        }
        // 显式请求头密钥压过一切（probeOne 对这类本就不注入 Bearer）
        let authKeys = headerKeys.filter(isAuthHeaderKey)
        if !authKeys.isEmpty { return .staticHeader(keys: authKeys) }
        if hasToken || snapshotScheme == "oauth" { return .oauthBrowser }
        // 探测见过 401 但无 OAuth 元数据 → 缺静态密钥（keys 空 = 待填入）
        if snapshotScheme == "header-or-key" { return .staticHeader(keys: []) }
        if snapshotScheme == "none" { return .open }
        return .unknown
    }

    /// 探测状态 → 快照 authScheme 折算（probeOne 落盘时调用）。
    /// - usedToken: 本次探测是否注入了 Eureka 持有的 Bearer
    /// - hadExplicitAuth: 配置里是否带显式鉴权请求头
    public static func scheme(
        for status: MCPProbe.Status, usedToken: Bool, hadExplicitAuth: Bool
    ) -> String? {
        switch status {
        case .connected:
            if usedToken { return "oauth" }
            return hadExplicitAuth ? "header-or-key" : "none"
        case .unauthorized(_, let authServer):
            return authServer != nil ? "oauth" : "header-or-key"
        default:
            return nil
        }
    }
}
