import Foundation

/// 状态机输出的副作用：调用方（app 层）据此驱动 UI / 持久化
public enum TaskStoreEffect: Equatable, Sendable {
    /// 有任务结束，应展示完成卡片并写入历史
    case taskFinished(FinishedTask)
    /// 有任务进入等待确认状态，应展示提醒卡片
    case taskWaiting(AgentTask)
    /// 活跃任务集合变化（数量或状态），compact 胶囊需要刷新
    case activeTasksChanged
}

/// 任务状态机：事件进、状态表出。纯逻辑，无 IO，调用方负责线程约束（app 内主线程）。
/// key = source:sessionId。
public final class TaskStore {
    public private(set) var activeTasks: [String: AgentTask] = [:]

    public init() {}

    /// 应用一个领域事件，返回需要执行的副作用
    @discardableResult
    public func apply(_ event: TaskEvent) -> [TaskStoreEffect] {
        let key = AgentTask.key(source: event.source, sessionId: event.sessionId)

        switch event.kind {
        case .taskStarted(let title):
            if var task = activeTasks[key] {
                // 同会话再次提交（追加引导/等待输入后回复）：保留原始开始时间，恢复 running
                task.lastActivityAt = event.timestamp
                if task.title == nil { task.title = title }
                if case .waiting = task.phase { task.phase = .running }
                activeTasks[key] = task
                return [.activeTasksChanged]
            }
            activeTasks[key] = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: title,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .running
            )
            return [.activeTasksChanged]

        case .taskFinished(let outcome, let title, let detail):
            let existing = activeTasks.removeValue(forKey: key)
            let finished = FinishedTask(
                source: event.source,
                sessionId: event.sessionId,
                title: title ?? existing?.title,
                cwd: event.cwd ?? existing?.cwd,
                startedAt: existing?.startedAt,
                finishedAt: event.timestamp,
                outcome: outcome,
                detail: detail
            )
            return [.taskFinished(finished), .activeTasksChanged]

        case .waiting(let reason, let message):
            if var task = activeTasks[key] {
                task.phase = .waiting(reason, since: event.timestamp)
                task.lastActivityAt = event.timestamp
                activeTasks[key] = task
                return [.taskWaiting(task), .activeTasksChanged]
            }
            // 没赶上开始事件（hooks 中途安装）：以等待状态登记
            let task = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: message,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .waiting(reason, since: event.timestamp)
            )
            activeTasks[key] = task
            return [.taskWaiting(task), .activeTasksChanged]

        case .activity(let tool):
            guard var task = activeTasks[key] else { return [] }
            task.lastActivityAt = event.timestamp
            var effects: [TaskStoreEffect] = []
            if case .waiting = task.phase {
                // 用户已处理完确认，工具继续跑了 → 恢复 running
                task.phase = .running
                effects.append(.activeTasksChanged)
            }
            if let tool, tool != task.currentActivity {
                task.currentActivity = tool
                if effects.isEmpty { effects.append(.activeTasksChanged) }
            }
            activeTasks[key] = task
            return effects

        case .contextUpdate(let percent):
            guard var task = activeTasks[key] else { return [] }
            // 整数桶变化才刷 UI，避免高频小数抖动
            let oldBucket = task.contextUsedPercent.map { Int($0.rounded()) }
            task.contextUsedPercent = percent
            task.lastActivityAt = event.timestamp
            activeTasks[key] = task
            return Int(percent.rounded()) == oldBucket ? [] : [.activeTasksChanged]

        case .sessionStarted:
            return []

        case .sessionEnded(let reason):
            guard let task = activeTasks.removeValue(forKey: key) else { return [] }
            // 任务还在跑会话就结束了 → 视为中断
            let finished = FinishedTask(
                source: event.source,
                sessionId: event.sessionId,
                title: task.title,
                cwd: task.cwd,
                startedAt: task.startedAt,
                finishedAt: event.timestamp,
                outcome: .interrupted,
                detail: reason.map { "会话结束（\($0)）" }
            )
            return [.taskFinished(finished), .activeTasksChanged]
        }
    }

    /// 清理超时任务（hook 丢失兜底），返回因此结束的任务效果
    @discardableResult
    public func reapStaleTasks(now: Date, runningTimeout: TimeInterval) -> [TaskStoreEffect] {
        var effects: [TaskStoreEffect] = []
        for (key, task) in activeTasks
        where now.timeIntervalSince(task.lastActivityAt) > runningTimeout {
            activeTasks.removeValue(forKey: key)
            effects.append(.taskFinished(FinishedTask(
                source: task.source,
                sessionId: task.sessionId,
                title: task.title,
                cwd: task.cwd,
                startedAt: task.startedAt,
                finishedAt: now,
                outcome: .interrupted,
                detail: "长时间无活动，已自动清理"
            )))
        }
        if !effects.isEmpty { effects.append(.activeTasksChanged) }
        return effects
    }

    /// 按开始时间排序的活跃任务（含 waiting）
    public var sortedActiveTasks: [AgentTask] {
        activeTasks.values.sorted { $0.startedAt < $1.startedAt }
    }
}
