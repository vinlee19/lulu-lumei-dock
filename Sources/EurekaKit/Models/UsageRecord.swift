import Foundation

/// Token usage of one API call (the unified accounting unit across both vendors)
public struct UsageRecord: Equatable, Sendable {
    public var source: AgentSource
    public var model: String
    /// Project name (grouped by repo root), for per-project stats
    public var project: String?
    /// Session id, for per-session cost stats
    public var sessionId: String?
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    /// Total tokens written to cache (Claude cache_creation_input_tokens)
    public var cacheCreationTokens: Int
    /// The 1h-TTL portion of it (priced 2x; the 5m portion = total - 1h portion, priced 1.25x)
    public var cacheCreation1hTokens: Int
    /// Cache reads (Claude cache_read / Codex cached_input)
    public var cacheReadTokens: Int
    /// Billing provider (opencode providerID / codex model_provider / hermes billing_provider...),
    /// tells whether a same-named model runs on a subscription plan or pay-as-you-go; nil for
    /// sources without it
    public var provider: String?
    /// The agent's self-reported cost for this record (USD). When set it wins over the price table
    /// (Grok's costUsdTicks already includes build-model real prices and tiers, which have no entry
    /// in the price catalog); nil for other sources
    public var reportedCostUSD: Double?

    public init(
        source: AgentSource,
        model: String,
        project: String? = nil,
        sessionId: String? = nil,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        cacheReadTokens: Int = 0,
        provider: String? = nil,
        reportedCostUSD: Double? = nil
    ) {
        self.source = source
        self.model = model
        self.project = project
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
        self.provider = provider
        self.reportedCostUSD = reportedCostUSD
    }
}
