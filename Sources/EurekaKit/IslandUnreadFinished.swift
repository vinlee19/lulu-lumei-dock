import Foundation

/// 未读完成：完成卡自动收起后留在胶囊上的「✓ N」标记。
///
/// 完成卡按时收起不等于用户看见了 —— 没有它，唯一在跑的会话一完成，卡片收起后岛就整个隐藏，
/// 错过那几秒就什么都找不回来。所以：
/// - 卡片**按时收起**不算已读，标记留在胶囊上；
/// - **点了那张卡** / **点开任务列表**才算已读；
/// - 该会话**开始新一轮 turn**（又进了运行/等待）也清掉：用户已经回到会话里了。
///
/// 每个会话只记最近一次完成（同会话连跑几轮只算 1 个未读）。纯逻辑；展示由 IslandViewModel 投影。
public struct IslandUnreadFinished: Equatable, Sendable {
    /// 按完成时间升序，每个会话（`AgentTask.key`）一条
    public private(set) var tasks: [FinishedTask] = []

    public init() {}

    public var count: Int { tasks.count }
    public var isEmpty: Bool { tasks.isEmpty }
    public var latest: FinishedTask? { tasks.last }
    /// 未读里最严重的结果（出错 > 中断 > 成功），决定胶囊标记的图标与颜色；无未读为 nil
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

    /// 用户点了这张完成卡
    public mutating func markRead(_ task: FinishedTask) {
        let key = Self.sessionKey(of: task)
        tasks.removeAll { Self.sessionKey(of: $0) == key }
    }

    /// 用户点开了任务列表
    public mutating func markAllRead() {
        tasks.removeAll()
    }

    /// 与运行/等待中的任务对账：会话开始了新一轮 turn 就不再算未读
    public mutating func reconcile(activeTaskIds: Set<String>) {
        tasks.removeAll { activeTaskIds.contains(Self.sessionKey(of: $0)) }
    }

    private static func sessionKey(of task: FinishedTask) -> String {
        AgentTask.key(source: task.source, sessionId: task.sessionId)
    }
}
