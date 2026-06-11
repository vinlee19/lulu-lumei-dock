import AppKit
import Combine
import EurekaKit
import Foundation

/// 灵动岛展示状态机：活跃任务 + 卡片队列 → 当前展示形态。
/// 自动收起计时、hover 暂停都在这里；视图与 panel 控制器只做投影。
@MainActor
final class IslandViewModel: ObservableObject {
    enum Display: Equatable {
        case hidden
        case compact
        case card(IslandState.Card)
        /// 点击胶囊展开的进行中任务列表
        case taskList
    }

    @Published private(set) var display: Display = .hidden
    @Published private(set) var activeTasks: [AgentTask] = []
    /// 空闲会话（开着但没在跑 turn）：任务列表展示，胶囊计数不算
    @Published private(set) var idleTasks: [AgentTask] = []
    @Published private(set) var queuedCount = 0
    @Published private(set) var screen = IslandGeometry.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    /// 用户把岛拖到了自定义位置：脱离刘海融合，渲染为四角全圆的悬浮样式
    @Published var isFloating = false
    /// 时间显示模式：false=已持续时长（计时器），true=开始的日期时间
    @Published var showStartTime: Bool = UserDefaults.standard.bool(forKey: "islandShowStartTime") {
        didSet { UserDefaults.standard.set(showStartTime, forKey: "islandShowStartTime") }
    }

    let layout = IslandGeometry.Layout.standard
    /// 完成/出错卡自动收起秒数（等待卡不自动收）
    var autoDismissSeconds: TimeInterval = 6

    /// 展示形态变化回调（panel 控制器据此显隐窗口）
    var onDisplayChange: (@MainActor (Display) -> Void)?

    private var queue = IslandCardQueue()
    private var hovering = false
    private var dismissTimer: Timer?

    // MARK: - 输入

    func updateScreen(_ info: IslandGeometry.ScreenInfo) {
        screen = info
    }

    func updateActiveTasks(_ tasks: [AgentTask], idle: [AgentTask] = []) {
        activeTasks = tasks
        idleTasks = idle
        // 与等待卡对账：任务已不在等待的撤卡
        let stillWaiting = Set(tasks.compactMap { task -> String? in
            if case .waiting = task.phase { return task.id }
            return nil
        })
        for id in queue.waitingTaskIds where !stillWaiting.contains(id) {
            queue.removeWaiting(taskId: id)
        }
        refresh()
    }

    func enqueueFinished(_ task: FinishedTask) {
        queue.enqueue(.finished(task))
        refresh()
    }

    func enqueueWaiting(_ task: AgentTask) {
        queue.enqueue(.waiting(task))
        refresh()
    }

    func islandTapped() {
        switch display {
        case .compact:
            setDisplay(.taskList)
            scheduleAutoDismiss()
        case .card:
            advanceCard()
        case .taskList:
            refresh(collapseTaskList: true)
        case .hidden:
            break
        }
    }

    func setHovering(_ value: Bool) {
        hovering = value
        if !value {
            hoverExtensions = 0
            // 真正移开后正常计时收起
            switch display {
            case .card(.finished), .taskList:
                scheduleAutoDismiss()
            default:
                break
            }
        }
        // 悬停中不取消定时器：靠续期机制暂停（防 mouseExited 丢失永久卡死）
    }

    // MARK: - 投影

    /// 内容距 panel 顶部留白：浮动模式贴 panel 顶（panel 在哪由用户决定）
    var topInset: CGFloat {
        isFloating ? 0 : IslandGeometry.contentTopInset(screen: screen, layout: layout)
    }

    /// 胶囊中部为物理刘海留的空隙（浮动模式无意义）
    var pillCenterGap: CGFloat {
        isFloating ? 0 : IslandGeometry.pillCenterGap(screen: screen)
    }

    /// 是否与刘海融合渲染（上沿直角）；浮动/无刘海 → 四角全圆
    var fuseWithNotch: Bool {
        !isFloating && screen.hasNotch
    }

    private var pillSize: CGSize {
        isFloating
            ? layout.compactPillNoNotchSize
            : IslandGeometry.pillSize(screen: screen, layout: layout)
    }

    var contentSize: CGSize {
        switch display {
        case .hidden:
            return .zero
        case .compact:
            return pillSize
        case .card:
            return layout.expandedCardSize
        case .taskList:
            let activeRows = min(activeTasks.count, 4)
            let idleRows = min(idleTasks.count, 3)
            let idleHeader = idleRows > 0 ? 18 : 0
            return CGSize(
                width: layout.expandedCardSize.width,
                height: CGFloat(34 + activeRows * 30 + idleHeader + idleRows * 24 + 10))
        }
    }

    /// panel 坐标系中的可交互区域（hitTest 穿透 + hover 跟踪）
    var interactiveRect: CGRect {
        IslandGeometry.interactiveRect(
            contentSize: contentSize, topInset: topInset, layout: layout)
    }

    var hasWaiting: Bool {
        activeTasks.contains {
            if case .waiting = $0.phase { return true }
            return false
        }
    }

    // MARK: - 内部

    private func refresh(collapseTaskList: Bool = false) {
        if case .taskList = display, !collapseTaskList,
           queue.current == nil,
           !(activeTasks.isEmpty && idleTasks.isEmpty) {
            // 任务列表展开期间不被状态刷新打断（除非有新卡/列表已空）
            queuedCount = queue.pendingCount
            if dismissTimer == nil {
                // 自愈：任何状态变化都确保收起定时器在走（防 hover 卡死）
                scheduleAutoDismiss()
            }
            return
        }
        if let card = queue.current {
            setDisplay(.card(card))
            switch card {
            case .finished: scheduleAutoDismiss()
            case .waiting: cancelAutoDismiss()  // 等待卡常驻到任务恢复/手动点掉
            }
        } else {
            setDisplay(activeTasks.isEmpty ? .hidden : .compact)
        }
        queuedCount = queue.pendingCount
    }

    private func advanceCard() {
        queue.advance()
        refresh()
    }

    private func setDisplay(_ new: Display) {
        guard display != new else { return }
        display = new
        logIsland(new)
        onDisplayChange?(new)
    }

    /// 悬停时收起被"续期"而非取消：mouseExited 可能被 performDrag 等吞掉导致
    /// hover 永久卡住——续期 + 硬上限保证岛绝不会停在旧内容上（曾导致整夜不更新）。
    private var hoverExtensions = 0
    private let maxHoverExtensions = 5

    private func scheduleAutoDismiss() {
        cancelAutoDismiss()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: autoDismissSeconds, repeats: false
        ) { [weak self] _ in
            // Timer 回调在主 runloop
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissTimer = nil
                if self.hovering && self.hoverExtensions < self.maxHoverExtensions {
                    // 用户在看：续期；超上限视为 hover 状态卡死，强制收起
                    self.hoverExtensions += 1
                    self.scheduleAutoDismiss()
                    return
                }
                self.hoverExtensions = 0
                switch self.display {
                case .card: self.advanceCard()
                case .taskList: self.refresh(collapseTaskList: true)
                default: break
                }
            }
        }
    }

    private func cancelAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// e2e 可观测性
    private func logIsland(_ display: Display) {
        let name: String
        switch display {
        case .hidden: name = "hidden"
        case .compact: name = "compact"
        case .card(.finished(let task)): name = "card-finished(\(task.outcome.rawValue))"
        case .card(.waiting): name = "card-waiting"
        case .taskList: name = "taskList"
        }
        print("[eureka] island=\(name)")
        fflush(stdout)
    }
}
