import AppKit
import Combine
import EurekaKit
import Foundation

/// Dynamic Island presentation state machine: active tasks + card queue → current presentation.
/// Auto-dismiss timing and hover pause live here; the views and panel controller are projections
/// only.
@MainActor
final class IslandViewModel: ObservableObject {
    enum Display: Equatable {
        case hidden
        case compact
        case card(IslandState.Card)
        /// In-progress task list shown when the capsule is clicked
        case taskList
    }

    @Published private(set) var display: Display = .hidden
    @Published private(set) var activeTasks: [AgentTask] = []
    /// Idle sessions (open but not running a turn): shown in the task list, not counted in the
    /// capsule
    @Published private(set) var idleTasks: [AgentTask] = []
    @Published private(set) var queuedCount = 0
    /// 按时收起、用户还没点开看过的完成卡：胶囊上的「✓ N」，有它时即使没有运行中任务岛也不隐藏
    @Published private(set) var unreadFinished = IslandUnreadFinished()
    /// 任务列表里当前展开子 agent 框的任务 id（nil = 全收起；单开，几何有界）
    @Published private(set) var expandedSubagentTaskId: String?
    @Published private(set) var screen = IslandGeometry.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    /// The user dragged the island to a custom position: detaches from the notch, rendered as a
    /// floating style with all corners rounded
    @Published var isFloating = false
    /// Time display mode: false = elapsed duration (timer), true = start date-time. The source of
    /// truth is AppSettings (shared by Settings and the island button); this is only a projection.
    @Published var showStartTime = false
    /// Interface language projection. Island copy is looked up in the views; a language change
    /// redraws via this publish.
    @Published private(set) var language: AppLanguage = L10n.current
    /// Island toggle button callback (AppDelegate wires it to AppSettings)
    var onToggleTimeMode: (@MainActor () -> Void)?

    /// Layout for the current screen (scaled proportionally as the screen changes)
    var layout: IslandGeometry.Layout { IslandGeometry.layout(for: screen) }
    /// UI scale factor for the current screen (fonts / padding / badges; pill height is pinned by
    /// the notch, not affected)
    var uiScale: CGFloat { IslandGeometry.scaleFactor(for: screen) }
    /// **Base** auto-dismiss seconds for cards (adjustable 3-15s in Settings).
    /// Each card kind adds its own offset on top, see `IslandState.Card.autoDismissExtraSeconds`.
    var autoDismissSeconds: TimeInterval = 6

    /// Presentation-change callback (the panel controller shows/hides the window from it)
    var onDisplayChange: (@MainActor (Display) -> Void)?

    private var queue = IslandCardQueue()
    private var hovering = false
    private var dismissTimer: Timer?
    /// Which card the current dismiss timer was scheduled for. Distinguishes "card changed" from
    /// "same card re-projected by a state refresh" -- the latter must never reschedule, or the
    /// countdown is reset to the start forever (see refresh).
    private var timerCard: IslandState.Card?

    // MARK: - Input

    func noteLanguage(_ language: AppLanguage) {
        self.language = language
    }

    func updateScreen(_ info: IslandGeometry.ScreenInfo) {
        screen = info
    }

    func updateActiveTasks(_ tasks: [AgentTask], idle: [AgentTask] = []) {
        activeTasks = tasks
        idleTasks = idle
        // Reconcile with waiting cards: withdraw cards for tasks no longer waiting
        let stillWaiting = Set(tasks.compactMap { task -> String? in
            if case .waiting = task.phase { return task.id }
            return nil
        })
        for id in queue.waitingTaskIds where !stillWaiting.contains(id) {
            queue.removeWaiting(taskId: id)
        }
        // 会话开始新一轮 turn：之前那次完成不再算未读
        unreadFinished.reconcile(activeTaskIds: Set(tasks.map(\.id)))
        // 展开的任务消失了就收起（防停在已不存在的会话上）
        if let id = expandedSubagentTaskId, !tasks.contains(where: { $0.id == id }) {
            expandedSubagentTaskId = nil
        }
        refresh()
    }

