import EurekaKit
import Foundation
import os

/// Claude subscription rate limits: **unofficial endpoint, off by default, opt-in in Settings**.
/// Credentials are read via the `/usr/bin/security` subprocess (the prompt's subject is Apple's
/// signed security tool,
/// silent after one "Always Allow" - avoids repeated Keychain ACL prompts after ad-hoc re-signing).
/// Any failure → returns nil → the whole UI block hides; never refreshes the token itself (racing
/// Claude Code
/// would invalidate the refresh token); on 401 the user is told to run claude once.
///
/// The endpoint is rate-limited per account and Claude Code polls it too. A burst of requests
/// (five page opens in 90 s, 2026-11-09) put the app into a 429 penalty that its 5-minute timer
/// and every relaunch kept renewing. So: requests are at least `minInterval` apart, a 429 backs
/// off (5 → 10 → 20 → 40 → 60 min, longer if `Retry-After` says so) with no request at all until
/// then - not even from the refresh button - and the last answer plus the backoff survive a
/// relaunch (`persistedState` / `restore`), so a restart neither hides the card nor re-knocks.
public final class ClaudeOAuthUsageProvider: RateLimitProvider {
    public typealias Fetch = (URLRequest) async throws -> (Data, URLResponse)

    public let source = AgentSource.claude

    /// Most recent failure reason (for UI hints; nil = OK)
    public private(set) var lastFailure: String?

    /// Shortest gap between two requests (Claude Code throttles itself to 60 s too), so page opens
    /// and the refresh button inside this gap reuse the last answer.
    public static let minInterval: TimeInterval = 60
    /// Longest wait after a 429, whatever `Retry-After` says
    public static let maxBackoff: TimeInterval = 3600
    /// A backoff ending within this much of a timer tick counts as over, so a 300 s wait is not
    /// missed by a tick that fires at 299.9 s
    static let tickSlack: TimeInterval = 10
    /// After a relaunch, a saved answer younger than this is reused instead of asking at once: the
    /// endpoint allows about one request per few minutes, and a launch right after the previous
    /// instance's refresh drew a 429 (2026-11-09, 69 s after a success)
    public static let relaunchReuse: TimeInterval = 300

    /// What must survive a relaunch
    public struct PersistedState: Codable, Equatable, Sendable {
        public var lastSnapshot: RateLimitSnapshot?
        public var lastAttemptAt: Date?
        public var nextAllowedAt: Date?
        public var consecutiveRateLimits: Int

        public init(
            lastSnapshot: RateLimitSnapshot? = nil, lastAttemptAt: Date? = nil,
            nextAllowedAt: Date? = nil, consecutiveRateLimits: Int = 0
        ) {
            self.lastSnapshot = lastSnapshot
            self.lastAttemptAt = lastAttemptAt
            self.nextAllowedAt = nextAllowedAt
            self.consecutiveRateLimits = consecutiveRateLimits
        }
    }

    private var cached: RateLimitSnapshot?
    private var lastAttemptAt: Date?
    private var nextAllowedAt: Date?
    private var consecutiveRateLimits = 0
    /// Set by `restore`: until then the saved answer stands in for a fresh request
    private var reuseUntil: Date?

    /// Claude Code's own copy of this endpoint's answer is used instead of a request while it is
    /// at most this old. Every running Claude Code session polls the endpoint and they share one
    /// per-account budget (10 sessions on 2026-11-09 kept this app at 429), so reading their
    /// cached answer costs nothing and loses nothing.
    public static let claudeCodeCacheMaxAge: TimeInterval = 600

    private let fetch: Fetch
    private let credentials: () -> ClaudeCredentials?
    private let claudeCodeConfig: () -> Data?
    private let clock: () -> Date
    private static let log = Logger(subsystem: "com.vinlee.eureka", category: "limits")

    /// Tests inject `fetch`, `credentials` and `claudeCodeConfig` so they never touch the
    /// network, the Keychain or the real ~/.claude.json
    public init(
        fetch: Fetch? = nil,
        credentials: (() -> ClaudeCredentials?)? = nil,
        claudeCodeConfig: (() -> Data?)? = nil,
        clock: @escaping () -> Date = Date.init
    ) {
        self.fetch = fetch ?? { try await URLSession.shared.data(for: $0) }
        self.credentials = credentials ?? { ClaudeOAuthUsageProvider.readCredentials() }
        self.claudeCodeConfig = claudeCodeConfig ?? ClaudeCodeConfigFile().read
        self.clock = clock
    }

