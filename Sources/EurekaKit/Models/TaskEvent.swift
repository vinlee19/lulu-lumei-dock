import Foundation

/// How a task ended (CaseIterable: the history chart legend iterates all cases, in declaration
/// order)
public enum TaskOutcome: String, Codable, Sendable, CaseIterable {
    case success
    case error
    case interrupted

    /// UI copy (shared by history-row outcome labels / chart legend / CSV export)
    public var label: String {
        switch self {
        case .success: return L10n.text("Success", zhHans: "成功")
        case .error: return L10n.text("Failed", zhHans: "失败")
        case .interrupted: return L10n.text("Interrupted", zhHans: "中断")
        }
    }
}

/// Why it is waiting (Claude Notification category)
public enum WaitReason: String, Codable, Sendable {
    case permission   // requesting tool permission
    case idle         // idle, waiting for input

    public var displayName: String {
        switch self {
        case .permission: return L10n.text("Waiting for permission", zhHans: "等待权限确认")
        case .idle: return L10n.text("Waiting for input", zhHans: "等待输入")
        }
    }
}

/// Unified domain event: output of every decoder (hook/notify/rollout), input to TaskStore
public struct TaskEvent: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case taskStarted(title: String?)
        case taskFinished(outcome: TaskOutcome, title: String?, detail: String?)
        case waiting(reason: WaitReason, message: String?)
        /// PostToolUse heartbeat: resets waiting to running and refreshes activity time; tool = the
        /// tool just run
        case activity(tool: String?)
        /// PreToolUse: a tool is **about to run** (or is waiting for your approval). A separate
        /// case rather than an associated value on activity: the semantics differ (about to vs just
        /// done), and `.activity` has 30 construction sites, so changing its signature would be
        /// pointless churn. detail is the concrete target (first command line / file path / URL) so
        /// the island can show "Edit src/main.swift" and the permission card can say exactly what
        /// is being requested.
        case toolPending(tool: String, detail: String?)
        /// PreCompact: context is being compacted. No other events arrive meanwhile, so the island
        /// looks frozen and needs its own state.
        case compacting
        /// Session context-window usage update (0-100)
        case contextUpdate(percent: Double)
        /// Task title upgrade (e.g. the transcript's ai-title, a better session name than the raw
        /// prompt)
        case titleUpdate(title: String)
        /// Subagent list snapshot update (from the Claude transcript watcher scanning the
        /// subagents/ dir)
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
    /// Codex turn id (used to dedup notify and rollout events)
    public var turnId: String?
    /// When the session was first created (transcript first-line timestamp / session_meta; kept
    /// across resume)
    public var sessionStartedAt: Date?
    /// Terminal the session runs in (only relay events carry it, from the envelope's terminal
    /// field; other sources rely on app-layer probing)
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
