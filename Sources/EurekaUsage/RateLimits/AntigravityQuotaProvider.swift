import Foundation
import EurekaKit

/// Antigravity quota through agy's own `/usage` command:
/// `agy -p /usage --output-format json`. agy signs in with its own keyring, so Eureka never
/// reads the Antigravity token, and never the IDE's stale `state.vscdb` cache either.
/// Measured on agy 1.5.3: ~5 s (it starts a short-lived local language server and makes a few
/// Google requests), zero model turns, zero tokens, no conversation and no history entry; MCP
/// servers are not started. It still loads the user's agy hooks, so the caller runs it only on
/// demand (Limits page / refresh button), never on a timer.
public final class AntigravityQuotaProvider: RateLimitProvider {
    public let source = AgentSource.antigravity

    /// Most recent failure reason (nil = OK, or agy is simply not installed)
    public private(set) var lastFailure: String?
    private var cached: RateLimitSnapshot?
    /// Working directory and log file of the probe, kept out of the user's agy log folder
    private let probeDirectory: URL

    public init(probeDirectory: URL) {
        self.probeDirectory = probeDirectory
    }

    public func snapshot() async -> RateLimitSnapshot? {
        guard let agy = CLIProbe.locate("agy") else {
            lastFailure = nil
            return nil
        }
        try? FileManager.default.createDirectory(
            at: probeDirectory, withIntermediateDirectories: true)
        let result = await CLIProbe.run(
            executable: agy,
            arguments: [
                "-p", "/usage", "--output-format", "json", "--print-timeout", "30s",
                "--log-file", probeDirectory.appendingPathComponent("agy-usage.log").path,
            ],
            directory: probeDirectory, timeout: 45)
        guard let result else {
            lastFailure = L10n.text("agy /usage did not finish in time", zhHans: "agy /usage 超时未返回")
            return staleCache()
        }
        guard let snapshot = Self.parseUsage(result.stdout) else {
            lastFailure = result.status == 0
                ? L10n.text("agy /usage returned no quota (signed out of Antigravity?)", zhHans: "agy /usage 没有返回额度（Antigravity 未登录？）")
                : L10n.format("agy /usage failed (exit %@)", zhHans: "agy /usage 执行失败（退出码 %@）", String(result.status))
            return staleCache()
        }
        lastFailure = nil
        cached = snapshot
        return snapshot
    }

    private func staleCache() -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = true
        return cached
    }

    /// `{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"name":"Gemini Models",
    ///   "buckets":[{"id":"gemini-weekly","name":"Weekly Limit Remaining","window":"weekly",
    ///   "remaining_fraction":1,"reset_time":"2026-11-16T06:19:45Z"}, …]}, …]}}}`
    /// Each bucket becomes one scoped window: used = (1 - remaining_fraction) × 100, scoped to its
    /// model group. A window kind other than weekly / 5h keeps the bucket's own name as label.
    public static func parseUsage(_ data: Data, now: Date = Date()) -> RateLimitSnapshot? {
        // Be lenient about anything printed before the JSON object
        let body: Data
        if let brace = data.firstIndex(of: UInt8(ascii: "{")) {
            body = data[brace...]
        } else {
            return nil
        }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              (root["status"] as? String).map({ $0 == "SUCCESS" }) ?? true,
              let command = root["command"] as? [String: Any],
              let payload = command["data"] as? [String: Any],
              let groups = payload["groups"] as? [[String: Any]]
        else { return nil }

        var windows: [RateLimitWindow] = []
        for group in groups {
            let groupName = (group["name"] as? String)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                guard let remaining = (bucket["remaining_fraction"] as? NSNumber)?.doubleValue
                else { continue }
                let minutes: Int
                switch (bucket["window"] as? String)?.lowercased() {
                case "weekly": minutes = 10080
                case "5h": minutes = 300
                case "daily": minutes = 1440
                case "monthly": minutes = 43200
                default: minutes = 0
                }
                windows.append(RateLimitWindow(
                    usedPercent: min(100, max(0, (1 - remaining) * 100)),
                    windowMinutes: minutes,
                    resetsAt: (bucket["reset_time"] as? String).flatMap(isoDate),
                    label: minutes == 0 ? bucket["name"] as? String : nil,
                    scope: groupName.isEmpty ? nil : groupName))
            }
        }
        guard !windows.isEmpty else { return nil }
        return RateLimitSnapshot(source: .antigravity, asOf: now, scopedWindows: windows)
    }

    private static func isoDate(_ string: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: string) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string)
    }
}
