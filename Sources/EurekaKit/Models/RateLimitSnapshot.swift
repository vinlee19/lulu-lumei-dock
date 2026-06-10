import Foundation

/// 单个限额窗口（5 小时 / 每周）
public struct RateLimitWindow: Equatable, Sendable {
    public var usedPercent: Double
    public var windowMinutes: Int
    public var resetsAt: Date?

    public init(usedPercent: Double, windowMinutes: Int, resetsAt: Date? = nil) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
    }
}

/// 某个来源的限额快照。Provider 返回 nil 时 UI 整块隐藏（优雅降级约定）。
public struct RateLimitSnapshot: Equatable, Sendable {
    public var source: AgentSource
    public var asOf: Date
    public var planType: String?
    /// 短窗口（通常 5h = 300 分钟）
    public var primary: RateLimitWindow?
    /// 长窗口（通常 7 天 = 10080 分钟）
    public var secondary: RateLimitWindow?
    /// 数据是否过期（上次成功值的缓存）
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
