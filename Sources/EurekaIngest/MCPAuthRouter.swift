import Foundation

/// **Detection and flow routing** for an MCP server's auth method (pure logic, v2.7).
///
/// Rationale: the MCP authorization spec only covers OAuth 2.1 over HTTP transports; the stdio spec says
/// verbatim "SHOULD NOT follow this specification, and instead retrieve credentials from
/// the environment". So browser authorization only makes sense for OAuth-style remote servers; the right
/// flow for static header secrets is "Edit headers", and for stdio it is "Edit environment variables".
/// Always showing "Authorize in browser" would send API-key users into a discovery flow bound to fail.
///
/// Signal sources (all zero-network): config shape (headers/env key names) + the authScheme derived from
/// the last probe snapshot ("oauth" / "header-or-key" / "none", persisted at probe time, survives restarts).
public enum MCPAuthRoute: Equatable, Sendable {
    /// OAuth 2.1: a 401 published OAuth metadata, or Eureka already holds a token → browser
    /// authorization
    case oauthBrowser
    /// Static header secret (keys = matched auth-type key names; empty = probe determined a secret
    /// is needed but none is configured yet)
    case staticHeader(keys: [String])
    /// stdio environment-variable secret (keys = env key names)
    case envKeys(keys: [String])
    /// No auth material and (if probed) a bare connection works → show no authorization UI
    case open
    /// Remote with no signal at all (never probed) → prompt to probe first; browser authorization
    /// becomes a secondary action
    case unknown
}

public enum MCPAuthRouter {
    /// Auth-type header key names (case-insensitive): authorization / *-api-key / *-token / *-key…
    public static func isAuthHeaderKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        if lowered == "authorization" || lowered == "proxy-authorization" { return true }
        for suffix in ["-api-key", "-key", "-token", "-secret", "-auth"]
        where lowered.hasSuffix(suffix) { return true }
        return ["apikey", "api-key", "token", "x-auth"].contains(lowered)
    }

    /// Five-way classification. Priority: explicit headers > OAuth signal > probe verdict >
    /// unknown.
    /// - transport: "stdio" or remote (http/sse…)
    /// - snapshotScheme: the authScheme from the last probe snapshot (nil if never probed)
    /// - hasToken: whether Eureka already holds an OAuth token for this server
    public static func route(
        transport: String, headerKeys: [String], envKeys: [String],
        snapshotScheme: String?, hasToken: Bool
    ) -> MCPAuthRoute {
        if transport == "stdio" {
            return envKeys.isEmpty ? .open : .envKeys(keys: envKeys)
        }
        // An explicit header secret overrides everything (probeOne never injects a Bearer for these
        // anyway)
        let authKeys = headerKeys.filter(isAuthHeaderKey)
        if !authKeys.isEmpty { return .staticHeader(keys: authKeys) }
        if hasToken || snapshotScheme == "oauth" { return .oauthBrowser }
        // The probe saw a 401 without OAuth metadata → a static secret is missing (empty keys =
        // still to be filled in)
        if snapshotScheme == "header-or-key" { return .staticHeader(keys: []) }
        if snapshotScheme == "none" { return .open }
        return .unknown
    }

    /// Probe status → snapshot authScheme (called when probeOne persists the snapshot).
    /// - usedToken: whether this probe injected a Bearer held by Eureka
    /// - hadExplicitAuth: whether the config carries an explicit auth header
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
