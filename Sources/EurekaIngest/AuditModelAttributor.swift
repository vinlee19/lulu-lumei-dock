import EurekaKit
import EurekaStore
import Foundation

/// Fills in which model issued each audited operation.
///
/// An audit row arrives without a model: Claude's hook payload has none, and the scanners read
/// tool lines, not usage lines. The usage ledger knows every model call of a session with its
/// time, so the model is looked up there afterwards: the call just before the operation (the
/// message that asked for it), else one just after. On a real log this places 97% of operations,
/// 90% within ten seconds.
///
/// A known limit: Claude's parallel subagents share the parent's session id, so when a subagent
/// runs another model some operations land on whichever model spoke last.
public enum AuditModelAttributor {
    /// How far back the issuing call may be (a long-running tool reports late)
    public static let lookBack: TimeInterval = 600
    /// Usage rows are stamped a moment after the hook fires for some sources
    public static let lookAhead: TimeInterval = 60
    /// The usage scan runs every minute; give it time to record the call first
    public static let settleDelay: TimeInterval = 120
    /// After this long an unmatched operation is marked unknown and not looked at again
    public static let giveUpAfter: TimeInterval = 86_400
    public static let batchSize = 5_000

    /// The model in force at `ts`, from a session's calls in time order
    public static func model(at ts: Double, in timeline: [(ts: Double, model: String)]) -> String? {
        // First call later than ts + 5 s (a hook can land a little before its usage row)
        var low = 0
        var high = timeline.count
        while low < high {
            let middle = (low + high) / 2
            if timeline[middle].ts <= ts + 5 { low = middle + 1 } else { high = middle }
        }
        if low > 0, ts - timeline[low - 1].ts <= lookBack, !timeline[low - 1].model.isEmpty {
            return timeline[low - 1].model
        }
        if low < timeline.count, timeline[low].ts - ts <= lookAhead, !timeline[low].model.isEmpty {
            return timeline[low].model
        }
        return nil
    }

    /// Looks up one batch. Returns how many rows it examined and how many it settled (given a
    /// model, or marked unknown); `examined == batchSize` means more may be waiting.
    @discardableResult
    public static func step(
        store: EurekaStore, now: Date = Date()
    ) throws -> (examined: Int, settled: Int) {
        let rows = try store.audit.unattributed(
            before: now.addingTimeInterval(-settleDelay), limit: batchSize)
        guard !rows.isEmpty else { return (0, 0) }
        var timelines: [String: [(ts: Double, model: String)]] = [:]
        var settled: [(id: Int64, model: String)] = []
        let giveUpBefore = now.timeIntervalSince1970 - giveUpAfter
        for row in rows {
            let key = row.source + "\u{1}" + row.sessionId
            let timeline: [(ts: Double, model: String)]
            if let cached = timelines[key] {
                timeline = cached
            } else {
                timeline = try store.audit.modelTimeline(source: row.source, sessionId: row.sessionId)
                timelines[key] = timeline
            }
            if let model = model(at: row.ts, in: timeline) {
                settled.append((row.id, model))
            } else if row.ts < giveUpBefore {
                settled.append((row.id, ""))
            }
        }
        try store.audit.setModels(settled)
        return (rows.count, settled.count)
    }
}
