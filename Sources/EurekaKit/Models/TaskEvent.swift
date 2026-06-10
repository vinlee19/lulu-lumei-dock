import Foundation

/// 任务结束方式
public enum TaskOutcome: String, Codable, Sendable {
    case success
    case error
    case interrupted
}

/// 等待原因（Claude Notification 分类）
public enum WaitReason: String, Codable, Sendable {
    case permission   // 请求工具权限
    case idle         // 空闲等待输入

    public var displayName: String {
        switch self {
        case .permission: return "等待权限确认"
        case .idle: return "等待输入"
        }
    }
}

/// 统一领域事件：各解码器（hook/notify/rollout）的输出，TaskStore 的输入
public struct TaskEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case taskStarted(title: String?)
        case taskFinished(outcome: TaskOutcome, title: String?, detail: String?)
        case waiting(reason: WaitReason, message: String?)
        /// PostToolUse 心跳：waiting 复位为 running、刷新活跃时间
        case activity
        case sessionStarted
        case sessionEnded(reason: String?)
    }

    public var source: AgentSource
    public var sessionId: String
    public var kind: Kind
    public var timestamp: Date
    public var cwd: String?
    public var transcriptPath: String?
    /// Codex turn id（notify 与 rollout 事件去重用）
    public var turnId: String?

    public init(
        source: AgentSource,
        sessionId: String,
        kind: Kind,
        timestamp: Date,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        turnId: String? = nil
    ) {
        self.source = source
        self.sessionId = sessionId
        self.kind = kind
        self.timestamp = timestamp
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.turnId = turnId
    }
}
