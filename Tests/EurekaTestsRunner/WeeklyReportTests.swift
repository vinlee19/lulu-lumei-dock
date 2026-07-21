import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func weeklyReportTests(_ t: TestRunner) {
    t.suite("WeeklyReportBuilder · vibe coding 周报")

    // 固定一周：从某个周一的本地零点开始
    let calendar = Calendar.current
    let weekStart = calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 13))!  // 2026-07-13 是周一
    let weekEnd = calendar.date(byAdding: .day, value: 7, to: weekStart)!

    func makeStore() throws -> (EurekaStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-weekly-\(UUID()).sqlite")
        return (try EurekaStore(path: path), path)
    }

    func record(
        _ dayOffset: Int, hour: Int, model: String = "claude-sonnet-5",
        source: AgentSource = .claude, project: String? = "proj-a",
        session: String? = "s1", input: Int = 1000, output: Int = 500
    ) -> UsageRecord {
        let ts = calendar.date(
            byAdding: DateComponents(day: dayOffset, hour: hour), to: weekStart)!
        return UsageRecord(
            source: source, model: model, project: project, sessionId: session,
            timestamp: ts, inputTokens: input, outputTokens: output,
            cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0)
    }

    let pricing = PricingTable(models: [
        .init(match: "claude-sonnet-5", inputPerM: 3, outputPerM: 15),
    ])

    t.test("总量 / 活跃小时 / 深夜天数 / 按源按项目聚合") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.usage.insert([
            record(0, hour: 10),                              // 周一 10 点
            record(0, hour: 10, input: 2000, output: 1000),   // 同小时 → 桶去重
            record(1, hour: 23, project: "proj-b", session: "s2"),  // 周二深夜
            record(2, hour: 15, model: "gpt-5.2", source: .codex, session: "s3"),
            record(9, hour: 10),                              // 下周 → 不计
        ])
        try store.history.insert(FinishedTask(
            source: .claude, sessionId: "s1", title: "t", cwd: nil,
            startedAt: nil, sessionStartedAt: nil,
            finishedAt: weekStart.addingTimeInterval(3600), outcome: .success, detail: nil))
        try store.history.insert(FinishedTask(
            source: .claude, sessionId: "s2", title: "t", cwd: nil,
            startedAt: nil, sessionStartedAt: nil,
            finishedAt: weekStart.addingTimeInterval(7200), outcome: .error, detail: nil))
        try store.toolCalls.bump(
            day: "2026-07-14", source: .claude, kind: "skill", name: "tdd", by: 3)
        try store.toolCalls.bump(
            day: "2026-07-14", source: .claude, kind: "mcp", name: "context7", by: 9)

        let report = try WeeklyReportBuilder.build(
            store: store, pricing: pricing, weekStart: weekStart, weekEnd: weekEnd)

        try expectEqual(report.requestCount, 4, "下周记录不应计入")
        try expectEqual(report.activeHours, 3, "同小时多请求只算一个桶")
        try expectEqual(report.lateNightDays, 1)
        try expectEqual(report.totalTokens, 1500 + 3000 + 1500 + 1500)
        try expectEqual(report.bySource.count, 2)
        try expectEqual(report.byProject.first?.name, "proj-a")
        try expectEqual(report.successCount, 1)
        try expectEqual(report.errorCount, 1)
        try expectEqual(report.topSkills.count, 1, "只统计 kind=skill")
        try expectEqual(report.topSkills.first?.name, "tdd")
        // claude 有价格表 → 有成本；codex 模型无价格 → 不计入
        try expect(report.totalCostUSD != nil)
        try expectEqual(report.topSessions.first?.sessionId, "s1", "s1 消耗最大")
        try expect(!report.isEmpty)
    }

    t.test("空周 → isEmpty") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        let report = try WeeklyReportBuilder.build(
            store: store, pricing: pricing, weekStart: weekStart, weekEnd: weekEnd)
        try expect(report.isEmpty)
    }

    t.test("导出 Markdown 含关键段落") {
        let (store, path) = try makeStore()
        defer { try? FileManager.default.removeItem(at: path) }
        try store.usage.insert([record(0, hour: 10)])
        let report = try WeeklyReportBuilder.build(
            store: store, pricing: pricing, weekStart: weekStart, weekEnd: weekEnd)
        let md = WeeklyReportBuilder.markdown(report, sessionNames: ["s1": "重构管道"])
        try expect(md.contains("# vibe coding 周报"))
        try expect(md.contains("活跃时长：约 1 小时"))
        try expect(md.contains("## 按来源"))
        try expect(md.contains("## 最贵会话"))
        try expect(md.contains("重构管道"), "应使用注入的会话名")
    }
}
