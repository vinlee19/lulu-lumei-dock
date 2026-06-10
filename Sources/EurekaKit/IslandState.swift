import Foundation

/// 灵动岛展示状态（TaskStore 的投影 + 卡片队列的快照）
public struct IslandState: Equatable, Sendable {
    /// 展开卡片的内容
    public enum Card: Equatable, Sendable {
        case finished(FinishedTask)
        case waiting(AgentTask)
    }

    /// 进行中任务（含 waiting），按开始时间排序
    public var activeTasks: [AgentTask]
    /// 当前展示的展开卡片（nil = compact 或隐藏）
    public var card: Card?
    /// 排队等待展示的卡片数
    public var queuedCardCount: Int

    /// 岛是否可见（无任务且无卡片时完全隐藏）
    public var isVisible: Bool { !activeTasks.isEmpty || card != nil }

    /// 是否有任务在等待确认（compact 态显示警示色）
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
