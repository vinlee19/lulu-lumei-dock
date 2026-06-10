import Foundation

/// 进行中的任务（TaskStore 内部状态）
public struct AgentTask: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
        case running
        case waiting(WaitReason, since: Date)
    }

    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var phase: Phase

    public var id: String { Self.key(source: source, sessionId: sessionId) }

    public static func key(source: AgentSource, sessionId: String) -> String {
        "\(source.rawValue):\(sessionId)"
    }

    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public init(
        source: AgentSource,
        sessionId: String,
        title: String? = nil,
        cwd: String? = nil,
        startedAt: Date,
        lastActivityAt: Date? = nil,
        phase: Phase = .running
    ) {
        self.source = source
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.phase = phase
    }
}

/// 已结束的任务（历史记录与完成卡片）
public struct FinishedTask: Equatable, Sendable, Identifiable {
    public var id: String
    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    public var startedAt: Date?
    public var finishedAt: Date
    public var outcome: TaskOutcome
    /// 错误信息 / 中断原因等补充说明
    public var detail: String?

    public var duration: TimeInterval? {
        startedAt.map { finishedAt.timeIntervalSince($0) }
    }

    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public init(
        source: AgentSource,
        sessionId: String,
        title: String? = nil,
        cwd: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date,
        outcome: TaskOutcome,
        detail: String? = nil
    ) {
        self.id = "\(source.rawValue):\(sessionId):\(finishedAt.timeIntervalSince1970)"
        self.source = source
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.detail = detail
    }
}
