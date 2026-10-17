import Foundation

/// Rate-limit exhaustion forecast: linear extrapolation over recent usage-percentage samples to
/// estimate when the window fills. Pure function, no IO; sample persistence and alert throttling
/// belong to the caller.
public enum LimitForecaster {
    public struct Point: Equatable, Sendable {
        public var ts: Date
        public var percent: Double

        public init(ts: Date, percent: Double) {
            self.ts = ts
            self.percent = percent
        }
    }

    /// Alert eligibility floor: no forecast while current usage is below this (low values are noisy
    /// and not actionable)
    public static let minPercent: Double = 50
    /// Only forecast "will fill within this horizon" (anything further out isn't actionable)
    public static let horizon: TimeInterval = 90 * 60
    /// Minimum sample count and time span for the fit (too little data makes the slope
    /// untrustworthy)
    static let minPoints = 3
    static let minSpan: TimeInterval = 10 * 60

    /// Linearly extrapolate the fill time. Returns nil when not eligible (too few samples /
    /// non-positive slope / current < minPercent / fill time beyond the horizon). A window reset
    /// (percentage drops) automatically fits only the tail after the drop.
    public static func forecastFullAt(
        points: [Point], now: Date,
        minPercent: Double = LimitForecaster.minPercent,
        horizon: TimeInterval = LimitForecaster.horizon
    ) -> Date? {
        let sorted = points.sorted { $0.ts < $1.ts }
        // keep only the tail after the last significant drop (window reset)
        var tail: [Point] = []
        for point in sorted {
            if let last = tail.last, point.percent < last.percent - 1 {
                tail = [point]
            } else {
                tail.append(point)
            }
        }
        guard tail.count >= minPoints,
              let first = tail.first, let last = tail.last,
              last.ts.timeIntervalSince(first.ts) >= minSpan,
              last.percent >= minPercent, last.percent < 100
        else { return nil }

        // least-squares linear fit percent = a + b·t (t in relative seconds for numerical
        // stability)
        let t0 = first.ts.timeIntervalSince1970
        let xs = tail.map { $0.ts.timeIntervalSince1970 - t0 }
        let ys = tail.map(\.percent)
        let n = Double(tail.count)
        let sumX = xs.reduce(0, +)
        let sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denominator = n * sumXX - sumX * sumX
        guard denominator > 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denominator
        // slope floor: below 0.01% per minute counts as flat; no forecast
        guard slope > 0.01 / 60 else { return nil }
        let intercept = (sumY - slope * sumX) / n

        let tFull = (100 - intercept) / slope
        let eta = Date(timeIntervalSince1970: t0 + tFull)
        guard eta > now, eta.timeIntervalSince(now) <= horizon else { return nil }
        return eta
    }
}
