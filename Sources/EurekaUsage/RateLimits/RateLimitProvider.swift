import Foundation
import EurekaKit

/// Rate-limit data provider. nil = data unavailable, and the UI must hide the whole block (the
/// shared graceful-degradation convention).
/// Implementations: CodexRateLimitProvider (local rollout snapshot, zero network),
/// ClaudeOAuthUsageProvider (opt-in, unofficial endpoint),
/// GrokRateLimitProvider (local log snapshot, zero network).
/// Note: the caller (RateLimitsService) refreshes serially, so providers need not be Sendable.
public protocol RateLimitProvider {
    var source: AgentSource { get }
    func snapshot() async -> RateLimitSnapshot?
}
