import Foundation
import EurekaKit
import EurekaStore

/// Turn-level view of a range: one asked prompt is one turn. Duration and outcome come from the
/// prompt evaluation, which is more reliable than task history (task rows are reaped after 4h of
/// silence, which inflates both duration and "interrupted").
public struct TurnSummary: Equatable, Sendable {
    public var turns = 0
    public var bySource: [AgentSource: Int] = [:]
    /// Turns that have an evaluation (outcome / rework known)
    public var evaluated = 0
    public var errors = 0
    public var rework = 0
    public var medianDuration: TimeInterval?
    public var p90Duration: TimeInterval?

    public init() {}

    public init(rows: [PromptsRepo.TurnRow]) {
        var durations: [Double] = []
        for row in rows {
            turns += 1
            bySource[row.source, default: 0] += 1
            if let outcome = row.outcome {
                evaluated += 1
                if outcome == "error" { errors += 1 }
                if row.rework == true { rework += 1 }
            }
            if let duration = row.duration, duration >= 0 { durations.append(duration) }
        }
        durations.sort()
        medianDuration = UsageStats.percentile(durations, 0.5)
        p90Duration = UsageStats.percentile(durations, 0.9)
    }

    public var errorRate: Double? { evaluated > 0 ? Double(errors) / Double(evaluated) : nil }
    /// Share of turns whose follow-up was a correction or a struggling rephrase
    public var reworkRate: Double? { evaluated > 0 ? Double(rework) / Double(evaluated) : nil }
}

public enum UsageStats {
    /// Nearest-rank percentile of an ascending array; nil when empty
    public static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return sorted[min(sorted.count - 1, max(0, rank))]
    }

    /// Days that spiked: index → multiple of the baseline, where the baseline is the median of the
    /// up-to-`window` previous non-zero days (idle days would make every busy day look like a
    /// spike). Needs `minHistory` such days before judging.
    public static func spikes(
        _ values: [Double], window: Int = 7, factor: Double = 2, minHistory: Int = 3
    ) -> [Int: Double] {
        var result: [Int: Double] = [:]
        for index in values.indices where values[index] > 0 {
            let history = values[..<index].filter { $0 > 0 }.suffix(window).sorted()
            guard history.count >= minHistory,
                  let baseline = percentile(Array(history), 0.5), baseline > 0
            else { continue }
            let multiple = values[index] / baseline
            if multiple >= factor { result[index] = multiple }
        }
        return result
    }

    /// Share of `total` held by the `top` largest values; nil without a total
    public static func topShare(_ values: [Double], top: Int, total: Double) -> Double? {
        guard total > 0 else { return nil }
        return values.sorted(by: >).prefix(top).reduce(0, +) / total
    }
}
