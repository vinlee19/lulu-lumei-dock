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

private func firstActive(_ store: TaskStore) throws -> AgentTask {
    guard let task = store.sortedActiveTasks.first else {
        throw ExpectationError(description: "没有运行中的任务")
    }
    return task
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

    t.test("会话最初开始时间贯通到完成任务（历史开始时间排序用）") {
        let store = TaskStore()
        store.apply(TaskEvent(
            source: .claude, sessionId: "s1", kind: .taskStarted(title: "x"),
            timestamp: ts(100), cwd: "/w", sessionStartedAt: ts(50)))
        let effects = store.apply(
            event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 160))
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.sessionStartedAt, ts(50))
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
        // The transcript watcher then reports completion too (dual source) → suppressed
        try expectEqual(
            store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 155)),
            [])
        try expectEqual(store.sortedIdleTasks.count, 1, "会话仍是空闲，不被移除")
    }

    t.test("双源短 turn：hooks 已收尾，transcript 补报的开始+完成不复活、不出第二张卡") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "任务"), at: 100))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 103))
        // The transcript watcher only sees this turn on its next poll: the start time is the prompt
        // time (earlier than the wrap-up)
        try expectEqual(store.apply(event(.taskStarted(title: "任务"), at: 100)), [])
        try expectEqual(
            store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 103)),
            [])
        try expectEqual(store.sortedIdleTasks.count, 1, "仍是空闲")
        // A genuinely new prompt later than the last wrap-up → a new turn starts normally
        store.apply(event(.taskStarted(title: "下一轮"), at: 200))
        try expectEqual(store.sortedActiveTasks.first?.title, "下一轮")
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

    t.test("Codex 完成后变空闲（可跨 turn 持续可见，由 reapStaleTasks 回收）") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: nil), source: .codex, at: 100))
        store.apply(event(
            .taskFinished(outcome: .success, title: nil, detail: nil), source: .codex, at: 150))
        // After finishing, the session stays in the idle area (not counted as active)
        try expect(store.sortedActiveTasks.isEmpty, "active 应为空")
        try expectEqual(store.sortedIdleTasks.count, 1, "idle 应有 Codex 会话")
        try expectEqual(store.sortedIdleTasks[0].source, .codex)
    }

    t.test("sessionStarted 注册空闲会话；心跳发现未知会话登记为运行中") {
        let store = TaskStore()
        store.apply(event(.sessionStarted, session: "opened", at: 100))
        try expectEqual(store.sortedIdleTasks.count, 1)
        try expect(store.sortedActiveTasks.isEmpty, "空闲不算运行")

        // App launched mid-turn: the first heartbeat should surface the session
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

    t.test("cwd 只补一次：首见事件没带 cwd，后续任一事件带来就补上并刷新 UI") {
        let store = TaskStore()
        // Desktop's first turn: the tail holds only metadata lines → the first snapshot has neither a
        // prompt nor a cwd (registered as idle)
        store.apply(event(.sessionStarted, at: 100, cwd: nil))
        try expectEqual(store.sortedIdleTasks[0].projectName, nil)
        try expectEqual(
            store.apply(event(.taskStarted(title: nil), at: 110, cwd: "/Users/me/work/demo")),
            [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].projectName, "demo")
        // An existing cwd is never overwritten by a later one
        store.apply(event(.activity(tool: nil), at: 120, cwd: "/Users/me/work/other"))
        try expectEqual(store.sortedActiveTasks[0].cwd, "/Users/me/work/demo")

        // A heartbeat with unchanged state normally returns []; backfilling cwd refreshes once (the
        // project name only becomes visible now)
        let midturn = TaskStore()
        midturn.apply(event(.taskStarted(title: nil), at: 100, cwd: nil))
        try expectEqual(
            midturn.apply(event(.activity(tool: nil), at: 105, cwd: "/Users/me/work/demo")),
            [.activeTasksChanged])
        try expectEqual(midturn.sortedActiveTasks[0].projectName, "demo")
        try expectEqual(midturn.apply(event(.activity(tool: nil), at: 106, cwd: "/Users/me/work/demo")), [])
    }

    t.test("会话首启时间：任意事件补设一次，turn 重置不影响它") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "第一轮"), at: 1000))
        // The heartbeat carries the first-start time (read by the pipeline from the file head)
        var heartbeat = event(.activity(tool: "Bash"), at: 1010)
        heartbeat.sessionStartedAt = ts(500)
        store.apply(heartbeat)
        try expectEqual(store.sortedActiveTasks[0].sessionStartedAt, ts(500))

        // Turn ends → idle → new turn: startedAt resets, sessionStartedAt stays
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 1100))
        store.apply(event(.taskStarted(title: "第二轮"), at: 2000))
        let task = store.sortedActiveTasks[0]
        try expectEqual(task.startedAt, ts(2000))
        try expectEqual(task.sessionStartedAt, ts(500), "会话首启时间跨 turn 保持")

        // A later smaller value doesn't overwrite (set only once)
        var later = event(.activity(tool: nil), at: 2010)
        later.sessionStartedAt = ts(999)
        store.apply(later)
        try expectEqual(store.sortedActiveTasks[0].sessionStartedAt, ts(500))
    }

    t.test("WellnessAdvisor：阈值触发、每小时冷却、歇够重置") {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        // Use a daytime hour so the late-night rule isn't triggered by accident
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

        // Below the threshold: no reminder
        var state = WellnessAdvisor.State()
        var result = WellnessAdvisor.evaluate(
            input(streakHours: 1.5), state: state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty)

        // Threshold reached: remind once
        result = WellnessAdvisor.evaluate(
            input(streakHours: 2.1), state: result.state, calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].headline.contains("2 小时"), result.notices[0].headline)

        // Still above the threshold 10 minutes later: no repeat within the cooldown
        result = WellnessAdvisor.evaluate(
            input(streakHours: 2.3, at: 600), state: result.state,
            calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty, "冷却期内不应重复")

        // Remind again after 1 hour
        result = WellnessAdvisor.evaluate(
            input(streakHours: 3.2, at: 3700), state: result.state,
            calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)

        // Quiet down (no active segment) → state resets, the next segment counts afresh
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

        // too many sessions
        var result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: day, streakStartAt: nil, activeSessionCount: 2, aliveSessionCount: 6),
            state: .init(), calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].headline.contains("6 个会话"))
        // No repeat within the cooldown
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: day.addingTimeInterval(600), streakStartAt: nil,
                activeSessionCount: 2, aliveSessionCount: 7),
            state: result.state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty)

        // A task late at night → once; not again the same night
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: night, streakStartAt: nil, activeSessionCount: 1, aliveSessionCount: 1),
            state: .init(), calendar: calendar, pick: pickFirst)
        try expectEqual(result.notices.count, 1)
        try expect(result.notices[0].emoji == "🌙")
        result = WellnessAdvisor.evaluate(
            WellnessAdvisor.Input(
                now: night.addingTimeInterval(3600),  // 0:30 a.m. still counts as the same night
                streakStartAt: nil, activeSessionCount: 1, aliveSessionCount: 1),
            state: result.state, calendar: calendar, pick: pickFirst)
        try expect(result.notices.isEmpty, "同一晚不应重复")

        // Master switch off: nothing is sent
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
        // Take the max of the two sources
        try expectEqual(
            StatusTitleComposer.maxPrimaryPercent([snapshot(37), snapshot(22)]), 37)
        try expectEqual(StatusTitleComposer.maxPrimaryPercent([nil, nil]), nil)

        // Assembly and bucketing
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

        // No data / switch off → fall back to a plain count
        try expectEqual(
            StatusTitleComposer.compose(
                taskCount: 3, hasWaiting: false, maxUsedPercent: nil, showLimit: true).combined,
            "▶3")
        try expectEqual(
            StatusTitleComposer.compose(
                taskCount: 3, hasWaiting: false, maxUsedPercent: 50, showLimit: false).combined,
            "▶3")
    }

    t.test("StatusTitleComposer：窗口已过重置时刻的快照不计入徽标") {
        let now = ts(1_000_000)
        func snapshot(_ percent: Double, resetsAt: Date?) -> RateLimitSnapshot {
            RateLimitSnapshot(
                source: .codex, asOf: now.addingTimeInterval(-7 * 86400),
                primary: RateLimitWindow(
                    usedPercent: percent, windowMinutes: 300, resetsAt: resetsAt),
                isStale: true)
        }
        // A week-old snapshot: its 5h window reset long ago, so 9% describes a window that no longer exists
        let expired = snapshot(9, resetsAt: now.addingTimeInterval(-6 * 86400))
        let live = snapshot(22, resetsAt: now.addingTimeInterval(3600))
        // No reset time: cannot be judged expired, counts as usual
        let unknown = snapshot(5, resetsAt: nil)

        try expect(expired.primary!.hasReset(at: now))
        try expect(!live.primary!.hasReset(at: now))
        try expect(!unknown.primary!.hasReset(at: now))
        try expectEqual(
            StatusTitleComposer.maxPrimaryPercent([expired, live, unknown], now: now), 22)
        try expectEqual(StatusTitleComposer.maxPrimaryPercent([expired], now: now), nil)
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
        // Polling type: heartbeat older than 3×interval (with ≥15s tolerance) → stalled
        let future = Date().addingTimeInterval(60)
        try expectEqual(snapshot["poller"]?.status(now: future), .stalled)
        // Event-driven: stalls are not judged by time
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
        // A context update with no matching task is a no-op
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

    t.test("subagentsUpdated：存入子 agent、相同快照幂等、未知会话不建任务") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "主任务"), at: 100))
        let subs = [SubagentInfo(
            agentId: "a1", agentType: "Explore", description: "探索", status: .running)]
        try expectEqual(
            store.apply(event(.subagentsUpdated(subs), at: 110)), [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks[0].subagents, subs)
        // An identical snapshot doesn't refresh the UI (guards against 5s jitter)
        try expectEqual(store.apply(event(.subagentsUpdated(subs), at: 111)), [])
        // Unknown session: don't create a task out of thin air
        try expectEqual(
            store.apply(event(.subagentsUpdated(subs), session: "ghost", at: 112)), [])
        try expectEqual(store.sortedActiveTasks.count, 1)
    }

    t.test("turn 收尾转空闲时清空子 agent") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "主任务"), at: 100))
        store.apply(event(.subagentsUpdated([SubagentInfo(
            agentId: "a1", agentType: "Plan", description: "设计", status: .completed)]), at: 110))
        store.apply(event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 160))
        try expect(
            store.sortedIdleTasks.first?.subagents.isEmpty ?? false, "收尾后应清空子 agent")
    }

    t.test("等待后台任务：不出完成卡、保持运行；回报轮里清零；全部回报后的收尾才出一张卡") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "复核归因"), at: 100))
        store.apply(event(.toolPending(tool: "Agent", detail: "复核 A 组"), at: 110))

        // The main agent ends its turn while two background agents run
        try expectEqual(
            store.apply(event(.awaitingBackgroundTasks(count: 2), at: 150)), [.activeTasksChanged])
        var task = try firstActive(store)
        try expectEqual(task.phase, .running)
        try expectEqual(task.awaitingBackgroundTasks, 2)
        try expectEqual(task.currentActivity, nil, "收尾后不该还显示上一个工具")
        try expectEqual(task.currentToolDetail, nil)
        try expectEqual(task.startedAt, ts(100))
        // Repeats (hook Stop and the transcript watcher both report it) change nothing
        try expectEqual(store.apply(event(.awaitingBackgroundTasks(count: 2), at: 151)), [])

        // The first report starts a turn: the main agent works again
        store.apply(event(.taskStarted(title: nil), at: 900))
        task = try firstActive(store)
        try expectEqual(task.awaitingBackgroundTasks, 0)
        try expectEqual(task.title, "复核归因", "回报轮没有标题，沿用原任务名")
        try expectEqual(task.startedAt, ts(100), "回报轮不重新计时")
        try expectEqual(
            store.apply(event(.awaitingBackgroundTasks(count: 1), at: 950)), [.activeTasksChanged])
        store.apply(event(.activity(tool: "Read"), at: 960))
        try expectEqual(try firstActive(store).awaitingBackgroundTasks, 0,
                        "主 agent 又动起来就清零")
        store.apply(event(.awaitingBackgroundTasks(count: 1), at: 970))

        // The last report's turn ends with nothing outstanding: exactly one card for the whole job
        let effects = store.apply(
            event(.taskFinished(outcome: .success, title: nil, detail: nil), at: 1200))
        let finished = try finishedTask(in: effects)
        try expectEqual(finished.startedAt, ts(100))
        try expectEqual(finished.title, "复核归因")
        try expectEqual(store.sortedIdleTasks.first?.awaitingBackgroundTasks, 0)
    }

    t.test("等待后台任务：未知会话登记为运行；空闲会话转运行；等待中被关会话判中断") {
        let store = TaskStore()
        try expectEqual(
            store.apply(event(.awaitingBackgroundTasks(count: 3), session: "late", at: 100)),
            [.activeTasksChanged])
        try expectEqual(store.sortedActiveTasks.first?.awaitingBackgroundTasks, 3)

        store.apply(event(.sessionStarted, session: "quiet", at: 100))
        store.apply(event(.awaitingBackgroundTasks(count: 1), session: "quiet", at: 120))
        try expectEqual(store.sortedActiveTasks.count, 2)

        let effects = store.apply(
            event(.sessionEnded(reason: "进程已退出"), session: "late", at: 200))
        try expectEqual(try finishedTask(in: effects).outcome, .interrupted)
    }
}
