import EurekaKit
import Foundation

func usageDateRangeTests(_ t: TestRunner) {
    t.suite("UsageDateRange · 自定义日期区间")

    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }
    // Thursday 2026-10-29 14:30
    let now = day(2026, 10, 29, 14, 30)

    t.test("任意两天：按自然日取整、自动排序，结束日不越过今天") {
        let range = UsageDateRange(day(2026, 11, 5, 9), day(2026, 10, 20, 18), now: now, calendar: calendar)
        try expectEqual(range.firstDay, day(2026, 10, 20))
        try expectEqual(range.lastDay, day(2026, 10, 29), "未来的结束日收回到今天")
        try expectEqual(range.dayCount(calendar: calendar), 10)
    }

    t.test("查询区间：过去的区间到末日次日 0 点为止，包含今天的截到此刻") {
        let past = UsageDateRange(day(2026, 10, 1), day(2026, 10, 7), now: now, calendar: calendar)
        let pastInterval = past.interval(now: now, calendar: calendar)
        try expectEqual(pastInterval.from, day(2026, 10, 1))
        try expectEqual(pastInterval.to, day(2026, 10, 8), "末日整天都算，不丢最后一秒")

        let current = UsageDateRange(day(2026, 10, 23), now, now: now, calendar: calendar)
        try expectEqual(current.interval(now: now, calendar: calendar).to, now,
                        "截到此刻：环比才比得是同样长的已过时间")
    }

    t.test("快捷区间：近 N 天含今天，上周按周一起算，上月取整月，今年从 1 月 1 日") {
        func preset(_ p: UsageDateRange.Preset) -> (Date, Date) {
            let r = UsageDateRange.preset(p, now: now, calendar: calendar)
            return (r.firstDay, r.lastDay)
        }
        try expect(preset(.yesterday) == (day(2026, 10, 28), day(2026, 10, 28)))
        try expect(preset(.last7Days) == (day(2026, 10, 23), day(2026, 10, 29)))
        try expect(preset(.last30Days) == (day(2026, 9, 30), day(2026, 10, 29)))
        try expect(preset(.last90Days) == (day(2026, 8, 1), day(2026, 10, 29)))
        try expect(preset(.lastWeek) == (day(2026, 10, 19), day(2026, 10, 25)), "\(preset(.lastWeek))")
        try expect(preset(.lastMonth) == (day(2026, 9, 1), day(2026, 9, 30)))
        try expect(preset(.thisYear) == (day(2026, 1, 1), day(2026, 10, 29)))
    }

    t.test("上月跨年、上周在周一当天也取完整上一周") {
        let january = day(2026, 1, 15, 9)
        let lastMonth = UsageDateRange.preset(.lastMonth, now: january, calendar: calendar)
        try expectEqual(lastMonth.firstDay, day(2025, 12, 1))
        try expectEqual(lastMonth.lastDay, day(2025, 12, 31))

        let monday = day(2026, 10, 26, 8)
        let lastWeek = UsageDateRange.preset(.lastWeek, now: monday, calendar: calendar)
        try expectEqual(lastWeek.firstDay, day(2026, 10, 19))
        try expectEqual(lastWeek.lastDay, day(2026, 10, 25))
    }

    t.test("选择的持久化：快捷区间随日期滚动，手选日期原样还原，坏数据回落到默认") {
        let rolling = UsageRangeSelection.preset(.last7Days)
        let restored = try expectSome(UsageRangeSelection(storageValue: rolling.storageValue()))
        let tomorrow = now.addingTimeInterval(86_400)
        try expectEqual(
            restored.resolve(now: tomorrow, calendar: calendar).lastDay, day(2026, 10, 30),
            "近 7 天第二天打开要跟着往后滚")

        let fixed = UsageRangeSelection.days(
            UsageDateRange(day(2026, 10, 1), day(2026, 10, 7), now: now, calendar: calendar))
        let reloaded = try expectSome(
            UsageRangeSelection(storageValue: fixed.storageValue(calendar: calendar), calendar: calendar))
        try expectEqual(reloaded.resolve(now: tomorrow, calendar: calendar).firstDay, day(2026, 10, 1))
        try expectEqual(reloaded.resolve(now: tomorrow, calendar: calendar).lastDay, day(2026, 10, 7))

        try expect(UsageRangeSelection(storageValue: "") == nil)
        try expect(UsageRangeSelection(storageValue: "days:not-a-date..2026-10-07") == nil)
        try expect(UsageRangeSelection(storageValue: "preset:unknown") == nil)
    }
}
