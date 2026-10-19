import Foundation

/// Data-source health registry: heartbeat/output/failure counts for each pipeline source (spool
/// consumer, 9 agent tailers/watchers, 8 usage scanners, audit, cloud sync; 20 registrations in
/// total). The Settings "data health" section renders from it, so a stalled polling source (e.g. a
/// dead timer) is directly visible instead of relying on "something feels off".
public final class HealthRegistry: @unchecked Sendable {
    public static let shared = HealthRegistry()

    public struct Entry: Sendable {
        /// nil = event-driven (no fixed heartbeat, never marked red for staleness)
        public var expectedInterval: TimeInterval?
        public var lastBeatAt: Date?
        public var lastEventAt: Date?
        public var failureCount = 0
        public var lastFailureNote: String?

        public enum Status: Equatable {
            case ok
            case degraded   // running but has recorded failures
            case stalled    // polling source overdue for a heartbeat
            case idle       // registered but no activity yet
        }

        public func status(now: Date = Date()) -> Status {
            if let interval = expectedInterval {
                guard let beat = lastBeatAt else { return .idle }
                if now.timeIntervalSince(beat) > max(interval * 3, 15) { return .stalled }
            } else if lastBeatAt == nil && lastEventAt == nil {
                return .idle
            }
            return failureCount > 0 ? .degraded : .ok
        }
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let lock = NSLock()

    public init() {}

    public func register(_ name: String, expectedInterval: TimeInterval?) {
        lock.lock()
        defer { lock.unlock() }
        if entries[name] == nil {
            order.append(name)
        }
        entries[name] = Entry(expectedInterval: expectedInterval)
    }

    public func beat(_ name: String) {
        mutate(name) { $0.lastBeatAt = Date() }
    }

    public func event(_ name: String) {
        mutate(name) { $0.lastEventAt = Date() }
    }

    public func failure(_ name: String, note: String) {
        mutate(name) {
            $0.failureCount += 1
            $0.lastFailureNote = note
        }
    }

    /// Snapshots in registration order
    public func snapshot() -> [(name: String, entry: Entry)] {
        lock.lock()
        defer { lock.unlock() }
        return order.compactMap { name in
            entries[name].map { (name, $0) }
        }
    }

    private func mutate(_ name: String, _ apply: (inout Entry) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        var entry = entries[name] ?? Entry(expectedInterval: nil)
        apply(&entry)
        if entries[name] == nil {
            order.append(name)
        }
        entries[name] = entry
    }
}
