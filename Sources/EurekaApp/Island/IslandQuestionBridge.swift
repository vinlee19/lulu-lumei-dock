import AppKit
import EurekaIngest
import EurekaKit

/// App-side scheduling for island answering: heartbeat, polling pending questions, handing answers
/// to the hook.
///
/// - Heartbeat every 5 seconds: the hook only blocks for an island answer while the heartbeat is
///   fresh, otherwise it exits at once; turning the feature off / quitting the app deletes the
///   heartbeat, and a waiting hook lets go within 2 seconds;
/// - Look at `questions/` every 0.5 seconds: the user sees the card as soon as the hook blocks, and
///   it is withdrawn just as fast when the hook gives up (timeout / turn interrupted);
/// - If the user answers first in Claude's own confirmation UI, the hook is not terminated: polling
///   also checks the session transcript (`QuestionTranscriptProbe`), and once the question is
///   settled, withdraws the card and lets the hook go.
@MainActor
final class IslandQuestionBridge {
    private let inbox: QuestionInbox
    private let probe = QuestionTranscriptProbe()
    private weak var viewModel: IslandViewModel?
    private var pollTimer: Timer?
    private var heartbeatTimer: Timer?
    /// Pending questions seen on the last poll
    private var pending: [PendingQuestion] = []
    /// Questions already settled in Claude whose hook was released: the file lingers until the hook
    /// exits, so don't write "dismiss" again
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

    /// Call before the app quits: waiting hooks learn immediately that the island is gone
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

    /// Dev-mode observability: single-line stdout log, same format as AppDelegate.logLine
    private func log(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
