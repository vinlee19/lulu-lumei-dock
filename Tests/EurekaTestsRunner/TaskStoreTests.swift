import Foundation
import EurekaKit

private func ts(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

private func event(
    _ kind: TaskEvent.Kind,
    source: AgentSource = .claude,
    session: String = "s1",
    at: TimeInterval,
    cwd: String? = "/Users/me/work/demo"
) -> TaskEvent {
    TaskEvent(source: source, sessionId: session, kind: kind, timestamp: ts(at), cwd: cwd)
}

private func finishedTask(in effects: [TaskStoreEffect]) throws -> FinishedTask {
    for case .taskFinished(let task) in effects { return task }
    throw ExpectationError(description: "effects 中没有 taskFinished: \(effects)")
}

func taskStoreTests(_ t: TestRunner) {
    t.suite("TaskStore")

    t.test("开始→完成：配对计算耗时，沿用开始时的标题") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "修复报错"), at: 100))
        try expectEqual(store.sortedActiveTasks.count, 1)

        let effects = store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 160))
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.duration, 60)
        try expectEqual(finished.title, "修复报错")
        try expectEqual(finished.outcome, .success)
        try expect(store.sortedActiveTasks.isEmpty, "完成后应移除活跃任务")
    }

    t.test("没赶上开始的完成事件：照样出卡但无耗时") {
        let store = TaskStore()
        let effects = store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 200))
        let finished = try finishedTask(in: effects)
        try expect(finished.duration == nil)
        try expect(finished.startedAt == nil)
    }

    t.test("等待确认→心跳复位 running") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "跑测试"), at: 100))
        let waitingEffects = store.apply(event(.waiting(reason: .permission, message: "需要 Bash 权限"), at: 120))
        try expect(waitingEffects.contains { if case .taskWaiting = $0 { return true } else { return false } })
        guard case .waiting(.permission, since: ts(120)) = store.sortedActiveTasks[0].phase else {
            throw ExpectationError(description: "应处于 waiting(permission)")
        }

        let activityEffects = store.apply(event(.activity, at: 130))
        try expectEqual(activityEffects, [.activeTasksChanged])
        guard case .running = store.sortedActiveTasks[0].phase else {
            throw ExpectationError(description: "心跳后应恢复 running")
        }
    }

    t.test("纯心跳只刷新活跃时间，不产生 UI 效果") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), at: 100))
        try expectEqual(store.apply(event(.activity, at: 110)), [])
        try expectEqual(store.sortedActiveTasks[0].lastActivityAt, ts(110))
    }

    t.test("等待输入后用户再次提交 prompt：恢复 running 且保留原开始时间") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "第一个任务"), at: 100))
        store.apply(event(.waiting(reason: .idle, message: nil), at: 200))
        store.apply(event(.taskStarted(title: "继续"), at: 300))
        let task = store.sortedActiveTasks[0]
        try expectEqual(task.startedAt, ts(100))
        try expectEqual(task.title, "第一个任务")
        guard case .running = task.phase else {
            throw ExpectationError(description: "应恢复 running")
        }
    }

    t.test("任务运行中会话结束：判为中断") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "长任务"), at: 100))
        let effects = store.apply(event(.sessionEnded(reason: "prompt_input_exit"), at: 150))
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.outcome, .interrupted)
        try expect(store.sortedActiveTasks.isEmpty)
    }

    t.test("正常完成后的会话结束是无操作") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), at: 100))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 150))
        try expectEqual(store.apply(event(.sessionEnded(reason: "other"), at: 151)), [])
    }

    t.test("没赶上开始的等待事件：以 waiting 登记新任务") {
        let store = TaskStore()
        let effects = store.apply(event(.waiting(reason: .permission, message: "需要权限"), at: 100))
        try expect(effects.contains { if case .taskWaiting = $0 { return true } else { return false } })
        try expectEqual(store.sortedActiveTasks.count, 1)
    }

    t.test("多会话并发：按开始时间排序，互不影响") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "B"), session: "s2", at: 200))
        store.apply(event(.taskStarted(title: "A"), session: "s1", at: 100))
        store.apply(event(.taskStarted(title: "C"), source: .codex, session: "s1", at: 300))
        try expectEqual(store.sortedActiveTasks.map(\.title), ["A", "B", "C"])

        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), session: "s2", at: 400))
        try expectEqual(store.sortedActiveTasks.map(\.title), ["A", "C"])
        try expectEqual(store.sortedActiveTasks[0].id, "claude:s1")
        try expectEqual(store.sortedActiveTasks[1].id, "codex:s1")
    }

    t.test("超时清理：只清理无活动的任务") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "老任务"), session: "old", at: 0))
        store.apply(event(.taskStarted(title: "新任务"), session: "new", at: 0))
        store.apply(event(.activity, session: "new", at: 14000))

        let effects = store.reapStaleTasks(now: ts(14500), runningTimeout: 4 * 3600)
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.sessionId, "old")
        try expectEqual(finished.outcome, .interrupted)
        try expectEqual(store.sortedActiveTasks.map(\.sessionId), ["new"])
    }
}
