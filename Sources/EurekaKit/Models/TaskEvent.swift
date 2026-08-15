import Foundation

/// 任务结束方式（CaseIterable：历史页图表图例全量遍历用，顺序即声明顺序）
public enum TaskOutcome: String, Codable, Sendable, CaseIterable {
    case success
    case error
    case interrupted

    /// 界面文案（历史行结局标签 / 图表图例 / 导出 CSV 共用）
    public var label: String {
        switch self {
        case .success: return "成功"
        case .error: return "失败"
        case .interrupted: return "中断"
        }
    }
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
        /// PostToolUse 心跳：waiting 复位为 running、刷新活跃时间；tool = 刚执行的工具名
        case activity(tool: String?)
        /// PreToolUse：工具**即将执行**（或正等你授权）。
        /// 单独一个 case 而不是给 activity 加关联值：语义不同（将要做 vs 刚做完），
        /// 且 `.activity` 有 30 处构造点，改签名纯属无谓的连带修改。
        /// detail 是具体对象（命令首行 / 文件路径 / URL），让岛上能显示「Edit src/main.swift」，
        /// 等待授权卡也能说清到底在请求什么。
        case toolPending(tool: String, detail: String?)
        /// PreCompact：正在压缩上下文。压缩期间没有别的事件，岛上看起来像卡死，需要单独交代。
        case compacting
        /// 会话上下文窗口占用更新（0-100）
        case contextUpdate(percent: Double)
        /// 任务标题升级（如 transcript 里的 ai-title，比原始 prompt 更适合做会话名）
        case titleUpdate(title: String)
        /// 子 agent 列表快照更新（Claude transcript 监视扫 subagents/ 目录得来）
        case subagentsUpdated([SubagentInfo])
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
    /// 会话最初创建的时间（transcript 首行时间戳 / session_meta，跨 resume 保持）
    public var sessionStartedAt: Date?
    /// 会话所在终端（仅 relay 事件带，来自信封的 terminal 字段；其余源靠 app 层探测补）
    public var terminal: TerminalBinding?

    public init(
        source: AgentSource,
        sessionId: String,
        kind: Kind,
        timestamp: Date,
        cwd: String? = nil,
        transcriptPath: String? = nil,
        turnId: String? = nil,
        sessionStartedAt: Date? = nil,
        terminal: TerminalBinding? = nil
    ) {
        self.source = source
        self.sessionId = sessionId
        self.kind = kind
        self.timestamp = timestamp
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.turnId = turnId
        self.sessionStartedAt = sessionStartedAt
        self.terminal = terminal
    }
}
