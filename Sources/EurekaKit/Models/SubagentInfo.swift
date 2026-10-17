import Foundation

/// Current status snapshot of a Claude Code subagent (a subtask spawned by the Agent/Task tool).
/// Data source: `<sessionId>/subagents/agent-<id>.meta.json` + the parent transcript's tool_result.
public struct SubagentInfo: Equatable, Sendable, Identifiable {
    public enum Status: String, Equatable, Sendable {
        case running     // meta.json exists, but the parent transcript has no matching tool_result yet
        case completed   // tool_result appeared in the parent transcript (no is_error)
        case failed      // tool_result is marked is_error
    }

    /// Subagent instance id (from the agent-<id>.jsonl file name)
    public var agentId: String
    /// Subagent type (subagent_type, e.g. "Explore" / "claude-code-guide")
    public var agentType: String
    /// Task description given at spawn time
    public var description: String
    public var status: Status
    /// Tool currently in use (last tool_use name at the tail of the subagent transcript)
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
