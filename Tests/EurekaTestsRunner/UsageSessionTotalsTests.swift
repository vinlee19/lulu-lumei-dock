import EurekaKit
import EurekaStore
import Foundation

func usageSessionTotalsTests(_ t: TestRunner) {
    t.suite("UsageRepo · 会话聚合/热力图/趋势粒度")

    func makeStore() throws -> (EurekaStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-sess-totals-\(UUID()).sqlite")
        return (try EurekaStore(path: path), path)
    }

    func makeRecord(
        source: AgentSource = .claude, model: String = "m1", project: String? = "proj",
        sessionId: String?, ts: Double, input: Int = 10, output: Int = 5
    ) -> UsageRecord {
        UsageRecord(
            source: source, model: model, project: project, sessionId: sessionId,
            timestamp: Date(timeIntervalSince1970: ts),
            inputTokens: input, outputTokens: output,
            cacheCreationTokens: 2, cacheCreation1hTokens: 1, cacheReadTokens: 100)
    }

    t.test("totalsBySession：分组求和、MAX(ts)、NULL/空串排除、时间窗与来源过滤") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.usage.insert([
            // 会话 A：同会话双模型、双记录
            makeRecord(model: "m1", sessionId: "sess-a", ts: 100),
            makeRecord(model: "m1", sessionId: "sess-a", ts: 200),
            makeRecord(model: "m2", sessionId: "sess-a", ts: 300),
            // 会话 B：codex
            makeRecord(source: .codex, model: "g1", sessionId: "sess-b", ts: 150),
            // 无会话 id 的记录应排除
            makeRecord(sessionId: nil, ts: 120),
            makeRecord(sessionId: "", ts: 130),
            // 时间窗外
            makeRecord(sessionId: "sess-old", ts: 10),
        ])

        let rows = try store.usage.totalsBySession(
            from: Date(timeIntervalSince1970: 50), to: Date(timeIntervalSince1970: 1000))
        // sess-a 两个 model 组 + sess-b 一组
        try expectEqual(rows.count, 3)
        let sessA = rows.filter { $0.sessionId == "sess-a" }
        try expectEqual(sessA.count, 2)
        let m1 = sessA.first { $0.totals.model == "m1" }!
        try expectEqual(m1.totals.inputTokens, 20)   // 两条求和
        try expectEqual(m1.totals.requestCount, 2)
        try expectEqual(m1.lastTs, Date(timeIntervalSince1970: 200))  // 组内 MAX(ts)
        try expectEqual(m1.project, "proj")
        try expect(!rows.contains { $0.sessionId == "sess-old" }, "时间窗外应排除")

        // 来源过滤
        let codexOnly = try store.usage.totalsBySession(
            from: Date(timeIntervalSince1970: 50), to: Date(timeIntervalSince1970: 1000),
            source: .codex)
        try expectEqual(codexOnly.map(\.sessionId), ["sess-b"])
    }

    t.test("hourlyHeatmap：落格正确（Calendar 反推期望，避免时区耦合）、同格合并、来源过滤") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        // 两条同格 + 一条隔小时 + 一条 codex
        let base = Date(timeIntervalSince1970: 1_782_900_000)
        let sameCell = base.addingTimeInterval(60)          // 同一小时内
        let nextHour = base.addingTimeInterval(3600)
        try store.usage.insert([
            makeRecord(sessionId: "s", ts: base.timeIntervalSince1970, input: 10, output: 5),
            makeRecord(sessionId: "s", ts: sameCell.timeIntervalSince1970, input: 20, output: 5),
            makeRecord(sessionId: "s", ts: nextHour.timeIntervalSince1970),
            makeRecord(source: .codex, sessionId: "s", ts: base.timeIntervalSince1970),
        ])

        // 期望格坐标用本机 Calendar 反推（SQLite %w：0=周日 == Calendar.weekday-1）
        let calendar = Calendar.current
        let comps = calendar.dateComponents([.weekday, .hour], from: base)
        let expectedWeekday = comps.weekday! - 1
        let expectedHour = comps.hour!

        let cells = try store.usage.hourlyHeatmap(
            from: base.addingTimeInterval(-100), to: base.addingTimeInterval(7200))
        let baseCell = cells.first { $0.weekday == expectedWeekday && $0.hour == expectedHour }
        try expect(baseCell != nil, "base 所在格应存在")
        try expectEqual(baseCell!.requests, 3)  // 同格两条 claude + 一条 codex
        // tokens = input+output+cacheCreation(2)+cacheRead(100)
        try expectEqual(baseCell!.tokens, (10 + 5 + 102) + (20 + 5 + 102) + (10 + 5 + 102))

        let codexCells = try store.usage.hourlyHeatmap(
            from: base.addingTimeInterval(-100), to: base.addingTimeInterval(7200),
            source: .codex)
        try expectEqual(codexCells.count, 1)
        try expectEqual(codexCells[0].requests, 1)
    }

    t.test("dailyRows 粒度：hour 分桶格式与 day 总量对账") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let base = Date(timeIntervalSince1970: 1_782_900_000)
        try store.usage.insert([
            makeRecord(sessionId: "s", ts: base.timeIntervalSince1970, input: 10),
            makeRecord(sessionId: "s", ts: base.addingTimeInterval(3700).timeIntervalSince1970,
                       input: 30),
        ])
        let from = base.addingTimeInterval(-100)
        let to = base.addingTimeInterval(7200)

        let hourly = try store.usage.dailyRows(from: from, to: to, granularity: .hour)
        try expectEqual(hourly.count, 2, "跨小时应分两桶")
        // 桶格式 yyyy-MM-dd HH:00
        for row in hourly {
            try expect(row.day.count == 16 && row.day.hasSuffix(":00"),
                       "hour 桶格式应为 yyyy-MM-dd HH:00，实际 \(row.day)")
        }
        let daily = try store.usage.dailyRows(from: from, to: to)  // 默认 .day
        let hourSum = hourly.map(\.totals.inputTokens).reduce(0, +)
        let daySum = daily.map(\.totals.inputTokens).reduce(0, +)
        try expectEqual(hourSum, daySum, "两种粒度总量应一致")
        try expectEqual(hourSum, 40)
    }
}
