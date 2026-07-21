import EurekaKit
import EurekaStore
import Foundation

func limitForecasterTests(_ t: TestRunner) {
    t.suite("LimitForecaster · 限额打满预测")

    let base = Date(timeIntervalSince1970: 1_784_600_000)

    /// 每 5 分钟一个采样点
    func points(_ percents: [Double]) -> [LimitForecaster.Point] {
        percents.enumerated().map { index, percent in
            LimitForecaster.Point(
                ts: base.addingTimeInterval(Double(index) * 300), percent: percent)
        }
    }

    t.test("匀速上升 → 线性外推 ETA 正确") {
        // 每 5 分钟 +5%：60% → 70%，斜率 1%/min，从 70% 到 100% 还要 30 分钟
        let series = points([60, 65, 70])
        let now = base.addingTimeInterval(600)
        let eta = LimitForecaster.forecastFullAt(points: series, now: now)
        try expect(eta != nil, "应给出预测")
        let minutes = eta!.timeIntervalSince(now) / 60
        try expect(abs(minutes - 30) < 1, "ETA 应 ≈30 分钟后，实际 \(minutes)")
    }

    t.test("平稳（斜率≈0）→ 不预测") {
        let series = points([70, 70, 70, 70])
        try expect(LimitForecaster.forecastFullAt(
            points: series, now: base.addingTimeInterval(900)) == nil)
    }

    t.test("当前用量 < 50% → 不预测") {
        let series = points([10, 20, 30])
        try expect(LimitForecaster.forecastFullAt(
            points: series, now: base.addingTimeInterval(600)) == nil)
    }

    t.test("ETA 超出 90 分钟视距 → 不预测") {
        // 每 5 分钟 +0.5%：到 100% 需要约 5 小时
        let series = points([84, 84.5, 85])
        try expect(LimitForecaster.forecastFullAt(
            points: series, now: base.addingTimeInterval(600)) == nil)
    }

    t.test("窗口重置回落 → 只用回落后的尾段拟合") {
        // 前段冲到 90%，重置回落到 10% 后缓慢爬升 → 尾段不满足资格，不预测
        let series = points([80, 85, 90, 10, 12, 14])
        try expect(LimitForecaster.forecastFullAt(
            points: series, now: base.addingTimeInterval(1500)) == nil,
            "重置后低位爬升不应沿用重置前的高位样本")
    }

    t.test("样本不足 / 跨度不足 → 不预测") {
        try expect(LimitForecaster.forecastFullAt(
            points: points([60, 70]), now: base.addingTimeInterval(300)) == nil,
            "两个点不预测")
        let dense = [
            LimitForecaster.Point(ts: base, percent: 60),
            LimitForecaster.Point(ts: base.addingTimeInterval(60), percent: 62),
            LimitForecaster.Point(ts: base.addingTimeInterval(120), percent: 64),
        ]
        try expect(LimitForecaster.forecastFullAt(
            points: dense, now: base.addingTimeInterval(120)) == nil,
            "跨度 <10 分钟不预测")
    }

    t.test("LimitSamplesRepo 落样 / 查询 / 清理") {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-limits-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        try store.limitSamples.insert(source: "codex", window: "primary", percent: 60, ts: base)
        try store.limitSamples.insert(
            source: "codex", window: "primary", percent: 65, ts: base.addingTimeInterval(300))
        try store.limitSamples.insert(
            source: "grok", window: "primary", percent: 10, ts: base.addingTimeInterval(300))

        let rows = try store.limitSamples.samples(
            source: "codex", window: "primary", since: base.addingTimeInterval(-1))
        try expectEqual(rows.count, 2)
        try expectEqual(rows[0].percent, 60)
        try expectEqual(rows[1].percent, 65)

        try store.limitSamples.prune(before: base.addingTimeInterval(100))
        let pruned = try store.limitSamples.samples(
            source: "codex", window: "primary", since: base.addingTimeInterval(-1))
        try expectEqual(pruned.count, 1, "早于界限的样本应被清理")
    }
}
