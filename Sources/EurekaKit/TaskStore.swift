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

/// 会话状态机：事件进、状态表出。纯逻辑，无 IO，调用方负责线程约束（app 内主线程）。
/// key = source:sessionId。
///
/// 生命周期：sessionStarted/心跳发现 → idle/running ↔ waiting → (turn 完成) idle
/// （Claude 会话开着可反复跑 turn；Codex 完成即移除）→ sessionEnded/超时 → 移除。
public final class TaskStore {
    public private(set) var activeTasks: [String: AgentTask] = [:]

    public init() {}

    /// 应用一个领域事件，返回需要执行的副作用
    @discardableResult
    public func apply(_ event: TaskEvent) -> [TaskStoreEffect] {
        let key = AgentTask.key(source: event.source, sessionId: event.sessionId)
        let effects = applyKind(event, key: key)
        // 任何事件带来的"会话首启时间"都补到任务上（只设一次）
        if let sessionStart = event.sessionStartedAt,
           var task = activeTasks[key], task.sessionStartedAt == nil {
            task.sessionStartedAt = sessionStart
            activeTasks[key] = task
        }
        return effects
    }

    private func applyKind(_ event: TaskEvent, key: String) -> [TaskStoreEffect] {
        switch event.kind {
        case .taskStarted(let title):
            if var task = activeTasks[key] {
                // 同会话再次提交（追加引导/等待输入后回复/空闲后新 turn）
                task.lastActivityAt = event.timestamp
                if task.title == nil { task.title = title }
                if case .idle = task.phase {
                    // 空闲后开新 turn：计时从现在起，新 prompt 即新任务名
                    task.startedAt = event.timestamp
                    task.currentActivity = nil
                    if let title { task.title = title }
                }
                if case .running = task.phase {} else { task.phase = .running }
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
            let existing = activeTasks[key]
            if var task = existing, case .idle = task.phase {
                // 已收尾会话的重复完成信号（hooks 与 transcript 监视双源）：
                // 刷新活性即可，绝不重复出卡/写历史
                task.lastActivityAt = event.timestamp
                activeTasks[key] = task
                return []
            }
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
            if var task = existing {
                // 已知会话（Claude/Codex）：turn 结束 → 转空闲，等下一个 prompt
                // Codex 空闲会话由 reapStaleTasks 按 idleTimeout 静默回收
                task.phase = .idle
                task.lastActivityAt = event.timestamp
                task.currentActivity = nil
                if task.title == nil { task.title = title }
                activeTasks[key] = task
            } else {
                // 没赶上开始事件的未知会话：不留空闲残影
                activeTasks.removeValue(forKey: key)
            }
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
                title: nil,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .waiting(reason, since: event.timestamp)
            )
            _ = message  // 文案不当标题（titleUpdate 会带来 ai-title）
            activeTasks[key] = task
            return [.taskWaiting(task), .activeTasksChanged]

        case .activity(let tool):
            guard var task = activeTasks[key] else {
                // 心跳发现未知会话（app 在 turn 中途启动）：登记为运行中
                activeTasks[key] = AgentTask(
                    source: event.source,
                    sessionId: event.sessionId,
                    title: nil,
                    cwd: event.cwd,
                    startedAt: event.timestamp,
                    phase: .running,
                    currentActivity: tool
                )
                return [.activeTasksChanged]
            }
            task.lastActivityAt = event.timestamp
            var effects: [TaskStoreEffect] = []
            switch task.phase {
            case .waiting, .idle:
                // 等待已处理 / 空闲会话有工具在跑 → running
                task.phase = .running
                effects.append(.activeTasksChanged)
            case .running:
                break
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

        case .titleUpdate(let title):
            guard var task = activeTasks[key], task.title != title else { return [] }
            task.title = title
            activeTasks[key] = task
            return [.activeTasksChanged]

        case .sessionStarted:
            guard activeTasks[key] == nil else { return [] }
            // 会话打开但还没跑任务：登记为空闲（任务列表可见）
            activeTasks[key] = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: nil,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .idle
            )
            return [.activeTasksChanged]

        case .sessionEnded(let reason):
            guard let task = activeTasks.removeValue(forKey: key) else { return [] }
            if case .idle = task.phase {
                // 空闲会话正常关闭：不算任务中断，不出卡
                return [.activeTasksChanged]
            }
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

    /// 清理超时任务（hook 丢失兜底）：
    /// 运行/等待超时 → 判中断出卡；空闲超时（更短，可能没收到 SessionEnd）→ 静默移除
    @discardableResult
    public func reapStaleTasks(
        now: Date, runningTimeout: TimeInterval, idleTimeout: TimeInterval = 3600
    ) -> [TaskStoreEffect] {
        var effects: [TaskStoreEffect] = []
        var changed = false
        for (key, task) in activeTasks {
            let timeout: TimeInterval
            if case .idle = task.phase { timeout = idleTimeout } else { timeout = runningTimeout }
            guard now.timeIntervalSince(task.lastActivityAt) > timeout else { continue }
            activeTasks.removeValue(forKey: key)
            changed = true
            if case .idle = task.phase { continue }
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
        if changed { effects.append(.activeTasksChanged) }
        return effects
    }

    /// 运行/等待中的任务，按开始时间排序（胶囊计数、卡片）
    public var sortedActiveTasks: [AgentTask] {
        activeTasks.values
            .filter { if case .idle = $0.phase { return false } else { return true } }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// 空闲会话，按最近活跃排序（任务列表"空闲"分组）
    public var sortedIdleTasks: [AgentTask] {
        activeTasks.values
            .filter { if case .idle = $0.phase { return true } else { return false } }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
