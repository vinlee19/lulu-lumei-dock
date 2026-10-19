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
        /// The agent's multiple-choice question (AskUserQuestion), answered by clicking on the
        /// island. Jumps the queue to the top, never auto-dismisses:
        /// the agent is paused waiting for the answer; withdrawn only once answered (on the island
        /// or in Claude)
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
        case .finished: return 0  // baseline value; the slider applies directly
        case .waiting: return 4   // permission/input requests need a clear look: default 6+4=10s
        case .notice: return 5    // wellbeing copy gets ample reading time
        case .alert: return 6     // security alerts stay longer (audit page / Notification Center keep a record)
        case .question: return nil  // withdrawn only when answered / dismissed / the hook gives up
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
