import Foundation

/// 数据源健康登记：5 个数据源（spool、rollout 监视、transcript 监视、双用量扫描）
/// 的心跳/产出/失败计数。设置页"数据健康"区据此渲染——
/// 轮询型数据源停摆（如定时器死掉）能被直接看见，不再靠"感觉不对"。
public final class HealthRegistry: @unchecked Sendable {
    public static let shared = HealthRegistry()

    public struct Entry: Sendable {
        /// nil = 事件驱动（无固定心跳，不按 stale 判红）
        public var expectedInterval: TimeInterval?
        public var lastBeatAt: Date?
        public var lastEventAt: Date?
        public var failureCount = 0
        public var lastFailureNote: String?

        public enum Status: Equatable {
            case ok
            case degraded   // 在跑但有失败记录
            case stalled    // 轮询型超时未心跳
            case idle       // 注册了还没动静
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

    /// 按注册顺序返回快照
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