    public var persistedState: PersistedState {
        PersistedState(
            lastSnapshot: cached, lastAttemptAt: lastAttemptAt, nextAllowedAt: nextAllowedAt,
            consecutiveRateLimits: consecutiveRateLimits)
    }

    /// Seeds the provider after a relaunch; returns what the card can show right away (stale)
    @discardableResult
    public func restore(_ state: PersistedState) -> RateLimitSnapshot? {
        cached = state.lastSnapshot
        lastAttemptAt = state.lastAttemptAt
        nextAllowedAt = state.nextAllowedAt
        consecutiveRateLimits = state.consecutiveRateLimits
        // A streak saved by an older build may carry a shorter wait than the current schedule
        if consecutiveRateLimits > 0, let lastAttemptAt {
            let scheduled = lastAttemptAt.addingTimeInterval(
                Self.backoff(afterRateLimits: consecutiveRateLimits))
            nextAllowedAt = max(nextAllowedAt ?? scheduled, scheduled)
        } else if let saved = state.lastSnapshot {
            reuseUntil = saved.asOf.addingTimeInterval(Self.relaunchReuse - Self.tickSlack)
        }
        if let nextAllowedAt, clock() < nextAllowedAt {
            lastFailure = Self.rateLimitedHint(until: nextAllowedAt)
        }
        return staleCache()
    }

