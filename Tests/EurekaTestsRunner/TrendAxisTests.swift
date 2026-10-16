import EurekaKit
import Foundation

func trendAxisTests(_ t: TestRunner) {
    t.suite("TrendAxis · 趋势图横轴")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21
    let epoch = Date(timeIntervalSince1970: 0)

    t.test("全部（起点=1970）→ 轴域收拢到首个数据日，而不是铺 56 年") {
        let first = now.addingTimeInterval(-220 * 86400)
        let layout = TrendAxis.layout(
            rangeFrom: epoch, rangeTo: now, firstBucket: first, calendar: calendar)
        try expectEqual(layout.domain.lowerBound, calendar.startOfDay(for: first))
        try expectEqual(layout.domain.upperBound, now)
        try expect(220 / layout.strideDays <= 8, "刻度应 ≤8 个，步长 \(layout.strideDays)")
    }

    t.test("固定区间起点晚于首个数据日 → 仍用区间起点（不扩张）") {
        let from = now.addingTimeInterval(-7 * 86400)
        let layout = TrendAxis.layout(
            rangeFrom: from, rangeTo: now,
            firstBucket: now.addingTimeInterval(-300 * 86400), calendar: calendar)
        try expectEqual(layout.domain.lowerBound, from)
        try expectEqual(layout.strideDays, 1)
    }

    t.test("无数据 → 用区间起点，不崩") {
        let from = now.addingTimeInterval(-30 * 86400)
        let layout = TrendAxis.layout(
            rangeFrom: from, rangeTo: now, firstBucket: nil, calendar: calendar)
        try expectEqual(layout.domain.lowerBound, from)
        try expectEqual(layout.strideDays, 5)
    }

    t.test("首个数据晚于区间终点 → 域不倒置") {
        let layout = TrendAxis.layout(
            rangeFrom: epoch, rangeTo: now,
            firstBucket: now.addingTimeInterval(86400), calendar: calendar)
        try expect(layout.domain.lowerBound <= layout.domain.upperBound)
    }

    t.test("跨度 >1 年 → 带年份；≤1 年不带") {
        let long = TrendAxis.layout(
            rangeFrom: epoch, rangeTo: now,
            firstBucket: now.addingTimeInterval(-800 * 86400), calendar: calendar)
        try expect(long.showsYear)
        let short = TrendAxis.layout(
            rangeFrom: epoch, rangeTo: now,
            firstBucket: now.addingTimeInterval(-200 * 86400), calendar: calendar)
        try expect(!short.showsYear)
    }

    t.test("超长跨度（十年）→ 步长封顶 365") {
        let layout = TrendAxis.layout(
            rangeFrom: epoch, rangeTo: now,
            firstBucket: now.addingTimeInterval(-3650 * 86400), calendar: calendar)
        try expectEqual(layout.strideDays, 365)
    }
}
