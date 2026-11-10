import Foundation

/// When opening a server's detail page should probe it without being asked. The page exists to
/// show what the server offers, so it fetches that once when it has nothing fresh — but it must
/// not loop on a server that keeps failing, nor nag one that is waiting for the user to authorize.
public enum MCPProbePolicy {
    /// A tool list older than this is refreshed on open
    public static let staleAfter: TimeInterval = 7 * 24 * 3600
    /// After any probe, successful or not, leave the server alone for this long
    public static let retryAfter: TimeInterval = 10 * 60
    /// A server that answered "authorize first" / "not an MCP endpoint" needs the user, not
    /// another request; wait this long before asking again
    public static let needsUserAfter: TimeInterval = 24 * 3600

    /// Whether a server's config is trusted enough to be contacted or launched **without a
    /// click**. Project-scope config is checked into a repository, so its author is whoever
    /// wrote the repo: opening a page must not run their command. It is trusted only once the
    /// user approved that server in Claude Code; other agents record no approval, so theirs
    /// always wait for the button. Global and local config live in the user's own home.
    public static func trustsForAutoProbe(
        scope: MCPServerEntry.Scope,
        claudeApproval: MCPToolPermissionIndex.ProjectServerApproval?
    ) -> Bool {
        scope != .project || claudeApproval == .approved
    }

    /// - cache: the tool cache entry for this server name, if any
    /// - snapshots: last probe result of each of its config locations
    public static func shouldAutoProbe(
        cache: MCPToolCacheEntry?, snapshots: [MCPProbeSnapshot], now: Date
    ) -> Bool {
        if let cache, cache.toolsError == nil,
           now.timeIntervalSince(cache.measuredAt) < staleAfter {
            return false
        }
        guard let latest = snapshots.max(by: { $0.checkedAt < $1.checkedAt }) else {
            return true
        }
        let age = now.timeIntervalSince(latest.checkedAt)
        if age < retryAfter { return false }
        if latest.tone == "warning", age < needsUserAfter { return false }
        return true
    }
}