    public func snapshot() async -> RateLimitSnapshot? {
        let now = clock()
        // Claude Code's cached answer first: fresh enough → no request at all, even mid-backoff
        if let local = claudeCodeConfig().flatMap({ Self.parseClaudeCodeCache($0) }) {
            if local.asOf >= (cached?.asOf ?? .distantPast) {
                var adopted = local
                adopted.planType = local.planType ?? cached?.planType
                cached = adopted
            }
            if now.timeIntervalSince(local.asOf) <= Self.claudeCodeCacheMaxAge {
                lastFailure = nil
                return freshCache(now: now)
            }
        }
        // Backing off after a 429: no request at all until the wait is over
        if let nextAllowedAt, now < nextAllowedAt.addingTimeInterval(-Self.tickSlack) {
            lastFailure = Self.rateLimitedHint(until: nextAllowedAt)
            return staleCache()
        }
        if let reuseUntil, now < reuseUntil {
            return freshCache(now: now)
        }
        reuseUntil = nil
        if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.minInterval {
            return lastFailure == nil ? freshCache(now: now) : staleCache()
        }
        lastAttemptAt = now
        guard let credentials = credentials() else {
            lastFailure = L10n.text("Could not read Claude Code credentials from Keychain", zhHans: "未能从钥匙串读取 Claude Code 凭证")
            Self.log.notice("claude usage: credentials unreadable")
            return staleCache()
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10

        do {
            let (data, response) = try await fetch(request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if status == 429 {
                consecutiveRateLimits += 1
                let header = http?.value(forHTTPHeaderField: "Retry-After")
                // The server answers 429 with `Retry-After: 0` (observed 2026-11-09), so the header
                // may lengthen our own schedule but never shorten it
                let wait = max(
                    Self.retryAfter(header, now: now) ?? 0,
                    Self.backoff(afterRateLimits: consecutiveRateLimits))
                let until = now.addingTimeInterval(min(max(wait, Self.minInterval), Self.maxBackoff))
                nextAllowedAt = until
                lastFailure = Self.rateLimitedHint(until: until)
                Self.log.notice("claude usage: HTTP 429 #\(self.consecutiveRateLimits, privacy: .public) retry-after=\(header ?? "-", privacy: .public) next=\(until.timeIntervalSince1970, privacy: .public)")
                return staleCache()
            }
            if status == 401 || status == 403 {
                lastFailure = L10n.format("Credentials expired (%@): run claude once to refresh the login", zhHans: "凭证过期（%@）：跑一次 claude 让它刷新登录态", String(status))
                Self.log.notice("claude usage: HTTP \(status, privacy: .public)")
                return staleCache()
            }
            guard status == 200 else {
                lastFailure = L10n.format("The API returned %@ (the unofficial API may have changed)", zhHans: "接口返回 %@（非官方接口可能已变更）", String(status))
                Self.log.notice("claude usage: HTTP \(status, privacy: .public)")
                return staleCache()
            }
            guard var snapshot = Self.parseUsageResponse(data, now: now) else {
                lastFailure = L10n.text("Unrecognized response format (the unofficial API may have changed)", zhHans: "响应格式无法识别（非官方接口可能已变更）")
                Self.log.notice("claude usage: unrecognized response")
                return staleCache()
            }
            // The usage response carries no plan; the credential record does
            snapshot.planType = snapshot.planType ?? Self.planLabel(
                subscriptionType: credentials.subscriptionType,
                rateLimitTier: credentials.rateLimitTier)
            lastFailure = nil
            consecutiveRateLimits = 0
            nextAllowedAt = nil
            cached = snapshot
            return snapshot
        } catch {
            lastFailure = L10n.format("Request failed: %@", zhHans: "请求失败：%@", String(error.localizedDescription))
            Self.log.notice("claude usage: request failed \((error as NSError).code, privacy: .public)")
            return staleCache()
        }
    }

    /// Wait after the n-th 429 in a row when the server gives no `Retry-After`
    public static func backoff(afterRateLimits count: Int) -> TimeInterval {
        let minutes = min(5 * pow(2, Double(max(0, count - 1))), maxBackoff / 60)
        return minutes * 60
    }

    /// `Retry-After` as seconds or an HTTP date; nil when absent or unreadable
    public static func retryAfter(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty
        else { return nil }
        if let seconds = TimeInterval(header) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }

    private static func rateLimitedHint(until: Date) -> String {
        L10n.format("Rate-limited by the API (429); showing the last values, next try after %@", zhHans: "接口限流（429）：先显示上次数值，%@ 后再试", until.formatted(date: .omitted, time: .shortened))
    }

    /// Within `minInterval` of a success: the cached answer, stale once it is over 10 minutes old
    /// (a value restored after a relaunch)
    private func freshCache(now: Date) -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = now.timeIntervalSince(cached.asOf) > 600
        return cached
    }

    /// On failure, returns the last successful value (marked stale); nil if there is no cache at
    /// all (UI hides)
    private func staleCache() -> RateLimitSnapshot? {
        guard var cached else { return nil }
        cached.isStale = true
        return cached
    }

    // MARK: - Credentials

    /// The fields read from Claude Code's credential record. The token only ever goes into the
    /// request header - never into logs, hints, or the UI.
    public struct ClaudeCredentials: Equatable, Sendable {
        public var accessToken: String
        /// "pro" / "max" / "team" / "enterprise"
        public var subscriptionType: String?
        /// e.g. "default_claude_max_5x"
        public var rateLimitTier: String?

        public init(accessToken: String, subscriptionType: String?, rateLimitTier: String?) {
            self.accessToken = accessToken
            self.subscriptionType = subscriptionType
            self.rateLimitTier = rateLimitTier
        }
    }

    /// The Keychain item "Claude Code-credentials" holds JSON
    static func readCredentials() -> ClaudeCredentials? {
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
        return String(data: data, encoding: .utf8).flatMap(parseCredentials)
    }

    /// Takes `claudeAiOauth.{accessToken, subscriptionType, rateLimitTier}`; a flat record (no
    /// `claudeAiOauth` wrapper) is accepted too. nil without an access token.
    public static func parseCredentials(_ raw: String) -> ClaudeCredentials? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let json = try? JSONSerialization.jsonObject(
            with: Data(trimmed.utf8)) as? [String: Any]
        else { return nil }
        let oauth = (json["claudeAiOauth"] as? [String: Any]) ?? json
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return ClaudeCredentials(
            accessToken: token,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String)
    }

