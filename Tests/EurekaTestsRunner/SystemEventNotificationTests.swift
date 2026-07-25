import EurekaKit
import Foundation

private func finishedTask(
    outcome: TaskOutcome,
    title: String? = "修复报错",
    cwd: String? = "/Users/me/work/demo",
    session: String = "s1"
) -> FinishedTask {
    FinishedTask(
        source: .claude, sessionId: session, title: title, cwd: cwd,
        startedAt: Date(timeIntervalSince1970: 100),
        finishedAt: Date(timeIntervalSince1970: 160), outcome: outcome)
}

private func waitingTask(
    reason: WaitReason = .permission,
    title: String? = nil,
    cwd: String? = nil
) -> AgentTask {
    AgentTask(
        source: .codex, sessionId: "s2", title: title, cwd: cwd,
        startedAt: Date(timeIntervalSince1970: 100),
        phase: .waiting(reason, since: Date(timeIntervalSince1970: 120)))
}

func systemEventNotificationTests(_ t: TestRunner) {
    t.suite("SystemEventNotifications")

    t.test("主开关关闭：任何事件都不发") {
        try expect(SystemEventNotifications.forFinished(
            finishedTask(outcome: .success),
            master: false, completion: true, error: true) == nil)
        try expect(SystemEventNotifications.forWaiting(
            waitingTask(), master: false, waiting: true) == nil)
    }

    t.test("完成成功：受 notifyCompletion 门控，文案含来源/标题/项目") {
        let note = SystemEventNotifications.forFinished(
            finishedTask(outcome: .success),
            master: true, completion: true, error: false)
        try expectEqual(note?.title, "任务完成")
        try expectEqual(note?.body, "Claude Code · 修复报错 · demo")
        try expect(SystemEventNotifications.forFinished(
            finishedTask(outcome: .success),
            master: true, completion: false, error: true) == nil)
    }

    t.test("出错/中断：受 notifyError 门控") {
        try expectEqual(SystemEventNotifications.forFinished(
            finishedTask(outcome: .error),
            master: true, completion: false, error: true)?.title, "任务出错")
        try expectEqual(SystemEventNotifications.forFinished(
            finishedTask(outcome: .interrupted),
            master: true, completion: true, error: true)?.title, "任务中断")
        try expect(SystemEventNotifications.forFinished(
            finishedTask(outcome: .error),
            master: true, completion: true, error: false) == nil)
    }

    t.test("无标题时正文退回项目名，再退回会话号") {
        try expectEqual(SystemEventNotifications.forFinished(
            finishedTask(outcome: .success, title: nil),
            master: true, completion: true, error: true)?.body, "Claude Code · demo")
        try expectEqual(SystemEventNotifications.forFinished(
            finishedTask(outcome: .success, title: nil, cwd: nil, session: "abcdef123456"),
            master: true, completion: true, error: true)?.body,
            "Claude Code · 会话 abcdef12")
    }

    t.test("等待确认：受 notifyWaiting 门控，标题用等待原因") {
        let note = SystemEventNotifications.forWaiting(
            waitingTask(), master: true, waiting: true)
        try expectEqual(note?.title, "等待权限确认")
        try expect(note?.identifier.hasPrefix("eureka-event-waiting-") == true)
        try expect(SystemEventNotifications.forWaiting(
            waitingTask(), master: true, waiting: false) == nil)
        try expectEqual(SystemEventNotifications.forWaiting(
            waitingTask(reason: .idle), master: true, waiting: true)?.title, "等待输入")
    }

    t.test("非等待态任务不产生等待通知（防御）") {
        var task = waitingTask()
        task.phase = .running
        try expect(SystemEventNotifications.forWaiting(
            task, master: true, waiting: true) == nil)
    }
}
