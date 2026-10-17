import Foundation

/// Menu-bar title assembly (pure function): task count + optional rate-limit percentage.
/// Shaped like `✦ 37%` / `▶2 · 37%` / `⏳1 · 88%`.
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

    /// Take the max 5h-window usage across all available sources (the one that tops out first is what matters).
    /// Windows whose reset time has passed are skipped: a week-old Codex snapshot would
    /// otherwise pin a dead "9%" on the menu bar and the sidebar badge.
    public static func maxPrimaryPercent(
        _ snapshots: [RateLimitSnapshot?], now: Date = Date()
    ) -> Double? {
        snapshots
            .compactMap { $0?.primary }
            .filter { !$0.hasReset(at: now) }
            .map(\.usedPercent)
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
