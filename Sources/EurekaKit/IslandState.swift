import Foundation

/// Dynamic Island display state (a projection of TaskStore + a snapshot of the card queue)
public struct IslandState: Equatable, Sendable {
    /// Content of the expanded card
    public enum Card: Equatable, Sendable {
        case finished(FinishedTask)
        case waiting(AgentTask)
        /// Care-style notifications such as health tips
        case notice(IslandNotice)
        /// High-risk operation security alert (red card; jumps the queue to the top,
        /// auto-dismisses)
        case alert(RiskAlert)
        /// agent 的选择题（AskUserQuestion），在岛上点选作答。插队置顶、不自动收起：
        /// agent 正停着等答案，收掉了用户就只能干等到 hook 超时
        case question(PendingQuestion)
    }

    /// Active tasks (including waiting), sorted by start time
    public var activeTasks: [AgentTask]
    /// Expanded card currently shown (nil = compact or hidden)
    public var card: Card?
    /// Number of cards queued for display
    public var queuedCardCount: Int

    /// Whether the island is visible (fully hidden when there are no tasks and no card)
    public var isVisible: Bool { !activeTasks.isEmpty || card != nil }

    /// Whether any task is waiting for confirmation (compact state shows a warning colour)
    public var hasWaitingTask: Bool {
        activeTasks.contains { if case .waiting = $0.phase { return true } else { return false } }
    }

    public init(activeTasks: [AgentTask] = [], card: Card? = nil, queuedCardCount: Int = 0) {
        self.activeTasks = activeTasks
        self.card = card
        self.queuedCardCount = queuedCardCount
    }

    public static let hidden = IslandState()
}

// MARK: - Auto-dismiss duration

extension IslandState.Card {
    /// **Extra** seconds before auto-dismiss, added on top of the user's base setting
    /// (`autoDismissSeconds`, 3–15s in Settings). nil = never auto-dismiss.
    ///
    /// Relative offsets instead of hardcoded absolute seconds per card: the slider is what
    /// carries the user's intent. With hardcoded values, a user who sets it to 15s would see
    /// "the waiting card dismisses faster than the finished card", which makes no sense.
    public var autoDismissExtraSeconds: TimeInterval? {
        switch self {
        case .finished: return 0  // 基准值，滑块直接生效
        case .waiting: return 4   // 授权/输入请求要看清：默认 6+4=10s
        case .notice: return 5    // 关怀文案给足阅读时间
        case .alert: return 6     // 安全告警多停一会（审计页与通知中心另有留存）
        case .question: return nil  // 答完 / 回终端 / hook 放弃时才撤
        }
    }

    /// Whether the card auto-dismisses.
    ///
    /// **Starting the timer when a card appears (`refresh`) and restarting it after the mouse
    /// leaves (`setHovering`) must share this single predicate.** Those two places used to
    /// each have their own switch, and `setHovering` missed the waiting card -- so once
    /// waiting cards became auto-dismissing, hovering once and moving away reverted them to
    /// sticky. With the predicate kept here it can't drift again.
    public var autoDismisses: Bool { autoDismissExtraSeconds != nil }
}
