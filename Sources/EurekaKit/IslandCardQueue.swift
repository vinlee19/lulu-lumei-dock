import Foundation

/// 展开卡片队列：完成卡排队逐显（不刷屏），等待卡置顶且同任务去重。
/// 纯逻辑；自动收起的计时由 UI 层负责。
public struct IslandCardQueue: Equatable, Sendable {
    public private(set) var current: IslandState.Card?
    public private(set) var pending: [IslandState.Card] = []

    public init() {}

    public var pendingCount: Int { pending.count }
    public var isEmpty: Bool { current == nil && pending.isEmpty }

    public mutating func enqueue(_ card: IslandState.Card) {
        switch card {
        case .waiting(let task):
            // 同任务旧等待卡先撤掉，新卡插队（等待确认比完成通知更紧急）
            removeWaiting(taskId: task.id)
            if current == nil {
                current = card
            } else {
                pending.insert(card, at: 0)
            }
        case .finished:
            if current == nil {
                current = card
            } else {
                pending.append(card)
            }
        }
    }

    /// 任务离开等待状态（恢复运行/结束/会话终止）时撤掉它的等待卡
    public mutating func removeWaiting(taskId: String) {
        pending.removeAll {
            if case .waiting(let task) = $0 { return task.id == taskId }
            return false
        }
        if case .waiting(let task) = current, task.id == taskId {
            current = pending.isEmpty ? nil : pending.removeFirst()
        }
    }

    /// 队列中所有等待卡对应的任务 id（与活跃任务对账清卡用）
    public var waitingTaskIds: [String] {
        var ids: [String] = []
        if case .waiting(let task)? = current { ids.append(task.id) }
        for card in pending {
            if case .waiting(let task) = card { ids.append(task.id) }
        }
        return ids
    }

    /// 收起当前卡，推进到下一张；返回新的当前卡
    @discardableResult
    public mutating func advance() -> IslandState.Card? {
        current = pending.isEmpty ? nil : pending.removeFirst()
        return current
    }
}
