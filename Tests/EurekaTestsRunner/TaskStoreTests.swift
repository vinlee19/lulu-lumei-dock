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

        let activityEffects = store.apply(event(.activity(tool: nil), at: 130))
        try expectEqual(activityEffects, [.activeTasksChanged])
        guard case .running = store.sortedActiveTasks[0].phase else {
            throw ExpectationError(description: "心跳后应恢复 running")
        }
    }

    t.test("纯心跳只刷新活跃时间，不产生 UI 效果") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), at: 100))
        try expectEqual(store.apply(event(.activity(tool: nil), at: 110)), [])
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

    t.test("Claude turn 完成 → 会话转空闲；正常关闭不出中断卡") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "任务A"), at: 100))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 150))
        try expect(store.sortedActiveTasks.isEmpty, "完成后不算运行中")
        try expectEqual(store.sortedIdleTasks.count, 1, "Claude 会话还开着 → 空闲")
        try expectEqual(store.sortedIdleTasks[0].title, "任务A")

        let endEffects = store.apply(event(.sessionEnded(reason: "other"), at: 200))
        try expectEqual(endEffects, [.activeTasksChanged], "空闲会话关闭只刷 UI，不出卡")
        try expect(store.sortedIdleTasks.isEmpty)
    }

    t.test("双源完成去重：空闲会话再收到完成信号不出卡") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "任务"), at: 100))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 150))
        // transcript 监视器随后也报完成（双源）→ 抑制
        try expectEqual(
            store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 155)),
            [])
        try expectEqual(store.sortedIdleTasks.count, 1, "会话仍是空闲，不被移除")
    }

    t.test("空闲会话再提交 prompt：计时重置、标题换新") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "第一轮"), at: 100))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 200))
        store.apply(event(.taskStarted(title: "第二轮"), at: 300))
        let task = store.sortedActiveTasks[0]
        try expectEqual(task.startedAt, ts(300), "新 turn 重新计时")
        try expectEqual(task.title, "第二轮")
    }

    t.test("Codex 完成直接移除（exec 一次性会话）") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), source: .codex, at: 100))
        store.apply(event(
            .taskFinished(outcome: .success, title: nil, detail: nil), source: .codex, at: 150))
        try expect(store.sortedIdleTasks.isEmpty && store.sortedActiveTasks.isEmpty)
    }

    t.test("sessionStarted 注册空闲会话；心跳发现未知会话登记为运行中") {
        let store = TaskStore()
        store.apply(event(.sessionStarted, session: "opened", at: 100))
        try expectEqual(store.sortedIdleTasks.count, 1)
        try expect(store.sortedActiveTasks.isEmpty, "空闲不算运行")

        // app 在 turn 中途启动：第一个心跳就该把会话挂出来
        let effects = store.apply(event(.activity(tool: "Bash"), session: "midturn", at: 110))
        try expectEqual(effects, [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks.count, 1)
        try expectEqual(store.sortedActiveTasks[0].currentActivity, "Bash")
    }

    t.test("titleUpdate 升级标题（ai-title）") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "原始 prompt 很长"), at: 100))
        try expectEqual(
            store.apply(event(.titleUpdate(title: "修复登录页报错"), at: 110)),
            [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].title, "修复登录页报错")
        try expectEqual(store.apply(event(.titleUpdate(title: "修复登录页报错"), at: 120)), [])
    }

    t.test("会话首启时间：任意事件补设一次，turn 重置不影响它") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "第一轮"), at: 1000))
        // 心跳带来首启时间（管道从文件头读到的）
        var heartbeat = event(.activity(tool: "Bash"), at: 1010)
        heartbeat.sessionStartedAt = ts(500)
        store.apply(heartbeat)
        try expectEqual(store.sortedActiveTasks[0].sessionStartedAt, ts(500))

        // turn 结束→空闲→新 turn：startedAt 重置，sessionStartedAt 不变
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 1100))
        store.apply(event(.taskStarted(title: "第二轮"), at: 2000))
        let task = store.sortedActiveTasks[0]
        try expectEqual(task.startedAt, ts(2000))
        try expectEqual(task.sessionStartedAt, ts(500), "会话首启时间跨 turn 保持")

        // 后续更小的值不覆盖（只设一次）
        var later = event(.activity(tool: nil), at: 2010)
        later.sessionStartedAt = ts(999)
        store.apply(later)
        try expectEqual(store.sortedActiveTasks[0].sessionStartedAt, ts(500))
    }

    t.test("WellnessAdvisor：阈值触发、每小时冷却、歇够重置") {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        // 用白天时间避免误触深夜规则
        let base = calendar.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 14))!
        func input(streakHours: Double?, at offset: TimeInterval = 0) -> WellnessAdvisor.Input {
            WellnessAdvisor.Input(
                now: base.addingTimeInterval(offset),
                streakStartAt: streakHours.map {
                    base.addingTimeInterval(offset - $0 * 3600)
                },
                activeSessionCount: 1, aliveSessionCount: 1)
        }
        let pickFirst: (Int) -> Int = { _ in 0 }

        // 未达阈值不提醒
        var state = WellnessAdvisor.State()
        var result = WellnessAdvisor.evaluate(
            input(streakHours: 1.5), state: state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty)

        // 达阈值提醒一次
        result = WellnessAdvisor.evaluate(
            input(streakHours: 2.1), state: result.state, calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].headline.contains("2 小时"), result.notices[0].headline)

        // 10 分钟后仍在阈值上：冷却期内不重复
        result = WellnessAdvisor.evaluate(
            input(streakHours: 2.3, at: 600), state: result.state,
            calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty, "冷却期内不应重复")

        // 1 小时后再次提醒
        result = WellnessAdvisor.evaluate(
            input(streakHours: 3.2, at: 3700), state: result.state,
            calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)

        // 歇下来（无活跃段）→ 状态重置，下个段重新计
        result = WellnessAdvisor.evaluate(
            input(streakHours: nil, at: 7200), state: result.state,
            calendar: calendar, pick: pickFirst)
        try expect(result.state.lastDurationRemindAt == nil)
    }

    t.test("WellnessAdvisor：会话过多冷却、深夜每晚一次、总开关") {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        let day = calendar.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 14))!
        let night = calendar.date(from: DateComponents(year: 2026, month: 6, day: 11, hour: 23, minute: 30))!
        let pickFirst: (Int) -> Int = { _ in 0 }

        // 会话过多
        var result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: day, streakStartAt: nil, activeSessionCount: 2, aliveSessionCount: 6),
            state: .init(), calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].headline.contains("6 个会话"))
        // 冷却期内不重复
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: day.addingTimeInterval(600), streakStartAt: nil,
                activeSessionCount: 2, aliveSessionCount: 7),
            state: result.state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty)

        // 深夜有任务 → 一次；同晚不再
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: night, streakStartAt: nil, activeSessionCount: 1, aliveSessionCount: 1),
            state: .init(), calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].emoji == "🌙")
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: night.addingTimeInterval(3600),  // 凌晨 0:30 仍算同一晚
                streakStartAt: nil, activeSessionCount: 1, aliveSessionCount: 1),
            state: result.state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty, "同一晚不应重复")

        // 总开关关闭：什么都不发
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: night, streakStartAt: night.addingTimeInterval(-10 * 3600),
                activeSessionCount: 9, aliveSessionCount: 9, enabled: false),
            state: .init(), calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty)
    }

    t.test("StatusTitleComposer：取最大值、分档、回退") {
        func snapshot(_ percent: Double?) -> RateLimitSnapshot? {
            guard let percent else { return nil }
            return RateLimitSnapshot(
                source: .codex, asOf: Date(),
                primary: RateLimitWindow(usedPercent: percent, windowMinutes: 300))
        }
        // 双源取最大
        try expectEqual(
            StatusTitleComposer.maxPrimaryPercent([snapshot(37), snapshot(22)]), 37)
        try expectEqual(StatusTitleComposer.maxPrimaryPercent([nil, nil]), nil)

        // 组装与分档
        let normal = StatusTitleComposer.compose(
            taskCount: 2, hasWaiting: false, maxUsedPercent: 37, showLimit: true)
        try expectEqual(normal.combined, "▶2 · 37%")
        try expectEqual(normal.tier, .normal)

        let warning = StatusTitleComposer.compose(
            taskCount: 1, hasWaiting: true, maxUsedPercent: 72.4, showLimit: true)
        try expectEqual(warning.combined, "⏳1 · 72%")
        try expectEqual(warning.tier, .warning)

        let critical = StatusTitleComposer.compose(
            taskCount: 0, hasWaiting: false, maxUsedPercent: 91, showLimit: true)
        try expectEqual(critical.combined, "✦ · 91%")
        try expectEqual(critical.tier, .critical)

        // 无数据 / 开关关闭 → 回退纯计数
        try expectEqual(
            StatusTitleComposer.compose(
                taskCount: 3, hasWaiting: false, maxUsedPercent: nil, showLimit: true).combined,
            "▶3")
        try expectEqual(
            StatusTitleComposer.compose(
                taskCount: 3, hasWaiting: false, maxUsedPercent: 50, showLimit: false).combined,
            "▶3")
    }

    t.test("HealthRegistry：轮询型停摆判红、事件驱动不误报、失败降级") {
        let registry = HealthRegistry()
        registry.register("poller", expectedInterval: 2)
        registry.register("eventer", expectedInterval: nil)

        var snapshot = Dictionary(uniqueKeysWithValues: registry.snapshot())
        try expectEqual(snapshot["poller"]?.status(), .idle)

        registry.beat("poller")
        registry.beat("eventer")
        snapshot = Dictionary(uniqueKeysWithValues: registry.snapshot())
        try expectEqual(snapshot["poller"]?.status(), .ok)
        // 轮询型：心跳早于 3×interval（且 ≥15s 容忍）→ 停摆
        let future = Date().addingTimeInterval(60)
        try expectEqual(snapshot["poller"]?.status(now: future), .stalled)
        // 事件驱动：不按时间判停摆
        try expectEqual(snapshot["eventer"]?.status(now: future), .ok)

        registry.failure("eventer", note: "坏行")
        snapshot = Dictionary(uniqueKeysWithValues: registry.snapshot())
        try expectEqual(snapshot["eventer"]?.status(), .degraded)
        try expectEqual(snapshot["eventer"]?.failureCount, 1)
    }

    t.test("超时清理：空闲会话静默移除不出卡") {
        let store = TaskStore()
        store.apply(event(.sessionStarted, session: "old-idle", at: 0))
        let effects = store.reapStaleTasks(now: ts(20000), runningTimeout: 4 * 3600)
        try expectEqual(effects, [.activeTasksChanged], "空闲超时不该有 taskFinished")
        try expect(store.sortedIdleTasks.isEmpty)
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

    t.test("心跳带工具名：更新当前活动并刷 UI；同名不重复刷") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), at: 100))
        try expectEqual(
            store.apply(event(.activity(tool: "Bash"), at: 110)), [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].currentActivity, "Bash")
        try expectEqual(store.apply(event(.activity(tool: "Bash"), at: 120)), [])
        try expectEqual(
            store.apply(event(.activity(tool: "Edit"), at: 130)), [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].currentActivity, "Edit")
    }

    t.test("上下文占用更新：整数桶变化才刷 UI") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), at: 100))
        try expectEqual(
            store.apply(event(.contextUpdate(percent: 41.2), at: 110)), [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].contextUsedPercent, 41.2)
        try expectEqual(store.apply(event(.contextUpdate(percent: 41.4), at: 111)), [])
        try expectEqual(
            store.apply(event(.contextUpdate(percent: 87.0), at: 120)), [.activeTasksChanged])
        // 没有对应任务的上下文更新是无操作
        try expectEqual(
            store.apply(event(.contextUpdate(percent: 50), session: "ghost", at: 130)), [])
    }

    t.test("超时清理：只清理无活动的任务") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "老任务"), session: "old", at: 0))
        store.apply(event(.taskStarted(title: "新任务"), session: "new", at: 0))
        store.apply(event(.activity(tool: nil), session: "new", at: 14000))

        let effects = store.reapStaleTasks(now: ts(14500), runningTimeout: 4 * 3600)
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.sessionId, "old")
        try expectEqual(finished.outcome, .interrupted)
        try expectEqual(store.sortedActiveTasks.map(\.sessionId), ["new"])
    }
}
