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
    /// Idle sessions (open but not running a turn): shown in the task list and as dimmed source
    /// icons on the capsule, which they keep visible; not counted in the running count
    @Published private(set) var idleTasks: [AgentTask] = []
    @Published private(set) var queuedCount = 0
    /// Finished cards that auto-dismissed on time and the user hasn't opened yet: the pill's "✓ N";
    /// while present, the island stays visible even after every session has exited
    @Published private(set) var unreadFinished = IslandUnreadFinished()
    /// Id of the task whose subagent box is expanded in the task list (nil = all collapsed; one at
    /// a time, bounded geometry)
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

    /// Direct session links (found by SessionAppLinkCache, pushed in by AppDelegate): session key →
    /// link
    @Published private(set) var appLinks: [String: SessionAppLink] = [:]
    /// "Open session" button on the current finished / waiting card; nil = no button, and the card
    /// height follows it
    @Published private(set) var cardJump: SessionJumpOption?
    /// Jump target → button. Preview rendering swaps in a fixed result so it doesn't depend on which
    /// apps are installed
    var jumpOptionResolver: @MainActor (SessionJumpTarget) -> SessionJumpOption? = {
        SessionJumper.option(for: $0)
    }
    /// Performs the jump (AppDelegate wires it to SessionJumper.perform)
    var onOpenSession: (@MainActor (SessionJumpTarget) -> Void)?

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

    /// Answer progress of the current question card (nil when the current card isn't a question
    /// card)
    @Published private(set) var questionDraft: QuestionDraft?
    /// Typing "Other" in the question card: the panel must temporarily become key window to receive
    /// the keyboard
    @Published private(set) var wantsKeyboard = false
    /// Hands the answer to the hook (AppDelegate wires it to QuestionInbox)
    var onQuestionReply: (@MainActor (_ questionId: String, _ reply: QuestionReply) -> Void)?
    /// A new question card was queued (AppDelegate plays a sound alert)
    var onQuestionArrived: (@MainActor () -> Void)?
    /// Keyboard focus demand changed (the panel controller calls makeKey / hands focus back
    /// accordingly)
    var onKeyboardChange: (@MainActor (Bool) -> Void)?

    enum QuestionReply: Equatable {
        /// Keys are the question text
        case answer([String: String])
        /// Dismissed on the island; answer in Claude's own confirmation UI instead
        case dismiss
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
        // The session started a new turn: the previous finish no longer counts as unread
        unreadFinished.reconcile(activeTaskIds: Set(tasks.map(\.id)))
        // Collapse if the expanded task disappeared (don't stay on a session that no longer exists)
        if let id = expandedSubagentTaskId, !tasks.contains(where: { $0.id == id }) {
            expandedSubagentTaskId = nil
        }
        refresh()
        // The terminal binding may have been probed after the card was queued
        syncCardJump()
    }

    func updateAppLinks(_ links: [String: SessionAppLink]) {
        appLinks = links
        syncCardJump()
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

    // MARK: - Question card

    /// Reconcile with the hook's pending questions: enqueue new ones, withdraw cards no longer
    /// pending (hook timed out / turn interrupted)
    func updatePendingQuestions(_ questions: [PendingQuestion]) {
        let waiting = Set(questions.map(\.id))
        let queued = Set(queue.questionIds)
        guard waiting != queued else { return }
        for id in queued.subtracting(waiting) {
            queue.removeQuestion(id: id)
        }
        let arrived = questions.filter { !queued.contains($0.id) }
        for question in arrived {
            queue.enqueue(.question(question))
        }
        refresh()
        if !arrived.isEmpty { onQuestionArrived?() }
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

    /// "Answer in Claude": dismiss the card on the island; the hook exits silently, and Claude's
    /// own confirmation UI is there all along
    func dismissQuestion() {
        guard let draft = questionDraft else { return }
        finishQuestion(id: draft.question.id, reply: .dismiss)
    }

    /// This question was already settled in Claude (as judged by IslandQuestionBridge): withdraw
    /// the card, don't write back to the hook
    func withdrawQuestion(id: String) {
        queue.removeQuestion(id: id)
        refresh()
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

    /// Whether a question card is on stage decides the answer progress: switching to another
    /// question card starts it from scratch, leaving question cards clears it
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
                // Only the unread mark is left and all sessions have exited: the list has nothing
                // to show, so one click clears the mark
                refresh()
                return
            }
            setDisplay(.taskList)
            scheduleAutoDismiss()
        case .card(let card):
            // Question cards only honor their buttons: a click on blank space must not swipe away a
            // question the agent is waiting on
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

    // MARK: - Open session

    /// A session's "open session" button (the task list's trailing badge uses it too); nil when
    /// there is nowhere to go
    func jumpOption(for task: AgentTask) -> SessionJumpOption? {
        jumpOption(source: task.source, sessionId: task.sessionId, terminal: task.terminal)
    }

    private func jumpOption(
        source: AgentSource, sessionId: String, terminal: TerminalBinding?
    ) -> SessionJumpOption? {
        let link = appLinks[AgentTask.key(source: source, sessionId: sessionId)]
        guard let target = SessionJumpTarget.resolve(terminal: terminal, link: link) else {
            return nil
        }
        return jumpOptionResolver(target)
    }

    /// "Open session" on a card: jumping there counts as seen (a finished card leaves no unread
    /// mark), then the next card shows
    func openSessionFromCard() {
        guard case .card(let card) = display, let jump = cardJump else { return }
        onOpenSession?(jump.target)
        if case .finished(let task) = card {
            unreadFinished.markRead(task)
        }
        advanceCard()
    }

    /// Trailing badge in the task list: jump only, the list stays open
    func openSession(_ option: SessionJumpOption) {
        onOpenSession?(option.target)
    }

    /// The card holds a snapshot taken when it was queued; the terminal binding may have been
    /// probed later, so prefer the session's current value
    private func syncCardJump() {
        let session: (source: AgentSource, sessionId: String, terminal: TerminalBinding?)?
        switch display {
        case .card(.finished(let task)): session = (task.source, task.sessionId, task.terminal)
        case .card(.waiting(let task)): session = (task.source, task.sessionId, task.terminal)
        default: session = nil
        }
        let jump = session.flatMap { session -> SessionJumpOption? in
            let key = AgentTask.key(source: session.source, sessionId: session.sessionId)
            let live = activeTasks.first { $0.id == key } ?? idleTasks.first { $0.id == key }
            return jumpOption(
                source: session.source, sessionId: session.sessionId,
                terminal: live?.terminal ?? session.terminal)
        }
        guard cardJump != jump else { return }
        cardJump = jump
        logCardJump(jump)
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
            let height = IslandGeometry.expandedCardHeight(hasAction: cardJump != nil)
            return CGSize(width: layout.expandedCardSize.width, height: height * uiScale)
        case .taskList:
            let height = IslandGeometry.taskListHeight(
                activeCount: activeTasks.count, idleCount: idleTasks.count,
                expandedSubagentCount: expandedSubagentCount)
            return CGSize(width: layout.expandedCardSize.width, height: height * uiScale)
        }
    }

    /// "Which session is asking" in the question card's title row: session title → project name
    var questionSessionLabel: String? {
        guard let question = questionDraft?.question else { return nil }
        if let id = question.taskId,
           let task = (activeTasks + idleTasks).first(where: { $0.id == id }) {
            return taskDisplayName(task)
        }
        return question.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// Number of lines the current question text lays out to (1–2); both the question card height
    /// and the question area height derive from it. Measured with the same font size and width as
    /// the view; width is reduced by 4pt as margin -- underestimating squeezes the second line,
    /// overestimating only leaves an empty line
    var questionLines: Int {
        guard let text = questionDraft?.current.question else { return 1 }
        let font = NSFont.systemFont(ofSize: 14 * uiScale, weight: .semibold)
        let width = layout.expandedCardSize.width
            - 2 * QuestionCardView.horizontalPadding * uiScale - 4
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: max(width, 1), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font])
        // Use the layout engine's own line height; the ascender/descender value is smaller, so one
        // line would divide into 1.x lines and round up to 2
        let lineHeight = NSLayoutManager().defaultLineHeight(for: font)
        let lines = Int((bounds.height / lineHeight - 0.25).rounded(.up))
        return min(max(lines, 1), IslandGeometry.QuestionCard.maxQuestionLines)
    }

    /// Notch height the question card content must clear (1.0× baseline; 0 when not fused with the
    /// notch). The question card has many buttons; if the top row slid behind the notch it couldn't
    /// be clicked
    var questionTopInset: CGFloat {
        fuseWithNotch ? screen.safeAreaTopInset / uiScale : 0
    }

    /// Number of subagents in the expanded subagent box (only when the expanded task is in the
    /// first visible rows and does have subagents; otherwise 0)
    var expandedSubagentCount: Int {
        guard let id = expandedSubagentTaskId,
              let task = activeTasks.prefix(IslandGeometry.TaskList.maxActiveRows)
                  .first(where: { $0.id == id })
        else { return 0 }
        return task.subagents.count
    }

    /// Interactive area in panel coordinates (hitTest pass-through + hover tracking)
    var interactiveRect: CGRect {
        IslandGeometry.interactiveRect(
            contentSize: contentSize, topInset: topInset, layout: layout)
    }

    // MARK: - Internal

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
            let shown = IslandPill.isShown(
                active: activeTasks, idle: idleTasks, unread: unreadFinished)
            setDisplay(shown ? .compact : .hidden)
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
        syncCardJump()
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

    /// Card auto-dismissed on time: not counted as read; a finished card leaves an unread mark on
    /// the pill (preview rendering goes through here too)
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

    /// e2e observability: where the card's "open session" button goes
    private func logCardJump(_ jump: SessionJumpOption?) {
        let target: String
        switch jump?.target {
        case .appLink(.claudeDesktop(let localSessionId))?: target = "claude-desktop(\(localSessionId))"
        case .appLink(.codexDesktop(let threadId))?: target = "codex-desktop(\(threadId))"
        case .hostApp(let binding)?: target = "host-app(\(binding.bundleId ?? binding.app ?? "?"))"
        case nil: target = "none"
        }
        print("[eureka] island-jump=\(target) \(jump?.title ?? "")")
        fflush(stdout)
    }
}
