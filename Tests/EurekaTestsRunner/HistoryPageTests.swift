import EurekaKit
import EurekaStore
import Foundation

// 历史页改版配套：TaskHistoryRepo 新查询 + 四档分组边界。
// 分组逻辑是纯函数（Sources/EurekaKit/HistoryGrouping.swift），用固定日期构造边界。

func historyPageTests(_ t: TestRunner) {
    t.suite("TaskHistoryRepo · 区间查询与按天聚合")

    /// 内存库替代：临时文件库（schema 迁移走正式路径，与线上同构）
    func makeStore() throws -> (EurekaStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try EurekaStore(path: dir.appendingPathComponent("t.sqlite")), dir)
    }

    func task(
        _ id: String, finishedAt: Date, outcome: TaskOutcome = .success
    ) -> FinishedTask {
        FinishedTask(
            source: .claude, sessionId: id, title: id, cwd: "/w",
            startedAt: finishedAt.addingTimeInterval(-60),
            finishedAt: finishedAt, outcome: outcome)
    }

    // 固定参考时间：2026-08-09 12:00 本地（历史页窗口语义与墙钟无关，全靠 since 过滤）
    let base = Date(timeIntervalSince1970: 1_786_248_000)  // 2026-08-09 附近
    let cal = Calendar.current
    let day0 = cal.startOfDay(for: base)

    t.test("tasks(since:limit:)：区间过滤 + finished_at 倒序 + limit") {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 区间内 3 条 + 区间外 1 条
        try store.history.insert(task("old", finishedAt: day0.addingTimeInterval(-15 * 86400)))
        try store.history.insert(task("a", finishedAt: day0.addingTimeInterval(-2 * 86400)))
        try store.history.insert(task("b", finishedAt: day0.addingTimeInterval(-86400)))
        try store.history.insert(task("c", finishedAt: day0))

        let since = day0.addingTimeInterval(-14 * 86400)
        let all = try store.history.tasks(since: since, limit: 200)
        try expectEqual(all.map(\.sessionId), ["c", "b", "a"])  // 倒序，old 被区间滤掉

        let limited = try store.history.tasks(since: since, limit: 2)
        try expectEqual(limited.map(\.sessionId), ["c", "b"])
    }

    t.test("dailyOutcomeCounts：按天×结局聚合，区间外不计") {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.history.insert(task("s1", finishedAt: day0, outcome: .success))
        try store.history.insert(task("s2", finishedAt: day0.addingTimeInterval(3600), outcome: .success))
        try store.history.insert(task("e1", finishedAt: day0, outcome: .error))
        try store.history.insert(task("i1", finishedAt: day0.addingTimeInterval(-86400), outcome: .interrupted))
        try store.history.insert(task("old", finishedAt: day0.addingTimeInterval(-30 * 86400)))

        let rows = try store.history.dailyOutcomeCounts(
            since: day0.addingTimeInterval(-14 * 86400))
        // (day, outcome, count) 聚合：昨天 interrupted 1，今天 success 2 + error 1
        let lookup = Dictionary(
            rows.map { ("\($0.day)|\($0.outcome)", $0.count) },
            uniquingKeysWith: +)
        try expectEqual(rows.count, 3)
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        let day0Str = fmt.string(from: day0)
        let day1Str = fmt.string(from: day0.addingTimeInterval(-86400))
        try expectEqual(lookup["\(day0Str)|success"], 2)
        try expectEqual(lookup["\(day0Str)|error"], 1)
        try expectEqual(lookup["\(day1Str)|interrupted"], 1)
        try expect(rows.allSatisfy { !$0.day.isEmpty && $0.count > 0 })
    }

    t.suite("HistoryGrouping · 四档边界")

    // 固定 now：2026-08-12（周三）12:00 本地 —— 刻意取周中：无论周日首还是周一首，
    // 周起点都严格早于「昨天」，周界断言才确定（周日取 now 时周起点=今天，前一天归昨天）。
    let now = cal.date(
        bySettingHour: 12, minute: 0, second: 0,
        of: base.addingTimeInterval(3 * 86400))!
    let todayStart = cal.startOfDay(for: now)
    func at(_ daysAgo: Int, _ hour: Int) -> Date {
        cal.date(bySettingHour: hour, minute: 0, second: 0,
                 of: todayStart.addingTimeInterval(TimeInterval(-daysAgo * 86400)))!
    }

    t.test("今天：当天 0 点与 23 点都归今天") {
        try expectEqual(HistoryGrouping.group(of: at(0, 0), now: now, calendar: cal), .today)
        try expectEqual(HistoryGrouping.group(of: at(0, 23), now: now, calendar: cal), .today)
    }

    t.test("昨天边界：前一天任意时刻归昨天，前天不归") {
        try expectEqual(HistoryGrouping.group(of: at(1, 0), now: now, calendar: cal), .yesterday)
        try expectEqual(HistoryGrouping.group(of: at(1, 23), now: now, calendar: cal), .yesterday)
        try expect(HistoryGrouping.group(of: at(2, 12), now: now, calendar: cal) != .yesterday)
    }

    t.test("本周更早：周起点及之后（不含昨今）归本周更早，周起点前一天归更早") {
        let weekStart = cal.dateInterval(of: .weekOfYear, for: now)!.start
        // 周起点当天（只要不是今天/昨天）→ 本周更早
        if weekStart < todayStart.addingTimeInterval(-86400) {
            try expectEqual(
                HistoryGrouping.group(of: weekStart, now: now, calendar: cal),
                .earlierThisWeek)
        }
        // 周起点前一秒 → 更早
        try expectEqual(
            HistoryGrouping.group(
                of: weekStart.addingTimeInterval(-1), now: now, calendar: cal),
            .earlier)
    }

    t.test("未来日期宽容归今天（时钟漂移不分出新档）") {
        let future = now.addingTimeInterval(3600)
        try expectEqual(HistoryGrouping.group(of: future, now: now, calendar: cal), .today)
    }

    t.suite("HistoryGrouping · 按会话合并（mergeSessions）")

    func turn(
        _ id: String, source: AgentSource = .claude,
        title: String? = nil,
        started: Date, finished: Date,
        outcome: TaskOutcome = .success, detail: String? = nil
    ) -> FinishedTask {
        FinishedTask(
            source: source, sessionId: id, title: title, cwd: "/w",
            startedAt: started, finishedAt: finished, outcome: outcome, detail: detail)
    }

    t.test("同会话多轮合并为一条：轮数/时长合计/最早开始/最晚结束") {
        let s = now.addingTimeInterval(-3 * 86400)
        let turns = [
            turn("s1", title: "标题", started: s, finished: s.addingTimeInterval(60)),
            turn("s1", title: "标题", started: s.addingTimeInterval(3600),
                 finished: s.addingTimeInterval(3720)),
            turn("s1", title: "标题", started: s.addingTimeInterval(7200),
                 finished: s.addingTimeInterval(7500)),
        ]
        let merged = HistoryGrouping.mergeSessions(turns)
        try expectEqual(merged.count, 1)
        let m = merged[0]
        try expectEqual(m.id, "claude:s1")
        try expectEqual(m.turnCount, 3)
        try expectEqual(m.totalDuration, 60 + 120 + 300)
        try expectEqual(m.sessionStartedAt, s)
        try expectEqual(m.finishedAt, s.addingTimeInterval(7500))
        try expectEqual(m.title, "标题")
        try expectEqual(m.outcome, .success)
        try expect(m.detail == nil)
    }

    t.test("不同 source 的同 sessionId 不合并；返回按最近 finishedAt 倒序") {
        let s = now.addingTimeInterval(-86400)
        let merged = HistoryGrouping.mergeSessions([
            turn("x", source: .codex, started: s, finished: s.addingTimeInterval(60)),
            turn("x", source: .claude, started: s.addingTimeInterval(3600),
                 finished: s.addingTimeInterval(3660)),
        ])
        try expectEqual(merged.count, 2)
        try expectEqual(merged.map(\.source), [.claude, .codex])
    }

    t.test("outcome 取最近一轮；detail 取最近一条非 success 轮") {
        let s = now.addingTimeInterval(-86400)
        let merged = HistoryGrouping.mergeSessions([
            turn("s1", started: s, finished: s.addingTimeInterval(60),
                 outcome: .error, detail: "第一次失败"),
            turn("s1", started: s.addingTimeInterval(3600),
                 finished: s.addingTimeInterval(3660),
                 outcome: .interrupted, detail: "第二次中断"),
            turn("s1", started: s.addingTimeInterval(7200),
                 finished: s.addingTimeInterval(7260)),
        ])
        try expectEqual(merged.count, 1)
        try expectEqual(merged[0].outcome, .success)  // 最近一轮成功
        try expectEqual(merged[0].detail, "第二次中断")  // 最近的非 success 轮
    }

    t.test("title 为 nil 的最近轮回退到其它轮的 title；无 startedAt 的轮不计时长") {
        let s = now.addingTimeInterval(-86400)
        var noStart = FinishedTask(
            source: .claude, sessionId: "s1", title: "有标题",
            finishedAt: s, outcome: .success)
        noStart.startedAt = nil
        let merged = HistoryGrouping.mergeSessions([
            noStart,
            turn("s1", started: s.addingTimeInterval(3600),
                 finished: s.addingTimeInterval(3660)),
        ])
        try expectEqual(merged.count, 1)
        try expectEqual(merged[0].title, "有标题")
        try expectEqual(merged[0].totalDuration, 60)
        // 两轮都无 startedAt 时 totalDuration 为 nil
        var a = FinishedTask(source: .claude, sessionId: "s2",
                             finishedAt: s, outcome: .success)
        a.startedAt = nil
        var b = FinishedTask(source: .claude, sessionId: "s2",
                             finishedAt: s.addingTimeInterval(60), outcome: .success)
        b.startedAt = nil
        try expect(HistoryGrouping.mergeSessions([a, b])[0].totalDuration == nil)
    }
}
