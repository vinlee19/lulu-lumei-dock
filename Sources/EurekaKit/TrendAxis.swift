import Foundation

/// X-axis layout for the usage trend chart ("by date"). Pure, no IO.
/// The "all" period starts at 1970; used as-is for the axis domain, the chart would span
/// 56 years with thousands of ticks and turn into a smear. This clamps the domain to the
/// first day that has data and picks a tick stride that fits the span (same approach as
/// Claude Code Desktop's All view).
public enum TrendAxis {
    public struct Layout: Equatable, Sendable {
        /// Axis domain: `[max(range start, midnight of the first data day), range end]`
        public var domain: ClosedRange<Date>
        /// Tick stride in days for day granularity; unused for hourly
        public var strideDays: Int
        /// Spans over a year need the year in the labels, otherwise "3/17" is ambiguous
        public var showsYear: Bool
    }

    /// Stride candidates in days: the smallest one that keeps ticks within `maxLabels`
    static let steps = [1, 2, 5, 7, 14, 30, 60, 90, 180, 365]
    static let maxLabels = 8

    public static func layout(
        rangeFrom: Date, rangeTo: Date, firstBucket: Date?,
        calendar: Calendar = .current
    ) -> Layout {
        var lower = rangeFrom
        if let firstBucket {
            lower = max(rangeFrom, calendar.startOfDay(for: firstBucket))
        }
        // Guard: data later than the range end (clock skew / future timestamps) must not invert the domain
        let upper = max(rangeTo, lower)
        let days = max(1, Int((upper.timeIntervalSince(lower) / 86400).rounded(.up)))
        let step = steps.first { days / $0 <= maxLabels } ?? steps[steps.count - 1]
        return Layout(domain: lower...upper, strideDays: step, showsYear: days > 365)
    }
}
