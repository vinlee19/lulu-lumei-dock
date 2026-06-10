import Foundation
import EurekaKit

/// 限额数据提供方。返回 nil = 数据不可得，UI 必须整块隐藏（优雅降级统一约定）。
/// 实现：CodexRateLimitProvider（本地 rollout 快照，零网络）、
/// ClaudeOAuthUsageProvider（opt-in，非官方接口）。
/// 注意：调用方（RateLimitsService）串行刷新，provider 无需 Sendable。
public protocol RateLimitProvider {
    var source: AgentSource { get }
    func snapshot() async -> RateLimitSnapshot?
}
