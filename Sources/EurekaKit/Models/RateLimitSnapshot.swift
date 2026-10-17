import Foundation

/// A single rate-limit window (5-hour / weekly)
public struct RateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?
    /// Custom window name (Antigravity splits quota by model family, not 5h/weekly windows); nil =
    /// derive from windowMinutes
    public var label: String?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date? = nil, label: String? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.label = label
    }

    /// The window has rolled over since the snapshot was taken, so `usedPercent` describes a
    /// window that no longer exists. Unknown `resetsAt` cannot be judged and counts as live.
    public func hasReset(at now: Date = Date()) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }
}

/// Rate-limit snapshot for one source. When a provider returns nil the whole UI block hides
/// (graceful-degradation contract).
public struct RateLimitSnapshot: Equatable, Sendable {
    public var source: AgentSource
    public var asOf: Date
    public var planType: String?
    /// Short window (usually 5h = 300 minutes)
    public var primary: RateLimitWindow?
    /// Long window (usually 7 days = 10080 minutes)
    public var secondary: RateLimitWindow?
    /// Whether the data is stale (cache of the last successful value)
    public var isStale: Bool

    public init(
        source: AgentSource,
        asOf: Date,
        planType: String? = nil,
        primary: RateLimitWindow? = nil,
        secondary: RateLimitWindow? = nil,
        isStale: Bool = false
    ) {
        self.source = source
        self.asOf = asOf
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
        self.isStale = isStale
    }
}
