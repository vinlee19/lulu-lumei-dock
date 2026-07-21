import Foundation

/// 限额打满预测：对最近的用量百分比采样做线性外推，估算窗口打满时刻。
/// 纯函数、无 IO——采样持久化与告警节流由调用层负责。
public enum LimitForecaster {
    public struct Point: Equatable, Sendable {
        public var ts: Date
        public var percent: Double

        public init(ts: Date, percent: Double) {
            self.ts = ts
            self.percent = percent
        }
    }

    /// 告警资格线：当前用量低于此值不预测（低位噪声大、且没有行动价值）
    public static let minPercent: Double = 50
    /// 只对"这个视距内会打满"发出预测（太远没有行动价值）
    public static let horizon: TimeInterval = 90 * 60
    /// 拟合样本最少数量与最短时间跨度（数据太少斜率不可信）
    static let minPoints = 3
    static let minSpan: TimeInterval = 10 * 60

    /// 线性外推打满时刻。不满足资格（样本不足 / 斜率非正 / 当前 < minPercent /
    /// 打满时刻超出视距）返回 nil。窗口重置（百分比回落）自动只取回落后的尾段拟合。
    public static func forecastFullAt(
        points: [Point], now: Date,
        minPercent: Double = LimitForecaster.minPercent,
        horizon: TimeInterval = LimitForecaster.horizon
    ) -> Date? {
        let sorted = points.sorted { $0.ts < $1.ts }
        // 截取最后一次明显回落（窗口重置）之后的尾段
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

        // 最小二乘线性拟合 percent = a + b·t（t 取相对秒，数值稳定）
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
        // 斜率下限：每分钟 0.01% 以下视为平稳，不预测
        guard slope > 0.01 / 60 else { return nil }
        let intercept = (sumY - slope * sumX) / n

        let tFull = (100 - intercept) / slope
        let eta = Date(timeIntervalSince1970: t0 + tFull)
        guard eta > now, eta.timeIntervalSince(now) <= horizon else { return nil }
        return eta
    }
}
