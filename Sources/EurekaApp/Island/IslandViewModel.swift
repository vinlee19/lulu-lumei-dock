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
    /// 按时收起、用户还没点开看过的完成卡：胶囊上的「✓ N」，有它时即使没有运行中任务岛也不隐藏
    @Published private(set) var unreadFinished = IslandUnreadFinished()
    /// 任务列表里当前展开子 agent 框的任务 id（nil = 全收起；单开，几何有界）
    @Published private(set) var expandedSubagentTaskId: String?
    @Published private(set) var screen = IslandGeometry.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
    /// 用户把岛拖到了自定义位置：脱离刘海融合，渲染为四角全圆的悬浮样式
    @Published var isFloating = false
    /// 时间显示模式：false=已持续时长（计时器），true=开始的日期时间。
    /// 真值在 AppSettings（设置页与岛上按钮共用），这里只是投影。
    @Published var showStartTime = false
    /// 岛上切换按钮回调（AppDelegate 接到 AppSettings）
    var onToggleTimeMode: (@MainActor () -> Void)?

    /// 当前屏对应布局（随 screen 变化按比例缩放）
    var layout: IslandGeometry.Layout { IslandGeometry.layout(for: screen) }
    /// 当前屏 UI 缩放系数（字体/内边距/徽标用；pill 高度受刘海钉死，不适用）
    var uiScale: CGFloat { IslandGeometry.scaleFactor(for: screen) }
    /// 卡片自动收起的**基准**秒数（设置页 3–15s 可调）。
    /// 各类卡在此之上叠加自己的偏移，见 `IslandState.Card.autoDismissExtraSeconds`。
    var autoDismissSeconds: TimeInterval = 6

    /// 展示形态变化回调（panel 控制器据此显隐窗口）
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
        /// 岛上收起，到 Claude 自己的确认界面里回答
        case dismiss
    }

    private var queue = IslandCardQueue()
    private var hovering = false
    private var dismissTimer: Timer?
    /// 当前收起计时是为哪张卡排的。用来区分「换了卡」与「同一张卡被状态刷新重复投影」——
    /// 后者绝不能重排计时，否则倒计时被无限拨回起点（见 refresh）。
    private var timerCard: IslandState.Card?

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

    /// 与 hook 那边等待中的问题对账：新来的入队，已不在等待的（hook 超时 / 这一轮被中断）撤卡
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

    /// 「在 Claude 里回答」：收起岛上的卡，hook 静默退出，Claude 自己的确认界面一直都在
    func dismissQuestion() {
        guard let draft = questionDraft else { return }
        finishQuestion(id: draft.question.id, reply: .dismiss)
    }

    /// 这道题已在 Claude 里了结（IslandQuestionBridge 判定）：撤卡，不再回写 hook
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

    /// 任务列表展开时点了岛外（其他 app / 桌面 / 本 app 其他窗口）→ 立即收起。
    /// 只管点击展开的任务列表；卡片是定时通知，岛外点击不撤卡
    func dismissTaskList() {
        guard case .taskList = display else { return }
        refresh(collapseTaskList: true)
    }

    /// 行内展开/收起某任务的子 agent 框（任务列表里的内层按钮调用）
    func toggleSubagentExpansion(_ taskId: String) {
        expandedSubagentTaskId = (expandedSubagentTaskId == taskId) ? nil : taskId
        scheduleAutoDismiss()  // 展开=用户在看，续期收起计时
    }

    func setHovering(_ value: Bool) {
        hovering = value
        if !value {
            hoverExtensions = 0
            // 真正移开后正常计时收起。**判据与 refresh() 共用 card.autoDismisses** ——
            // 这里原本硬列 case，漏掉等待卡，导致它「悬停过一次就退回常驻」。
            switch display {
            case .card(let card) where card.autoDismisses:
                scheduleAutoDismiss(extraSeconds: card.autoDismissExtraSeconds ?? 0)
            case .taskList:
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
            // **只在换卡时重排计时**。refresh() 会被 updateActiveTasks 频繁调用（各源 tailer
            // 2 秒一轮），无条件重排等于每 2 秒把倒计时拨回起点 —— 卡片于是永远收不掉。
            // 实测：等待卡 15 秒里被刷新 6 次，一次都没收；完成卡只因 6 秒窗口短才偶尔抢在
            // 两次刷新之间收掉，notice(11s) / alert(12s) 窗口更长，中招更稳。
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
        // 离开任务列表即收起子 agent 框，避免下次再进时停在旧展开态
        if case .taskList = new {} else { expandedSubagentTaskId = nil }
        display = new
        syncQuestionDraft()
        logIsland(new)
        onDisplayChange?(new)
    }

    /// 悬停时收起被"续期"而非取消：mouseExited 可能被 performDrag 等吞掉导致
    /// hover 永久卡住——续期 + 硬上限保证岛绝不会停在旧内容上（曾导致整夜不更新）。
    private var hoverExtensions = 0
    private let maxHoverExtensions = 5

    private func scheduleAutoDismiss(extraSeconds: TimeInterval = 0) {
        cancelAutoDismiss()
        dismissTimer = Timer.scheduledTimer(
            withTimeInterval: autoDismissSeconds + extraSeconds, repeats: false
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

    /// e2e 可观测性
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
