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

    /// 当前提问卡的作答进度（当前卡不是提问卡时为 nil）
    @Published private(set) var questionDraft: QuestionDraft?
    /// 正在提问卡里输入「其他」：panel 要临时成为 key window 才收得到键盘
    @Published private(set) var wantsKeyboard = false
    /// 把回答交给 hook（AppDelegate 接到 QuestionInbox）
    var onQuestionReply: (@MainActor (_ questionId: String, _ reply: QuestionReply) -> Void)?
    /// 键盘焦点需求变化（panel 控制器据此 makeKey / 交还焦点）
    var onKeyboardChange: (@MainActor (Bool) -> Void)?

    enum QuestionReply: Equatable {
        /// 键是问题原文
        case answer([String: String])
        /// 回终端回答
        case terminal
    }

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

    // MARK: - 提问卡

    /// 与 hook 那边等待中的问题对账：新来的入队，已不在等待的（hook 超时 / 终端里中断）撤卡
    func updatePendingQuestions(_ questions: [PendingQuestion]) {
        let waiting = Set(questions.map(\.id))
        let queued = Set(queue.questionIds)
        guard waiting != queued else { return }
        for id in queued.subtracting(waiting) {
            queue.removeQuestion(id: id)
        }
        for question in questions where !queued.contains(question.id) {
            queue.enqueue(.question(question))
        }
        refresh()
    }

    func chooseOption(_ label: String) {
        mutateDraft { $0.choose(label) }
    }

    func toggleOption(_ label: String) {
        mutateDraft { $0.toggle(label) }
    }

    func confirmSelection() {
        mutateDraft { $0.confirmSelection() }
    }

    func beginOther() {
        mutateDraft { $0.beginOther() }
    }

    func cancelOther() {
        mutateDraft { $0.cancelOther() }
    }

    func submitOther(_ text: String) {
        mutateDraft { $0.submitOther(text) }
    }

    /// 「在终端回答」：hook 静默退出，Claude 弹出终端选择框
    func answerInTerminal() {
        guard let draft = questionDraft else { return }
        finishQuestion(id: draft.question.id, reply: .terminal)
    }

    private func mutateDraft(_ change: (inout QuestionDraft) -> Void) {
        guard var draft = questionDraft else { return }
        change(&draft)
        if draft.isComplete {
            finishQuestion(id: draft.question.id, reply: .answer(draft.answers))
            return
        }
        questionDraft = draft
        setWantsKeyboard(draft.isTypingOther)
    }

    private func finishQuestion(id: String, reply: QuestionReply) {
        onQuestionReply?(id, reply)
        queue.removeQuestion(id: id)
        refresh()
    }

    /// 提问卡在不在台上决定作答进度：换到另一张提问卡就从头答它，离开提问卡就清掉
    private func syncQuestionDraft() {
        if case .card(.question(let question)) = display {
            if questionDraft?.question.id != question.id {
                questionDraft = QuestionDraft(question: question)
            }
        } else {
            questionDraft = nil
        }
        setWantsKeyboard(questionDraft?.isTypingOther ?? false)
    }

    private func setWantsKeyboard(_ value: Bool) {
        guard wantsKeyboard != value else { return }
        wantsKeyboard = value
        onKeyboardChange?(value)
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
            // 提问卡只认里面的按钮：点到空白处不能把 agent 正在等的问题划走
            if case .question = card { return }
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
        case .card(.question(let question)):
            let current = questionDraft?.current ?? question.questions.first
            let height = IslandGeometry.questionCardHeight(
                optionCount: current?.options.count ?? 0,
                questionLines: questionLines,
                topInset: questionTopInset)
            return CGSize(width: layout.expandedCardSize.width, height: height * uiScale)
        case .card:
            return layout.expandedCardSize
        case .taskList:
            let height = IslandGeometry.taskListHeight(
                activeCount: activeTasks.count, idleCount: idleTasks.count,
                expandedSubagentCount: expandedSubagentCount)
            return CGSize(width: layout.expandedCardSize.width, height: height * uiScale)
        }
    }

    /// 提问卡标题行里的「哪个会话在问」：会话标题 → 项目名
    var questionSessionLabel: String? {
        guard let question = questionDraft?.question else { return nil }
        if let id = question.taskId,
           let task = (activeTasks + idleTasks).first(where: { $0.id == id }) {
            return taskDisplayName(task)
        }
        return question.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// 当前问题原文排出来的行数（1–2），提问卡高度与问题区高度都按它算。
    /// 用与视图相同的字号、宽度测量；宽度少算 4pt 留余量 —— 估少了第二行会被压缩，估多了只是多一行空
    var questionLines: Int {
        guard let text = questionDraft?.current.question else { return 1 }
        let font = NSFont.systemFont(ofSize: 14 * uiScale, weight: .semibold)
        let width = layout.expandedCardSize.width
            - 2 * QuestionCardView.horizontalPadding * uiScale - 4
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        // 行高用排版引擎自己的口径；ascender/descender 算出的值比它小，一行会被除成 1.x 行再进位成 2
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let lines = Int((bounds.height / lineHeight - 0.25).rounded(.up))
        return min(max(lines, 1), IslandGeometry.QuestionCard.maxQuestionLines)
    }

    /// 提问卡内容要让开的刘海高度（1.0× 基准；不与刘海融合时为 0）。
    /// 提问卡按钮多，顶部那一行若钻到刘海后面就点不到
    var questionTopInset: CGFloat {
        fuseWithNotch ? screen.safeAreaTopInset / uiScale : 0
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
        syncQuestionDraft()
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
        case .card(.alert(let alert)): name = "card-alert(\(alert.ruleId))"
        case .card(.question(let question)): name = "card-question(\(question.questions.count))"
        case .taskList: name = "taskList"
        }
        print("[eureka] island=\(name)")
        fflush(stdout)
    }
}
