import Foundation
import EurekaKit

/// Claude subscription rate limits: **unofficial endpoint, off by default, opt-in in Settings**.
/// Credentials are read via the `/usr/bin/security` subprocess (the prompt's subject is Apple's
/// signed security tool,
/// silent after one "Always Allow" - avoids repeated Keychain ACL prompts after ad-hoc re-signing).
/// Any failure → returns nil → the whole UI block hides; never refreshes the token itself (racing
/// Claude Code
/// would invalidate the refresh token); on 401 the user is told to run claude once.
public final class ClaudeOAuthUsageProvider: RateLimitProvider {
    public let source = AgentSource.claude

    /// Most recent failure reason (for UI hints; nil = OK)
    public private(set) var lastFailure: String?
    private var cached: RateLimitSnapshot?

    public init() {}

    public func snapshot() async -> RateLimitSnapshot? {
        guard let token = Self.readAccessToken() else {
            lastFailure = L10n.text("Could not read Claude Code credentials from Keychain", zhHans: "未能从钥匙串读取 Claude Code 凭证")
            return staleCache()
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 401 || status == 403 {
                lastFailure = L10n.format("Credentials expired (%@): run claude once to refresh the login", zhHans: "凭证过期（%@）：跑一次 claude 让它刷新登录态", String(status))
                return staleCache()
            }
            guard status == 200 else {
                lastFailure = L10n.format("The API returned %@ (the unofficial API may have changed)", zhHans: "接口返回 %@（非官方接口可能已变更）", String(status))
                return staleCache()
            }
            guard let snapshot = Self.parseUsageResponse(data) else {
                lastFailure = L10n.text("Unrecognized response format (the unofficial API may have changed)", zhHans: "响应格式无法识别（非官方接口可能已变更）")
                return staleCache()
            }
            lastFailure = nil
            cached = snapshot
            return snapshot
        } catch {
            lastFailure = L10n.format("Request failed: %@", zhHans: "请求失败：%@", String(error.localizedDescription))
            return staleCache()
        }
    }

    /// On failure, returns the last successful value (marked stale); nil if there is no cache at
    /// all (UI hides)
    private func staleCache() -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = true
        return cached
    }

    // MARK: - Credentials

    /// The Keychain item "Claude Code-credentials" holds JSON;
    /// take claudeAiOauth.accessToken
    static func readAccessToken() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password", "-s", "Claude Code-credentials", "-w",
        ]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        guard
            let raw = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            let json = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any]
        else { return nil }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        return oauth["accessToken"] as? String
    }

    // MARK: - Lenient parsing

    /// Known shape (community observation, may change at any time):
    /// `{"five_hour":{"utilization":32,"resets_at":"2026-06-10T16:00:00Z"},
    ///   "seven_day":{...}, "seven_day_opus":{...}}`
    /// utilization may be a 0-1 fraction or a 0-100 percentage; only recognized fields are read.
    public static func parseUsageResponse(_ data: Data, now: Date = Date()) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ keys: [String], minutes: Int) -> RateLimitWindow? {
            for key in keys {
                guard let dict = root[key] as? [String: Any] else { continue }
                guard let usedRaw = (dict["utilization"] as? Double)
                    ?? (dict["used_percent"] as? Double) else { continue }
                let percent = usedRaw <= 1.0 ? usedRaw * 100 : usedRaw
                var resetsAt: Date?
                if let isoString = dict["resets_at"] as? String {
                    let formatter = ISO8601DateFormatter()
                    resetsAt = formatter.date(from: isoString)
                    if resetsAt == nil {
                        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                        resetsAt = formatter.date(from: isoString)
                    }
                } else if let epoch = dict["resets_at"] as? Double {
                    resetsAt = Date(timeIntervalSince1970: epoch)
                }
                return RateLimitWindow(
                    usedPercent: percent, windowMinutes: minutes, resetsAt: resetsAt)
            }
            return nil
        }

        let fiveHour = window(["five_hour", "fiveHour", "session"], minutes: 300)
        let sevenDay = window(["seven_day", "sevenDay", "weekly"], minutes: 10080)
        guard fiveHour != nil || sevenDay != nil else { return nil }

        return RateLimitSnapshot(
            source: .claude,
            asOf: now,
            planType: root["plan_type"] as? String ?? root["subscription_type"] as? String,
            primary: fiveHour,
            secondary: sevenDay
        )
    }
}