    /// Plan badge: "Team · Max 5x" / "Max 20x" / "Pro". The tier carries the Max multiplier
    /// (`default_claude_max_5x`); team / enterprise seats can sit on a Max tier, so both parts
    /// show. Product names are not localized.
    public static func planLabel(subscriptionType: String?, rateLimitTier: String?) -> String? {
        let subscription = subscriptionType?.trimmingCharacters(in: .whitespaces).lowercased()
            .nilIfEmpty
        let maxTier: String? = rateLimitTier.flatMap { tier in
            guard let range = tier.range(
                of: #"max_(\d+)x"#, options: [.regularExpression, .caseInsensitive])
            else { return nil }
            let digits = tier[range].dropFirst("max_".count).dropLast()
            return "Max \(digits)x"
        }
        let base: String? = subscription.map { name in
            switch name {
            case "pro": return "Pro"
            case "max": return "Max"
            case "team": return "Team"
            case "enterprise": return "Enterprise"
            default: return name.prefix(1).uppercased() + name.dropFirst()
            }
        }
        switch (base, maxTier) {
        case let (.some(base), .some(tier)):
            // "Max" + "Max 5x" says the same thing twice
            return base == "Max" ? tier : "\(base) · \(tier)"
        case let (.some(base), nil): return base
        case let (nil, .some(tier)): return tier
        case (nil, nil): return nil
        }
    }

    // MARK: - Claude Code's cached answer

    /// `~/.claude.json` → `cachedUsageUtilization: {fetchedAtMs, accountUuid, utilization}`, the
    /// last answer Claude Code got from this endpoint (written at most once a minute, shape as in
    /// `parseUsageResponse`). Ignored when it belongs to another account than `oauthAccount`.
    /// The plan comes from `oauthAccount.organizationType` + `userRateLimitTier`. Only these
    /// fields are read; the rest of the file (email, name, projects) is never touched.
    public static func parseClaudeCodeCache(_ data: Data) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cache = root["cachedUsageUtilization"] as? [String: Any],
              let fetchedMs = (cache["fetchedAtMs"] as? NSNumber)?.doubleValue,
              let utilization = cache["utilization"] as? [String: Any],
              let body = try? JSONSerialization.data(withJSONObject: utilization)
        else { return nil }
        let account = root["oauthAccount"] as? [String: Any]
        if let cacheAccount = cache["accountUuid"] as? String,
           let currentAccount = account?["accountUuid"] as? String,
           cacheAccount != currentAccount {
            return nil
        }
        let fetchedAt = Date(timeIntervalSince1970: fetchedMs / 1000)
        guard var snapshot = parseUsageResponse(body, now: fetchedAt) else { return nil }
        let organization = (account?["organizationType"] as? String)
            .map { $0.hasPrefix("claude_") ? String($0.dropFirst("claude_".count)) : $0 }
        let tier = account?["userRateLimitTier"] as? String
            ?? account?["organizationRateLimitTier"] as? String
        snapshot.planType = planLabel(subscriptionType: organization, rateLimitTier: tier)
        return snapshot
    }

    // MARK: - Lenient parsing

    /// Known shape (observed in Claude Code 2.1.319's own cached copy of this response, may
    /// change at any time):
    /// `{"five_hour":{"utilization":1,"resets_at":"2026-11-09T09:09:59.761720+00:00"},
    ///   "seven_day":{...}, "seven_day_opus":null, "seven_day_sonnet":null,
    ///   "limits":[{"kind":"weekly_scoped","percent":0,"resets_at":"…",
    ///              "scope":{"model":{"display_name":"Fable"}}}, …],
    ///   "weekly_scoped_shares":[{"limit_index":2,"allowance_percent_of_weekly":50}],
    ///   "extra_usage":{"is_enabled":false,"monthly_limit":null,"used_credits":null,
    ///                  "currency":"USD","decimal_places":2,"disabled_reason":"out_of_credits"}}`
    /// `utilization` is a 0-100 percentage, never a 0-1 fraction: `seven_day.utilization: 1` sits
    /// next to `limits[weekly_all].percent: 1`, and Claude Code renders it as "1% used". Reading
    /// values <= 1 as fractions turned every 1% into 100%.
    public static func parseUsageResponse(_ data: Data, now: Date = Date()) -> RateLimitSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        func window(_ keys: [String], minutes: Int) -> RateLimitWindow? {
            for key in keys {
                guard let dict = root[key] as? [String: Any] else { continue }
                guard let percent = number(dict["utilization"]) ?? number(dict["used_percent"])
                else { continue }
                return RateLimitWindow(
                    usedPercent: percent, windowMinutes: minutes,
                    resetsAt: date(dict["resets_at"]))
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
            secondary: sevenDay,
            scopedWindows: scopedWindows(root),
            credits: extraUsage(root["extra_usage"] as? [String: Any])
        )
    }