    func enqueueFinished(_ task: FinishedTask) {
        queue.enqueue(.finished(task))
        unreadFinished.add(task)
        refresh()
    }

    func enqueueWaiting(_ task: AgentTask) {
        queue.enqueue(.waiting(task))
        refresh()
    }

    func enqueueNotice(_ notice: IslandNotice) {
        queue.enqueue(.notice(notice))
        refresh()
    }

    func enqueueAlert(_ alert: RiskAlert) {
        queue.enqueue(.alert(alert))
        refresh()
    }

    func islandTapped() {
        switch display {
        case .compact:
            unreadFinished.markAllRead()
            if activeTasks.isEmpty && idleTasks.isEmpty {
                // 只剩未读标记且会话都已退出：列表没东西可看，点一下即清掉标记
                refresh()
                return
            }
            setDisplay(.taskList)
            scheduleAutoDismiss()
        case .card(let card):
            if case .finished(let task) = card {
                unreadFinished.markRead(task)
            }
            advanceCard()
        case .taskList:
            refresh(collapseTaskList: true)
        case .hidden:
            break
        }
    }

    /// A click outside the island (another app, the desktop, another window of this app) while
    /// the task list is open closes it at once. Only the click-opened task list is affected;
    /// cards are timed notifications and an outside click does not dismiss them.
    func dismissTaskList() {
        guard case .taskList = display else { return }
        refresh(collapseTaskList: true)
    }

    /// Expand/collapse a task's subagent box inline (called by the inner button in the task list)
    func toggleSubagentExpansion(_ taskId: String) {
        expandedSubagentTaskId = (expandedSubagentTaskId == taskId) ? nil : taskId
        scheduleAutoDismiss()  // Expanding = the user is looking, so renew the dismiss timer
    }

    func setHovering(_ value: Bool) {
        hovering = value
        if !value {
            hoverExtensions = 0
            // Once the pointer truly leaves, dismiss on the normal timer. **Shares the
            // card.autoDismisses predicate with refresh()** -- this used to hardcode the cases and
            // missed waiting cards, so they "went back to staying open after one hover".
            switch display {
            case .card(let card) where card.autoDismisses:
                scheduleAutoDismiss(extraSeconds: card.autoDismissExtraSeconds ?? 0)
            case .taskList:
                scheduleAutoDismiss()
            default:
                break
            }
        }
            // Don't cancel the timer while hovering: pause by renewal instead (guards against a
            // lost mouseExited sticking forever)
    }

    // MARK: - Projection

    /// Top inset of content within the panel: floating mode hugs the panel top (the user decides
    /// where the panel is)
    var topInset: CGFloat {
        isFloating ? 0 : IslandGeometry.contentTopInset(screen: screen, layout: layout)
    }

    /// Gap in the middle of the capsule for the physical notch (meaningless in floating mode)
    var pillCenterGap: CGFloat {
        isFloating ? 0 : IslandGeometry.pillCenterGap(screen: screen)
    }

