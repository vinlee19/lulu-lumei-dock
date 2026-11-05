import Foundation

/// Projection of the compact pill (the "menu bar strip" in design mock agent-dock-final):
/// the left wing has one icon per present source, lit with a cyan dot when a session is running and
/// dimmed when only idle sessions remain, followed by the running count; the right wing is an alert
/// slot that "lights up only when something's up"; with no alert it shows the oldest task's timer.
/// Pure logic; the view only renders.
public enum IslandPill {
    /// One source icon in the left wing
    public struct SourceMark: Equatable, Sendable {
        public var source: AgentSource
        /// The source has a running/waiting session (icon lit + cyan dot); false = only idle
        /// sessions (dimmed)
        public var isActive: Bool

        public init(source: AgentSource, isActive: Bool) {
            self.source = source
            self.isActive = isActive
        }
    }

    /// Right-wing alert. When several hold at once, the first one in case order wins
    public enum Alert: Equatable, Sendable {
        /// Questions folded into the pill by an outside click, still waiting for an answer:
        /// the agent is paused on them, so they outrank everything else
        case question(count: Int)
        /// A session is waiting for permission / input (permission first)
        case waiting(WaitReason)
        /// Some session's (idle included) context usage ≥ `contextAlertPercent`; the highest is
        /// taken
        case context(percent: Double)
        /// Unread finished: count + the most severe result
        case unread(count: Int, worstOutcome: TaskOutcome)
    }

    /// Context usage at or above this percentage lights the right-wing alert
    public static let contextAlertPercent: Double = 90

    /// Whether the pill stays up when no card is showing: any open session (running, waiting or
    /// idle), an unread finish or a folded question keeps it; the island hides only when all are
    /// empty
    public static func isShown(
        active: [AgentTask], idle: [AgentTask], unread: IslandUnreadFinished,
        deferredQuestions: Int = 0
    ) -> Bool {
        !(active.isEmpty && idle.isEmpty && unread.isEmpty && deferredQuestions == 0)
    }

    /// Left-wing sources: union of the sources of running and idle sessions, in the fixed order of
    /// `AgentSource.allCases`
    public static func sourceMarks(active: [AgentTask], idle: [AgentTask]) -> [SourceMark] {
        let activeSources = Set(active.map(\.source))
        let present = activeSources.union(idle.map(\.source))
        return AgentSource.allCases
            .filter { present.contains($0) }
            .map { SourceMark(source: $0, isActive: activeSources.contains($0)) }
    }

    public static func alert(
        active: [AgentTask], idle: [AgentTask], unread: IslandUnreadFinished,
        deferredQuestions: Int = 0
    ) -> Alert? {
        if deferredQuestions > 0 { return .question(count: deferredQuestions) }
        let reasons = active.compactMap { task -> WaitReason? in
            if case .waiting(let reason, _) = task.phase { return reason }
            return nil
        }
        if reasons.contains(.permission) { return .waiting(.permission) }
        if let reason = reasons.first { return .waiting(reason) }
        let highest = (active + idle).compactMap(\.contextUsedPercent).max()
        if let highest, highest >= contextAlertPercent { return .context(percent: highest) }
        if let worst = unread.worstOutcome { return .unread(count: unread.count, worstOutcome: worst) }
        return nil
    }
}
