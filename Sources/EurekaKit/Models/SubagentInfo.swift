import Foundation

/// Claude Code 子 agent（Agent/Task 工具派生的子任务）的当前状态快照。
/// 数据源：`<sessionId>/subagents/agent-<id>.meta.json` + 父 transcript 的 tool_result。
public struct SubagentInfo: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case running     // meta.json 已建，父 transcript 还没对应 tool_result
        case completed   // 父 transcript 出现 tool_result（无 is_error）
        case failed      // tool_result 标了 is_error
    }

    /// 子 agent 实例 id（取自 agent-<id>.jsonl 文件名）
    public var agentId: String
    /// 子 agent 类型（subagent_type，如 "Explore" / "claude-code-guide"）
    public var agentType: String
    /// 派生时给的任务描述
    public var description: String
    public var status: Status
    /// 当前正在用的工具（子 agent transcript 尾部最后一个 tool_use 名）
    public var currentActivity: String?
    public var startedAt: Date?
    public var finishedAt: Date?

    public var id: String { agentId }

    public init(
        agentId: String,
        agentType: String,
        description: String,
        status: Status,
        currentActivity: String? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.agentId = agentId
        self.agentType = agentType
        self.description = description
        self.status = status
        self.currentActivity = currentActivity
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }
}
