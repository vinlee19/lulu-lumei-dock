import Foundation
import EurekaKit

/// 限额数据提供方。返回 nil = 数据不可得，UI 必须整块隐藏（优雅降级统一约定）。
/// M6 实现 CodexRateLimitProvider（本地 rollout 快照）与
/// ClaudeOAuthUsageProvider（opt-in，非官方接口）。
public protocol RateLimitProvider: Sendable {
    var source: AgentSource { get }
    func snapshot() async -> RateLimitSnapshot?
}
