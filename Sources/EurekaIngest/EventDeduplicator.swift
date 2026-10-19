import Foundation
import EurekaKit

/// Codex event dedup: notify (low latency) and the rollout tailer (main source) each report the
/// same turn's completion once. Dedup by (session, turn, event category) within a time window. Used
/// only on the EventPipeline serial queue.
public final class EventDeduplicator {
    private var seen: [String: Date] = [:]
    private let window: TimeInterval

    public init(window: TimeInterval = 600) {
        self.window = window
    }

    public func isDuplicate(_ event: TaskEvent, now: Date = Date()) -> Bool {
        guard let key = dedupKey(event) else { return false }
        prune(now: now)
        if seen[key] != nil { return true }
        seen[key] = now
        return false
    }

    private func dedupKey(_ event: TaskEvent) -> String? {
        // Only Codex has two channels; Claude hooks are single-channel and need no dedup
        guard event.source == .codex, let turnId = event.turnId else { return nil }
        switch event.kind {
        case .taskStarted: return "\(event.sessionId):\(turnId):start"
        case .taskFinished: return "\(event.sessionId):\(turnId):finish"
        default: return nil
        }
    }

    private func prune(now: Date) {
        guard seen.count > 64 else { return }
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
    }
}
