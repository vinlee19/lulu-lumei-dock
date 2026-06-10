import Foundation
import EurekaKit

/// Codex 事件去重：notify（低延迟）与 rollout tailer（主源）会对同一 turn
/// 各报一次完成。按 (session, turn, 事件类别) 在时间窗内去重。
/// 仅在 EventPipeline 串行队列上使用。
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
        // 只有 Codex 存在双通道；Claude hooks 单通道无需去重
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
