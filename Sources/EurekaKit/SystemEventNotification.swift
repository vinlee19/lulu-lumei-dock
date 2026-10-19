import Foundation

/// Copy for one pending system notification (EurekaApp hands it to UNUserNotificationCenter for
/// display)
public struct SystemEventNotification: Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String

    public init(identifier: String, title: String, body: String) {
        self.identifier = identifier
        self.title = title
        self.body = body
    }
}

/// Key island events (finished/error/waiting) → pure decision and copy assembly for system
/// notifications. Same conventions as the island cards: source displayName, task title, project
/// name. Called only at state transitions (taskFinished / taskWaiting effects); heartbeats never
/// reach here.
public enum SystemEventNotifications {
    /// Task finished/error/interrupted: sent only when both the master switch and the matching type
    /// switch are on
    public static func forFinished(
        _ task: FinishedTask, master: Bool, completion: Bool, error: Bool
    ) -> SystemEventNotification? {
        guard master else { return nil }
        let verb: String
        switch task.outcome {
        case .success:
            guard completion else { return nil }
            verb = L10n.text("Task completed", zhHans: "任务完成")
        case .error:
            guard error else { return nil }
            verb = L10n.text("Task failed", zhHans: "任务出错")
        case .interrupted:
            guard error else { return nil }
            verb = L10n.text("Task interrupted", zhHans: "任务中断")
        }
        return SystemEventNotification(
            identifier: "eureka-event-\(task.id)",
            title: verb,
            body: body(source: task.source, title: task.title,
                       projectName: task.projectName, sessionId: task.sessionId))
    }

    /// Waiting for confirmation/input: sent only when both the master switch and the waiting switch
    /// are on. The identifier is the session id: a repeated wait in the same session replaces the
    /// old banner instead of stacking.
    public static func forWaiting(
        _ task: AgentTask, master: Bool, waiting: Bool
    ) -> SystemEventNotification? {
        guard master, waiting else { return nil }
        let verb: String
        if case .waiting(let reason, _) = task.phase {
            verb = reason.displayName
        } else {
            return nil  // Defensive: non-waiting states should never reach here
        }
        return SystemEventNotification(
            identifier: "eureka-event-waiting-\(task.id)",
            title: verb,
            body: body(source: task.source, title: task.title,
                       projectName: task.projectName, sessionId: task.sessionId))
    }

    /// Body: source · title (· project); without a title, falls back to the project name, then the
    /// session number
    private static func body(
        source: AgentSource, title: String?, projectName: String?, sessionId: String
    ) -> String {
        var parts = [source.displayName]
        if let title {
            parts.append(title)
            if let projectName, projectName != title { parts.append(projectName) }
        } else if let projectName {
            parts.append(projectName)
        } else {
            parts.append(L10n.format("Session %@", zhHans: "会话 %@", String(sessionId.prefix(8))))
        }
        return parts.joined(separator: " · ")
    }
}
