import Foundation

/// A run of whole local calendar days for the usage dashboard's custom period. Pure, no IO.
public struct UsageDateRange: Equatable, Sendable {
    /// Midnight of the first and of the last day; both days are included
    public let firstDay: Date
    public let lastDay: Date

    /// Takes two dates in either order, snaps them to midnight and keeps the last day from
    /// running past today (there is no usage there yet).
    public init(_ a: Date, _ b: Date, now: Date = Date(), calendar: Calendar = .current) {
        let today = calendar.startOfDay(for: now)
        let lo = min(calendar.startOfDay(for: min(a, b)), today)
        let hi = min(calendar.startOfDay(for: max(a, b)), today)
        firstDay = lo
        lastDay = hi
    }

    public func dayCount(calendar: Calendar = .current) -> Int {
        (calendar.dateComponents([.day], from: firstDay, to: lastDay).day ?? 0) + 1
    }

    /// The query interval `[from, to)`: from the first midnight to the midnight after the last
    /// day, cut at `now` when the range reaches today. Cutting there matters for the
    /// period-over-period delta, which compares the same elapsed time just before `from`.
    public func interval(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? lastDay
        return (firstDay, min(end, max(now, firstDay)))
    }

    /// One-click ranges the dashboard's own periods (today / this week / this month) don't cover
    public enum Preset: String, CaseIterable, Sendable {
        case yesterday, last7Days, last30Days, last90Days, lastWeek, lastMonth, thisYear
    }

    public static func preset(
        _ preset: Preset, now: Date = Date(), calendar: Calendar = .current
    ) -> UsageDateRange {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ n: Int) -> Date { calendar.date(byAdding: .day, value: -n, to: today) ?? today }
        switch preset {
        case .yesterday:
            return UsageDateRange(daysAgo(1), daysAgo(1), now: now, calendar: calendar)
        case .last7Days:
            return UsageDateRange(daysAgo(6), today, now: now, calendar: calendar)
        case .last30Days:
            return UsageDateRange(daysAgo(29), today, now: now, calendar: calendar)
        case .last90Days:
            return UsageDateRange(daysAgo(89), today, now: now, calendar: calendar)
        case .lastWeek:
            // Weeks start on Monday app-wide (UsageAggregator.weekStart, the "This week" period)
            var monday = calendar
            monday.firstWeekday = 2
            let thisWeek = monday.dateInterval(of: .weekOfYear, for: today)?.start ?? today
            let start = monday.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek
            let end = monday.date(byAdding: .day, value: -1, to: thisWeek) ?? thisWeek
            return UsageDateRange(start, end, now: now, calendar: calendar)
        case .lastMonth:
            let thisMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
            let start = calendar.date(byAdding: .month, value: -1, to: thisMonth) ?? thisMonth
            let end = calendar.date(byAdding: .day, value: -1, to: thisMonth) ?? thisMonth
            return UsageDateRange(start, end, now: now, calendar: calendar)
        case .thisYear:
            let start = calendar.dateInterval(of: .year, for: today)?.start ?? today
            return UsageDateRange(start, today, now: now, calendar: calendar)
        }
    }
}

/// What the user picked for the custom period. A preset stays a preset, so "Last 7 days" still
/// means the last 7 days when the dashboard is opened tomorrow; hand-picked days stay fixed.
public enum UsageRangeSelection: Equatable, Sendable {
    case preset(UsageDateRange.Preset)
    case days(UsageDateRange)

    public static let `default` = UsageRangeSelection.preset(.last7Days)

    public func resolve(now: Date = Date(), calendar: Calendar = .current) -> UsageDateRange {
        switch self {
        case .preset(let preset): return UsageDateRange.preset(preset, now: now, calendar: calendar)
        case .days(let range): return UsageDateRange(range.firstDay, range.lastDay, now: now, calendar: calendar)
        }
    }

    /// `preset:<name>` or `days:yyyy-MM-dd..yyyy-MM-dd` (local calendar days, so a time zone
    /// change keeps the same days). `calendar` must be the one the range was built in.
    public func storageValue(calendar: Calendar = .current) -> String {
        switch self {
        case .preset(let preset):
            return "preset:\(preset.rawValue)"
        case .days(let range):
            let formatter = Self.dayFormatter(calendar)
            return "days:\(formatter.string(from: range.firstDay))..\(formatter.string(from: range.lastDay))"
        }
    }

    public init?(storageValue: String, calendar: Calendar = .current) {
        if storageValue.hasPrefix("preset:") {
            guard let preset = UsageDateRange.Preset(rawValue: String(storageValue.dropFirst(7)))
            else { return nil }
            self = .preset(preset)
        } else if storageValue.hasPrefix("days:") {
            let bounds = storageValue.dropFirst(5).components(separatedBy: "..")
            let formatter = Self.dayFormatter(calendar)
            guard bounds.count == 2,
                  let first = formatter.date(from: bounds[0]),
                  let last = formatter.date(from: bounds[1])
            else { return nil }
            self = .days(UsageDateRange(first, last, calendar: calendar))
        } else {
            return nil
        }
    }

    private static func dayFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
