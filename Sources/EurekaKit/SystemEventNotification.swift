import Foundation

/// 一条待发的系统通知文案（EurekaApp 侧交给 UNUserNotificationCenter 展示）
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

/// 关键岛事件（完成/出错/等待）→ 系统通知的纯决策与文案组装。
/// 与岛上卡片同一口径：来源 displayName、任务标题、项目名。
/// 只在状态转换处调用（taskFinished / taskWaiting 效果），心跳永远不会走到这里。
public enum SystemEventNotifications {
    /// 任务完成/出错/中断：主开关 + 对应类型开关都开才发
    public static func forFinished(
        _ task: FinishedTask, master: Bool, completion: Bool, error: Bool
    ) -> SystemEventNotification? {
        guard master else { return nil }
        let verb: String
        switch task.outcome {
        case .success:
            guard completion else { return nil }
            verb = "任务完成"
        case .error:
            guard error else { return nil }
            verb = "任务出错"
        case .interrupted:
            guard error else { return nil }
            verb = "任务中断"
        }
        return SystemEventNotification(
            identifier: "eureka-event-\(task.id)",
            title: verb,
            body: body(source: task.source, title: task.title,
                       projectName: task.projectName, sessionId: task.sessionId))
    }

    /// 等待确认/等待输入：主开关 + 等待开关都开才发。
    /// identifier 用会话 id：同会话重复等待会覆盖旧横幅，不堆叠。
    public static func forWaiting(
        _ task: AgentTask, master: Bool, waiting: Bool
    ) -> SystemEventNotification? {
        guard master, waiting else { return nil }
        let verb: String
        if case .waiting(let reason, _) = task.phase {
            verb = reason.displayName
        } else {
            return nil  // 防御：非等待态不该走到这里
        }
        return SystemEventNotification(
            identifier: "eureka-event-waiting-\(task.id)",
            title: verb,
            body: body(source: task.source, title: task.title,
                       projectName: task.projectName, sessionId: task.sessionId))
    }

    /// 正文：来源 · 标题（· 项目）；无标题时退回项目名，再退回会话号
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
            parts.append("会话 \(sessionId.prefix(8))")
        }
        return parts.joined(separator: " · ")
    }
}
