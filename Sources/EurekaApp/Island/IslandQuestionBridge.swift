import AppKit
import EurekaIngest
import EurekaKit

/// 灵动岛答题的 app 侧调度：心跳、轮询等待中的问题、把回答交给 hook。
///
/// - 心跳每 5 秒一次：hook 只在心跳新鲜时才挂起等岛上的回答，否则立刻让 Claude 回终端提问；
///   关掉功能 / app 退出时删掉心跳，正在等的 hook 2 秒内放手；
/// - 每 0.5 秒看一眼 `questions/`：hook 挂起后用户能马上看到卡片，hook 放弃（超时 / 终端里中断）也能马上撤卡。
@MainActor
final class IslandQuestionBridge {
    private let inbox: QuestionInbox
    private weak var viewModel: IslandViewModel?
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    private var lastIds: [String] = []
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
            lastIds = []
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
            log("灵动岛答题心跳写入失败: \(error)")
        }
    }

    private func poll() {
        let pending = inbox.pending()
        let ids = pending.map(\.id)
        guard ids != lastIds else { return }
        for question in pending where !lastIds.contains(question.id) {
            log("question=\(question.id) count=\(question.questions.count)")
        }
        lastIds = ids
        viewModel?.updatePendingQuestions(pending)
    }

    private func send(_ reply: IslandViewModel.QuestionReply, to id: String) {
        let message: QuestionInbox.Reply
        switch reply {
        case .answer(let answers): message = .answer(answers)
        case .terminal: message = .terminal
        }
        do {
            try inbox.send(message, to: id)
            log("question-reply=\(id) \(reply == .terminal ? "terminal" : "answer")")
        } catch {
            log("灵动岛答题回写失败 \(id): \(error)")
        }
    }

    /// 开发模式可观测性：stdout 单行日志，与 AppDelegate.logLine 同格式
    private func log(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