    /// Per-model weekly caps. `limits[]` rows of kind `weekly_scoped` come first (with their share
    /// of the weekly allowance from `weekly_scoped_shares`), then the older `seven_day_opus` /
    /// `seven_day_sonnet` keys for buckets `limits[]` did not already name.
    static func scopedWindows(_ root: [String: Any]) -> [RateLimitWindow] {
        var shares: [Int: Double] = [:]
        for share in root["weekly_scoped_shares"] as? [[String: Any]] ?? [] {
            if let index = number(share["limit_index"]),
               let allowance = number(share["allowance_percent_of_weekly"]) {
                shares[Int(index)] = allowance
            }
        }

        var windows: [RateLimitWindow] = []
        var seen = Set<String>()
        for (index, limit) in (root["limits"] as? [[String: Any]] ?? []).enumerated() {
            guard limit["kind"] as? String == "weekly_scoped",
                  let scope = limit["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?
                      .trimmingCharacters(in: .whitespaces).nilIfEmpty,
                  let percent = number(limit["percent"]),
                  !seen.contains(name.lowercased())
            else { continue }
            seen.insert(name.lowercased())
            windows.append(RateLimitWindow(
                usedPercent: percent, windowMinutes: 10080,
                resetsAt: date(limit["resets_at"]),
                scope: name, capShareOfParent: shares[index]))
        }

        for (key, name) in [("seven_day_opus", "Opus"), ("seven_day_sonnet", "Sonnet")] {
            guard !seen.contains(name.lowercased()),
                  let dict = root[key] as? [String: Any],
                  let percent = number(dict["utilization"])
            else { continue }
            seen.insert(name.lowercased())
            windows.append(RateLimitWindow(
                usedPercent: percent, windowMinutes: 10080,
                resetsAt: date(dict["resets_at"]), scope: name))
        }
        return windows
    }

    /// `extra_usage` amounts are minor units of `currency` (`decimal_places`, cents for USD).
    /// nil when extra usage was never turned on and nothing was spent - nothing to tell the user.
    static func extraUsage(_ dict: [String: Any]?) -> RateLimitCredits? {
        guard let dict else { return nil }
        let isEnabled = dict["is_enabled"] as? Bool ?? false
        let everEnabled = dict["credits_ever_enabled"] as? Bool ?? false
        let decimals = number(dict["decimal_places"]).map(Int.init) ?? 2
        let scale = pow(10, Double(max(0, min(decimals, 6))))
        let used = number(dict["used_credits"]).map { $0 / scale }
        let limit = number(dict["monthly_limit"]).map { $0 / scale }
        guard isEnabled || everEnabled || (used ?? 0) > 0 else { return nil }
        return RateLimitCredits(
            isEnabled: isEnabled,
            used: used,
            limit: limit,
            currency: (dict["currency"] as? String)?.uppercased().nilIfEmpty ?? "USD",
            disabledReason: isEnabled ? nil : (dict["disabled_reason"] as? String)?.nilIfEmpty)
    }

    /// JSON numbers arrive as NSNumber; Bool is an NSNumber too and must not count as one
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        return number.doubleValue
    }

    /// `resets_at`: ISO 8601 with or without fractional seconds (six digits observed), or epoch
    /// seconds
    private static func date(_ value: Any?) -> Date? {
        if let string = value as? String {
            return isoPlain.date(from: string) ?? isoFractional.date(from: string)
        }
        return number(value).map { Date(timeIntervalSince1970: $0) }
    }

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
    private static let isoFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Reads `~/.claude.json` only when it changed (it is a few hundred KB and Claude Code rewrites it
/// often), handing back the bytes for `parseClaudeCodeCache`. Not thread-safe on purpose: the
/// provider is driven serially by RateLimitsService.
final class ClaudeCodeConfigFile {
    private let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude.json")
    private var fingerprint: (mtime: Date, size: Int)?
    private var last: Data?

    func read() -> Data? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let mtime = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        if let fingerprint, fingerprint.mtime == mtime, fingerprint.size == size { return last }
        let data = try? Data(contentsOf: url)
        fingerprint = (mtime, size)
        last = data
        return data
    }
}
