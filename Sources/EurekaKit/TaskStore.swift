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

/// 任务状态机：事件进、状态表出。纯逻辑，无 IO。
/// key = source:sessionId。M1 实现 reducer。
public final class TaskStore {
    public private(set) var activeTasks: [String: AgentTask] = [:]

    public init() {}

    /// 应用一个领域事件，返回需要执行的副作用
    @discardableResult
    public func apply(_ event: TaskEvent) -> [TaskStoreEffect] {
        // M1 实现
        []
    }

    /// 清理超时任务（hook 丢失兜底），返回因此结束的任务
    @discardableResult
    public func reapStaleTasks(now: Date, runningTimeout: TimeInterval) -> [TaskStoreEffect] {
        // M1 实现
        []
    }

    /// 按开始时间排序的活跃任务（含 waiting）
    public var sortedActiveTasks: [AgentTask] {
        activeTasks.values.sorted { $0.startedAt < $1.startedAt }
    }
}
