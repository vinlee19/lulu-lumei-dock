import AppKit
import EurekaIngest
import EurekaKit

/// 灵动岛答题的 app 侧调度：心跳、轮询等待中的问题、把回答交给 hook。
///
/// - 心跳每 5 秒一次：hook 只在心跳新鲜时才挂起等岛上的回答，否则立刻退出；
///   关掉功能 / app 退出时删掉心跳，正在等的 hook 2 秒内放手；
/// - 每 0.5 秒看一眼 `questions/`：hook 挂起后用户能马上看到卡片，hook 放弃（超时 / 这一轮被中断）也能马上撤卡；
/// - 用户在 Claude 自己的确认界面里先答时 hook 不会被终止：轮询时顺带看会话转录（`QuestionTranscriptProbe`），
///   题已了结就撤卡并让 hook 放手。
@MainActor
final class IslandQuestionBridge {
    private let inbox: QuestionInbox
    private let probe = QuestionTranscriptProbe()
    private weak var viewModel: IslandViewModel?
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    /// 上次轮询看到的等待中问题
    private var pending: [PendingQuestion] = []
    /// 已在 Claude 里了结、让 hook 放手的题：hook 退出前文件还在，别重复写「收起」
    private var settledIds: Set<String> = []
    private(set) var isEnabled = false

    init(viewModel: IslandViewModel, inbox: QuestionInbox = QuestionInbox()) {
        self.viewModel = viewModel
        self.inbox = inbox
        viewModel.onQuestionReply = { [weak self] id, reply in
            self?.send(reply, to: id)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            beat()
            heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.beat() }
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            poll()
        } else {
            heartbeatTimer?.invalidate()
            pollTimer?.invalidate()
            heartbeatTimer = nil
            pollTimer = nil
            inbox.removeHeartbeat()
            pending = []
            settledIds = []
            probe.retain(only: [])
            viewModel?.updatePendingQuestions([])
        }
    }

    /// app 退出前调用：等待中的 hook 立刻知道岛不在了
    func stop() {
        inbox.removeHeartbeat()
    }

    private func beat() {
        do {
            try inbox.writeHeartbeat()
        } catch {
            log(L10n.format(
                "Writing the island question heartbeat failed: %@",
                zhHans: "灵动岛答题心跳写入失败: %@", String(describing: error)))
        }
    }

    private func poll() {
        let current = inbox.pending()
        let ids = current.map(\.id)
        probe.retain(only: Set(ids))
        for question in current where !settledIds.contains(question.id) && probe.isSettled(question) {
            settledIds.insert(question.id)
            log("question-settled=\(question.id)")
            send(.dismiss, to: question.id)
            viewModel?.withdrawQuestion(id: question.id)
        }
        guard ids != pending.map(\.id) else { return }
        let previous = Set(pending.map(\.id))
        for question in current where !previous.contains(question.id) {
            log("question=\(question.id) count=\(question.questions.count)")
        }
        pending = current
        settledIds.formIntersection(ids)
        viewModel?.updatePendingQuestions(current.filter { !settledIds.contains($0.id) })
    }

    private func send(_ reply: IslandViewModel.QuestionReply, to id: String) {
        let message: QuestionInbox.Reply
        switch reply {
        case .answer(let answers): message = .answer(answers)
        case .dismiss: message = .dismiss
        }
        do {
            try inbox.send(message, to: id)
            log("question-reply=\(id) \(reply == .dismiss ? "dismiss" : "answer")")
        } catch {
            log(L10n.format(
                "Writing the island answer %@ failed: %@",
                zhHans: "灵动岛答题回写失败 %@: %@", id, String(describing: error)))
        }
    }

    /// 开发模式可观测性：stdout 单行日志，与 AppDelegate.logLine 同格式
    private func log(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
