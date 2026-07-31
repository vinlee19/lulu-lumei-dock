import Foundation

/// 灵动岛展示状态（TaskStore 的投影 + 卡片队列的快照）
public struct IslandState: Equatable, Sendable {
    /// 展开卡片的内容
    public enum Card: Equatable, Sendable {
        case finished(FinishedTask)
        case waiting(AgentTask)
        /// 健康提示等关怀类通知
        case notice(IslandNotice)
        /// 高危操作安全告警（红卡，插队置顶、自动收起）
        case alert(RiskAlert)
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

// MARK: - 自动收起时长

extension IslandState.Card {
    /// 自动收起的**额外**秒数，叠加在用户设置的基准秒数（`autoDismissSeconds`，设置页 3–15s）之上。
    /// nil = 不自动收起。
    ///
    /// 用相对偏移而不是各卡写死绝对秒数：那个滑块才是用户意图的载体。写死的话，
    /// 用户把它调到 15s 时会看到「等待卡反而比完成卡收得快」，说不通。
    public var autoDismissExtraSeconds: TimeInterval? {
        switch self {
        case .finished: return 0  // 基准值，滑块直接生效
        case .waiting: return 4   // 授权/输入请求要看清：默认 6+4=10s
        case .notice: return 5    // 关怀文案给足阅读时间
        case .alert: return 6     // 安全告警多停一会（审计页与通知中心另有留存）
        }
    }

    /// 是否自动收起。
    ///
    /// **入卡起计时（`refresh`）与鼠标移开后重新起计时（`setHovering`）必须共用这一个判据。**
    /// 那两处原本各写一份 switch，而 `setHovering` 漏了等待卡 —— 于是等待卡改成自动收之后，
    /// 只要悬停过一次再移开，它就会退回常驻。判据收在这里就不可能再漂移。
    public var autoDismisses: Bool { autoDismissExtraSeconds != nil }
}
