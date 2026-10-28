import Foundation

/// Unread finished: the "✓ N" mark left on the pill after a finished card auto-dismisses.
///
/// A finished card dismissing on time doesn't mean the user saw it -- without this, once the card
/// dismisses nothing on the pill says a session finished (and if that session has also exited, the
/// island hides entirely), so missing those few seconds means nothing can be recovered. Hence:
/// - a card **dismissing on time** doesn't count as read; the mark stays on the pill;
/// - only **clicking that card** / **opening the task list** counts as read;
/// - the session **starting a new turn** (running/waiting again) also clears it: the user is
///   already back in the session.
///
/// Only the latest finish per session is kept (several turns in a row in one session count as 1
/// unread). Pure logic; IslandViewModel projects it for display.
public struct IslandUnreadFinished: Equatable, Sendable {
    /// Ascending by finish time, one entry per session (`AgentTask.key`)
    public private(set) var tasks: [FinishedTask] = []

    public init() {}

    public var count: Int { tasks.count }
    public var isEmpty: Bool { tasks.isEmpty }
    public var latest: FinishedTask? { tasks.last }
    /// The most severe unread result (error > interrupted > success), deciding the pill mark's icon
    /// and color; nil when nothing is unread
    public var worstOutcome: TaskOutcome? {
        let outcomes = Set(tasks.map(\.outcome))
        for outcome in [TaskOutcome.error, .interrupted, .success] where outcomes.contains(outcome) {
            return outcome
        }
        return nil
    }

    public mutating func add(_ task: FinishedTask) {
        let key = Self.sessionKey(of: task)
        tasks.removeAll { Self.sessionKey(of: $0) == key }
        tasks.append(task)
    }

    /// The user clicked this finished card
    public mutating func markRead(_ task: FinishedTask) {
        let key = Self.sessionKey(of: task)
        tasks.removeAll { Self.sessionKey(of: $0) == key }
    }

    /// The user opened the task list
    public mutating func markAllRead() {
        tasks.removeAll()
    }

    /// Reconcile with running/waiting tasks: a session that started a new turn no longer counts as
    /// unread
    public mutating func reconcile(activeTaskIds: Set<String>) {
        tasks.removeAll { activeTaskIds.contains(Self.sessionKey(of: $0)) }
    }

    private static func sessionKey(of task: FinishedTask) -> String {
        AgentTask.key(source: task.source, sessionId: task.sessionId)
    }
}
