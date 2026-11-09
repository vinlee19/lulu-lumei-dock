import Foundation

/// A single rate-limit window (5-hour / weekly)
public struct RateLimitWindow: Equatable, Sendable, Codable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?
    /// Custom window name (Antigravity splits quota by model family, not 5h/weekly windows); nil =
    /// derive from windowMinutes
    public var label: String?
    /// Model bucket a scoped window counts against (Claude's per-model weekly caps, e.g. "Fable",
    /// "Opus"); nil = the window covers every model. The UI composes "Weekly · Fable" from it.
    public var scope: String?
    /// This window's cap as a percentage (0-100) of its parent window's allowance (Claude
    /// `weekly_scoped_shares.allowance_percent_of_weekly`); nil = unknown
    public var capShareOfParent: Double?

    public init(
        usedPercent: Double, windowMinutes: Int, resetsAt: Date? = nil, label: String? = nil,
        scope: String? = nil, capShareOfParent: Double? = nil
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.label = label
        self.scope = scope
        self.capShareOfParent = capShareOfParent
    }

    /// The window has rolled over since the snapshot was taken, so `usedPercent` describes a
    /// window that no longer exists. Unknown `resetsAt` cannot be judged and counts as live.
    public func hasReset(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// Paid capacity beyond the plan's windows: Claude extra usage, Codex credits, Grok
/// pay-as-you-go. Providers return nil when there is nothing worth showing (never enabled and
/// nothing spent), matching the nil-hides convention of the snapshot itself.
public struct RateLimitCredits: Equatable, Sendable, Codable {
    public var isEnabled: Bool
    public var isUnlimited: Bool
    /// Spent in the current period, in major units of `currency` (or credits when it is nil)
    public var used: Double?
    /// Spending cap for the period, same unit as `used`
    public var limit: Double?
    /// Prepaid balance left, same unit as `used`
    public var balance: Double?
    /// ISO 4217 code for money amounts; nil = a plain credit count (Codex)
    public var currency: String?
    /// Server reason code while disabled (Claude `disabled_reason`, e.g. "out_of_credits")
    public var disabledReason: String?

    public init(
        isEnabled: Bool, isUnlimited: Bool = false, used: Double? = nil, limit: Double? = nil,
        balance: Double? = nil, currency: String? = nil, disabledReason: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.isUnlimited = isUnlimited
        self.used = used
        self.limit = limit
        self.balance = balance
        self.currency = currency
        self.disabledReason = disabledReason
    }
}

/// Why a source has no windows to show although it answered (the card then says so instead of
/// hiding). Stored as a code; the view words it in the current language.
public enum RateLimitPlanStatus: String, Equatable, Sendable, Codable {
    /// Not signed in to the account that would carry the plan (OpenCode Console)
    case signedOut
    /// Signed in, but the account has no such plan (no OpenCode Go)
    case noPlan
}

/// Rate-limit snapshot for one source. When a provider returns nil the whole UI block hides
/// (graceful-degradation contract).
public struct RateLimitSnapshot: Equatable, Sendable, Codable {
    public var source: AgentSource
    public var asOf: Date
    public var planType: String?
    /// Short window (usually 5h = 300 minutes)
    public var primary: RateLimitWindow?
    /// Long window (usually 7 days = 10080 minutes)
    public var secondary: RateLimitWindow?
    /// Extra per-model windows (each carries `scope`); not sampled for forecasts
    public var scopedWindows: [RateLimitWindow]
    /// Paid overflow beyond the windows; nil = nothing worth showing
    public var credits: RateLimitCredits?
    /// Set when the source answered but has no plan to meter (the card explains instead of hiding)
    public var planStatus: RateLimitPlanStatus?
    /// Whether the data is stale (cache of the last successful value)
    public var isStale: Bool

    public init(
        source: AgentSource,
        asOf: Date,
        planType: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        scopedWindows: [RateLimitWindow] = [],
        credits: RateLimitCredits? = nil,
        planStatus: RateLimitPlanStatus? = nil,
        isStale: Bool = false
    ) {
        self.source = source
        self.asOf = asOf
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.scopedWindows = scopedWindows
        self.credits = credits
        self.planStatus = planStatus
        self.isStale = isStale
    }
}

/// Codex `token_count.rate_limits` → snapshot. Shared by the rollout tailer (EurekaIngest) and
/// the limits provider (EurekaUsage) so the two readers cannot drift apart.
public enum CodexRateLimitParsing {
    public static func snapshot(limits: [String: Any], asOf: Date) -> RateLimitSnapshot {
        func window(_ key: String) -> RateLimitWindow? {
            guard let dict = limits[key] as? [String: Any],
                  let usedPercent = (dict["used_percent"] as? NSNumber)?.doubleValue
            else { return nil }
            return RateLimitWindow(
                usedPercent: usedPercent,
                windowMinutes: (dict["window_minutes"] as? NSNumber)?.intValue ?? 0,
                resetsAt: (dict["resets_at"] as? NSNumber)
                    .map { Date(timeIntervalSince1970: $0.doubleValue) }
            )
        }
        return RateLimitSnapshot(
            source: .codex,
            asOf: asOf,
            planType: limits["plan_type"] as? String,
            primary: window("primary"),
            secondary: window("secondary"),
            credits: credits(limits["credits"] as? [String: Any])
        )
    }

    /// `{has_credits, unlimited, balance: "120"}`; `balance` is a decimal string counting credits
    /// (the Codex CLI shows it as "Balance credits"), not money. nil when there is nothing to show.
    static func credits(_ dict: [String: Any]?) -> RateLimitCredits? {
        guard let dict else { return nil }
        let hasCredits = dict["has_credits"] as? Bool ?? false
        let unlimited = dict["unlimited"] as? Bool ?? false
        let balance: Double? = (dict["balance"] as? String).flatMap(Double.init)
            ?? (dict["balance"] as? NSNumber)?.doubleValue
        guard hasCredits || unlimited || (balance ?? 0) > 0 else { return nil }
        return RateLimitCredits(
            isEnabled: hasCredits || unlimited, isUnlimited: unlimited, balance: balance)
    }
}