    /// Whether to render merged with the notch (square top edge); floating / no notch → all corners
    /// rounded
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
            let height = IslandGeometry.taskListHeight(
                activeCount: activeTasks.count, idleCount: idleTasks.count,
                expandedSubagentCount: expandedSubagentCount)
            return CGSize(width: layout.expandedCardSize.width, height: height * uiScale)
        }
    }

    /// 展开的子 agent 框里的子 agent 数（仅当展开任务在可见的前几行且确有子 agent；否则 0）
    var expandedSubagentCount: Int {
        guard let id = expandedSubagentTaskId,
              let task = activeTasks.prefix(IslandGeometry.TaskList.maxActiveRows)
                  .first(where: { $0.id == id })
        else { return 0 }
        return task.subagents.count
    }

    /// panel 坐标系中的可交互区域（hitTest 穿透 + hover 跟踪）
    var interactiveRect: CGRect {
        IslandGeometry.interactiveRect(
            contentSize: contentSize, topInset: topInset, layout: layout)
    }

    // MARK: - 内部

    private func refresh(collapseTaskList: Bool = false) {
        if case .taskList = display, !collapseTaskList,
           queue.current == nil,
           !(activeTasks.isEmpty && idleTasks.isEmpty) {
            // While the task list is expanded, state refreshes don't interrupt it (unless there is
            // a new card / the list is empty)
            queuedCount = queue.pendingCount
            if dismissTimer == nil {
                // Self-heal: any state change makes sure the dismiss timer is running (guards
                // against hover getting stuck)
                scheduleAutoDismiss()
            }
            return
        }
        if let card = queue.current {
            setDisplay(.card(card))
            // **Reschedule only when the card changes.** refresh() is called often via
            // updateActiveTasks (each source tailer ticks every 2 seconds); rescheduling
            // unconditionally resets the countdown every 2 seconds -- so cards never dismiss.
            // Measured: a waiting card was refreshed 6 times in 15 seconds and never dismissed;
            // finished cards only occasionally slipped out between two refreshes thanks to their
            // short 6s window, and notice (11s) / alert (12s) with longer windows got stuck more
            // reliably.
            if timerCard != card {
                timerCard = card
                if let extra = card.autoDismissExtraSeconds {
                    scheduleAutoDismiss(extraSeconds: extra)
                } else {
                    cancelAutoDismiss()
                }
            }
        } else {
            timerCard = nil
            setDisplay(activeTasks.isEmpty && unreadFinished.isEmpty ? .hidden : .compact)
        }
        queuedCount = queue.pendingCount
    }

    private func advanceCard() {
        queue.advance()
        refresh()
    }

    private func setDisplay(_ new: Display) {
        guard display != new else { return }
        // Leaving the task list collapses the subagent box so the next visit doesn't land on a
        // stale expanded state
        if case .taskList = new {} else { expandedSubagentTaskId = nil }
        display = new
        logIsland(new)
        onDisplayChange?(new)
    }

    /// While hovering, dismissal is "renewed" rather than cancelled: mouseExited can be swallowed
    /// by performDrag etc., sticking hover forever -- renewal + a hard cap guarantee the island
    /// never stays on stale content (once caused a whole night without updates).
    private var hoverExtensions = 0
    private let maxHoverExtensions = 5

    private func scheduleAutoDismiss(extraSeconds: TimeInterval = 0) {
        cancelAutoDismiss()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: autoDismissSeconds + extraSeconds, repeats: false
        ) { [weak self] _ in
            // Timer callback runs on the main runloop
            MainActor.assumeIsolated {
                guard let self else { return }
                self.dismissTimer = nil
                if self.hovering && self.hoverExtensions < self.maxHoverExtensions {
                    // The user is looking: renew; past the cap, treat hover as stuck and force
                    // dismissal
                    self.hoverExtensions += 1
                    self.scheduleAutoDismiss()
                    return
                }
                self.hoverExtensions = 0
                switch self.display {
                case .card: self.expireCurrentCard()
                case .taskList: self.refresh(collapseTaskList: true)
                default: break
                }
            }
        }
    }

    /// 卡片按时收起：不算已读，完成卡在胶囊上留下未读标记（预览渲染也走这里）
    func expireCurrentCard() {
        guard case .card = display else { return }
        advanceCard()
    }

    private func cancelAutoDismiss() {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    /// e2e observability
    private func logIsland(_ display: Display) {
        let name: String
        switch display {
        case .hidden: name = "hidden"
        case .compact: name = "compact"
        case .card(.finished(let task)): name = "card-finished(\(task.outcome.rawValue))"
        case .card(.waiting): name = "card-waiting"
        case .card(.notice): name = "card-notice"
        case .card(.alert(let alert)): name = "card-alert(\(alert.ruleId))"        case .taskList: name = "taskList"
        }
        print("[eureka] island=\(name)")
        fflush(stdout)
    }
}
