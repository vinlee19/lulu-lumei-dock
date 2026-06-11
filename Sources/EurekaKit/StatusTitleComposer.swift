import Foundation

/// 菜单栏标题组装（纯函数）：任务计数 + 可选的限额百分比。
/// 形如 `✦ 37%` / `▶2 · 37%` / `⏳1 · 88%`。
public enum StatusTitleComposer {
    public enum Tier: Equatable, Sendable {
        case normal
        case warning   // ≥60%
        case critical  // ≥85%
    }

    public struct Title: Equatable, Sendable {
        public var base: String
        public var percent: String?
        public var tier: Tier

        public var combined: String {
            guard let percent else { return base }
            return "\(base) · \(percent)"
        }
    }

    /// 所有可用来源 5h 窗口用量取最大（最先见顶的才要紧）
    public static func maxPrimaryPercent(_ snapshots: [RateLimitSnapshot?]) -> Double? {
        snapshots
            .compactMap { $0?.primary?.usedPercent }
            .max()
    }

    public static func compose(
        taskCount: Int,
        hasWaiting: Bool,
        maxUsedPercent: Double?,
        showLimit: Bool
    ) -> Title {
        let base: String
        if taskCount == 0 {
            base = "✦"
        } else if hasWaiting {
            base = "⏳\(taskCount)"
        } else {
            base = "▶\(taskCount)"
        }

        guard showLimit, let percent = maxUsedPercent else {
            return Title(base: base, percent: nil, tier: .normal)
        }
        let tier: Tier
        switch percent {
        case ..<60: tier = .normal
        case ..<85: tier = .warning
        default: tier = .critical
        }
        return Title(base: base, percent: "\(Int(percent.rounded()))%", tier: tier)
    }
}
