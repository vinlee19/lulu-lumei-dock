import Foundation
import EurekaKit

/// OpenCode Go allowance through opencode's own server API:
/// `opencode api experimental.usage.limits` (opencode 2.2.x, `GET /api/experimental/usage/limits`,
/// "Return the OpenCode Go allowance and Console budgets of the OpenCode Console workspace the
/// location is signed in to, or null when it isn't signed in"). opencode authenticates itself;
/// Eureka never reads its credential store. The route is experimental, so any shape it does not
/// recognize hides the card.
/// `opencode api` talks to the background service; Eureka never starts that daemon, so the probe
/// is skipped unless `opencode service status` reports a running server.
public final class OpencodeGoProvider: RateLimitProvider {
    public let source = AgentSource.opencode

    public private(set) var lastFailure: String?
    private var cached: RateLimitSnapshot?
    private let probeDirectory: URL

    public init(probeDirectory: URL) {
        self.probeDirectory = probeDirectory
    }

    public func snapshot() async -> RateLimitSnapshot? {
        lastFailure = nil
        guard let opencode = CLIProbe.locate("opencode") else { return nil }
        try? FileManager.default.createDirectory(
            at: probeDirectory, withIntermediateDirectories: true)
        guard let status = await CLIProbe.run(
                executable: opencode, arguments: ["service", "status"],
                directory: probeDirectory, timeout: 10),
              status.status == 0,
              String(data: status.stdout, encoding: .utf8)?.contains("http") == true
        else { return nil }

        guard let result = await CLIProbe.run(
                executable: opencode, arguments: ["api", "experimental.usage.limits"],
                directory: probeDirectory, timeout: 20),
              result.status == 0
        else {
            lastFailure = L10n.text("opencode did not answer the usage-limits request", zhHans: "opencode 未响应用量额度请求")
            return staleCache()
        }
        // Signed out / no Go plan come back as a snapshot with `planStatus`, so the card can
        // say why there is nothing to meter; only an unrecognized answer hides it
        guard let snapshot = Self.parseLimits(result.stdout) else {
            cached = nil
            return nil
        }
        cached = snapshot
        return snapshot
    }

    private func staleCache() -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = true
        return cached
    }

    /// `{"location":{…},"data":{"workspace":{…},"go":{"rolling":Meter,"weekly":Meter,
    ///   "monthly":Meter},"budgets":[…]}}` with `Meter = {percent 0-100, limited, resetsAt ms}`.
    /// `data` is null when signed out of OpenCode Console → `planStatus: .signedOut`; a
    /// workspace without `go` has no Go plan → `.noPlan`. Anything else unrecognized → nil.
    /// Console budgets are not shown.
    public static func parseLimits(_ data: Data, now: Date = Date()) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // `opencode api` wraps the body as {location, data}; accept a bare body too
        let info: [String: Any]
        if root.keys.contains("data") {
            guard let body = root["data"] as? [String: Any] else {
                return root["data"] is NSNull
                    ? RateLimitSnapshot(source: .opencode, asOf: now, planStatus: .signedOut)
                    : nil
            }
            info = body
        } else {
            info = root
        }
        guard let go = info["go"] as? [String: Any] else {
            return info["workspace"] is [String: Any]
                ? RateLimitSnapshot(source: .opencode, asOf: now, planStatus: .noPlan)
                : nil
        }

        // Every `{percent, …}` meter under `go` becomes a row, so a meter OpenCode adds later
        // shows up instead of being dropped. Known meters come first in a fixed order and get a
        // length the view can name; an unknown one keeps its key as the label. The rolling
        // meter's length is not in the response: minutes 0, which the view names "Rolling window"
        // when it renders (labels are not stored, so a language switch applies).
        let known: [String: Int] = ["rolling": 0, "daily": 1440, "weekly": 10080, "monthly": 43200]
        let order = ["rolling", "daily", "weekly", "monthly"]
        let keys = order.filter { go[$0] != nil }
            + go.keys.filter { known[$0] == nil }.sorted()
        var windows: [RateLimitWindow] = []
        for key in keys {
            guard let dict = go[key] as? [String: Any],
                  let percent = (dict["percent"] as? NSNumber)?.doubleValue
            else { continue }
            let limited = dict["limited"] as? Bool ?? false
            windows.append(RateLimitWindow(
                usedPercent: limited ? max(percent, 100) : min(100, max(0, percent)),
                windowMinutes: known[key] ?? 0,
                resetsAt: (dict["resetsAt"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                label: known[key] == nil ? key : nil))
        }
        guard !windows.isEmpty else { return nil }
        return RateLimitSnapshot(
            source: .opencode, asOf: now, planType: "Go", scopedWindows: windows)
    }
}
