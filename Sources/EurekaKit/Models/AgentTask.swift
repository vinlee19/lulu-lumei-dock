import Foundation

/// 进行中的任务（TaskStore 内部状态）
public struct AgentTask: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
        case running
        case waiting(WaitReason, since: Date)
        /// 会话开着但没有 turn 在跑（任务列表可见，胶囊计数不算）
        case idle
    }

    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    /// 当前 turn 的开始时间（耗时计时基准，空闲后新 turn 会重置）
    public var startedAt: Date
    /// 会话最初创建的时间（跨 turn/resume 不变；"开始时间"模式显示它）
    public var sessionStartedAt: Date?
    public var lastActivityAt: Date
    public var phase: Phase
    /// 最近执行的工具名（PostToolUse 心跳带来，"正在干什么"）
    public var currentActivity: String?
    /// 上下文窗口占用百分比（0-100），nil = 未知
    public var contextUsedPercent: Double?
    /// 会话当前所在终端（供岛上跳转按钮用）；nil = 未知（无 hook 且探测未命中）
    public var terminal: TerminalBinding?
    /// 当前工具的**具体对象**（命令首行 / 文件路径 / URL），由 PreToolUse 带来。
    /// 让岛上显示「Edit src/main.swift」而不只是「Edit」，等待授权卡也能说清在请求什么。
    /// 只在 UI 展示、不写进历史库 —— 原始 tool_input 可能含凭据。
    public var currentToolDetail: String?
    /// 正在压缩上下文（PreCompact 到、后续有工具动静即清除）。
    /// 压缩期间没有别的事件，不标出来岛上看着像卡死。
    public var isCompacting = false
    /// 本 turn 派生的 Claude 子 agent（无则空；Codex 永远空）
    public var subagents: [SubagentInfo] = []

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
        sessionStartedAt: Date? = nil,
        lastActivityAt: Date? = nil,
        phase: Phase = .running,
        currentActivity: String? = nil,
        subagents: [SubagentInfo] = []
    ) {
        self.source = source
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.startedAt = startedAt
        self.sessionStartedAt = sessionStartedAt
        self.lastActivityAt = lastActivityAt ?? startedAt
        self.phase = phase
        self.currentActivity = currentActivity
        self.subagents = subagents
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
    /// 会话最初创建的时间（跨 turn/resume 不变；历史列表"开始时间"排序/展示用）
    public var sessionStartedAt: Date?
    public var finishedAt: Date
    public var outcome: TaskOutcome
    /// 错误信息 / 中断原因等补充说明
    public var detail: String?
    /// 会话所在终端（历史列表展示 + 智能静音判定用；结束时从任务上带过来）
    public var terminal: TerminalBinding?

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
        sessionStartedAt: Date? = nil,
        finishedAt: Date,
        outcome: TaskOutcome,
        detail: String? = nil,
        terminal: TerminalBinding? = nil
    ) {
        self.id = "\(source.rawValue):\(sessionId):\(finishedAt.timeIntervalSince1970)"
        self.source = source
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.startedAt = startedAt
        self.sessionStartedAt = sessionStartedAt
        self.finishedAt = finishedAt
        self.outcome = outcome
        self.detail = detail
        self.terminal = terminal
    }
}
