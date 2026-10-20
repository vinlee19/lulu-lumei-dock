import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func turnStatsTests(_ t: TestRunner) {
    t.suite("TurnSummary")

    typealias Row = PromptsRepo.TurnRow

    t.test("轮次、出错率、返工率只按已评价的轮次算") {
        let summary = TurnSummary(rows: [
            Row(source: .claude, duration: 30, outcome: "clean", rework: false),
            Row(source: .claude, duration: 60, outcome: "error", rework: true),
            Row(source: .codex, duration: nil, outcome: "clean", rework: true),
            Row(source: .codex, duration: nil, outcome: nil, rework: nil),
        ])
        try expectEqual(summary.turns, 4)
        try expectEqual(summary.bySource, [.claude: 2, .codex: 2])
        try expectEqual(summary.evaluated, 3)
        try expectEqual(summary.errorRate, 1.0 / 3)
        try expectEqual(summary.reworkRate, 2.0 / 3)
    }

    t.test("耗时取中位数与 P90，不受极端值拖偏") {
        let durations: [Double] = [10, 20, 30, 40, 50, 60, 70, 80, 90, 266_000]
        let summary = TurnSummary(rows: durations.map {
            Row(source: .claude, duration: $0, outcome: "clean", rework: false)
        })
        try expectEqual(summary.medianDuration, 50)
        try expectEqual(summary.p90Duration, 90)
    }

    t.test("空范围：比率为 nil") {
        let summary = TurnSummary(rows: [])
        try expect(summary.errorRate == nil && summary.medianDuration == nil)
    }

    t.suite("UsageStats")

    t.test("尖峰：超过前 7 个非零日中位数 2 倍才算，空闲日不参与基线") {
        let values: [Double] = [10, 0, 12, 0, 11, 30, 0, 9, 50]
        let spikes = UsageStats.spikes(values)
        // index 5: baseline median(10,12,11)=11 → 2.7×; index 8: median(10,12,11,30,9)=11 → 4.5×
        try expectEqual(Set(spikes.keys), [5, 8])
        try expect(abs((spikes[5] ?? 0) - 30.0 / 11) < 1e-9)
    }

    t.test("尖峰：历史不足 3 天不判断") {
        try expectEqual(UsageStats.spikes([1, 100, 1000]), [:])
    }

    t.test("集中度：前 N 项占比") {
        try expectEqual(UsageStats.topShare([5, 30, 10, 55], top: 2, total: 100), 0.85)
        try expect(UsageStats.topShare([1], top: 1, total: 0) == nil)
    }

    t.test("真实库：turnRows 遵循与周报相同的过滤规则") {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-turns-\(UUID().uuidString)/test.sqlite")
        let store = try EurekaStore(path: url)
        let now = Date()
        try store.prompts.upsertExtracted([
            PromptEntry(id: "a", source: .claude, sessionId: "s", messageIdx: 0,
                        text: "fix the bug", timestamp: now, cwd: nil, firstSeen: now),
            PromptEntry(id: "b", source: .claude, sessionId: "s", messageIdx: 1,
                        text: "/clear", timestamp: now, cwd: nil, firstSeen: now),
            PromptEntry(id: "c", source: .codex, sessionId: "t", messageIdx: 0,
                        text: "<injected>", timestamp: now, cwd: nil, firstSeen: now),
        ], at: now)
        let rows = try store.prompts.turnRows(
            from: now.addingTimeInterval(-60), to: now.addingTimeInterval(60))
        try expectEqual(rows.map(\.source), [.claude])
        try expect(rows[0].outcome == nil && rows[0].rework == nil)
    }
}
