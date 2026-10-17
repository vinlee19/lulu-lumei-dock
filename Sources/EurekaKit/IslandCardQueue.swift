import Foundation

/// Expanded card queue: finished cards queue up and show one at a time (no flooding, pending
/// count capped); waiting cards go to the top and are deduped per task.
/// Pure logic; the auto-dismiss timer is the UI layer's job.
public struct IslandCardQueue: Equatable, Sendable {
    public private(set) var current: IslandState.Card?
    public private(set) var pending: [IslandState.Card] = []

    /// Pending cap for "informational" cards (finished/notice): beyond it the oldest are
    /// dropped (the history page keeps everything). A burst of hundreds of finished events
    /// (observed 2026-09-05: the opencode event table was replayed wholesale) must not pin
    /// the island open for minutes -- each card occupies a full dismiss window, so an
    /// uncapped queue = an island that never collapses.
    /// Waiting/alert cards are exempt: they are already deduped by task / alert id, and they
    /// need user action.
    public static let maxPendingPassive = 5

    public init() {}

    public var pendingCount: Int { pending.count }
    public var isEmpty: Bool { current == nil && pending.isEmpty }

    public mutating func enqueue(_ card: IslandState.Card) {
        switch card {
        case .waiting(let task):
            // Drop the same task's old waiting card first, then let the new one jump the queue
            // (a pending confirmation is more urgent than a finished notification)
            removeWaiting(taskId: task.id)
            if current == nil {
                current = card
            } else {
                pending.insert(card, at: 0)
            }
        case .alert(let alert):
            // The same alert is never enqueued twice; security alerts jump to the top (as
            // urgent as waiting cards)
            guard !alertExists(id: alert.id) else { return }
            if current == nil {
                current = card
            } else {
                pending.insert(card, at: 0)
            }
        case .finished, .notice:
            if current == nil {
                current = card
            } else {
                pending.append(card)
                trimPassiveOverflow()
            }
        }
    }

    private static func isPassive(_ card: IslandState.Card) -> Bool {
        switch card {
        case .finished, .notice: return true
        case .waiting, .alert: return false
        }
    }

    /// When informational cards exceed the cap, drop from the oldest; waiting/alert cards stay
    /// in place
    private mutating func trimPassiveOverflow() {
        var overflow = pending.filter(Self.isPassive).count - Self.maxPendingPassive
        while overflow > 0, let index = pending.firstIndex(where: Self.isPassive) {
            pending.remove(at: index)
            overflow -= 1
        }
    }

    /// Whether the queue (current + pending) already holds an alert card with this id
    private func alertExists(id: String) -> Bool {
        if case .alert(let alert)? = current, alert.id == id { return true }
        return pending.contains {
            if case .alert(let alert) = $0 { return alert.id == id }
            return false
        }
    }

    /// Removes a task's waiting card when it leaves the waiting state (resumed / finished /
    /// session ended)
    public mutating func removeWaiting(taskId: String) {
        pending.removeAll {
            if case .waiting(let task) = $0 { return task.id == taskId }
            return false
        }
        if case .waiting(let task) = current, task.id == taskId {
            current = pending.isEmpty ? nil : pending.removeFirst()
        }
    }

    /// Task ids of all waiting cards in the queue (reconciled against active tasks to clear
    /// cards)
    public var waitingTaskIds: [String] {
        var ids: [String] = []
        if case .waiting(let task)? = current { ids.append(task.id) }
        for card in pending {
            if case .waiting(let task) = card { ids.append(task.id) }
        }
        return ids
    }

    /// Dismisses the current card and advances to the next; returns the new current card
    @discardableResult
    public mutating func advance() -> IslandState.Card? {
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }
}
