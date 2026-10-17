import Foundation

/// An in-flight task (TaskStore internal state)
public struct AgentTask: Equatable, Sendable, Identifiable {
    public enum Phase: Equatable, Sendable {
        case running
        case waiting(WaitReason, since: Date)
        /// Session open but no turn running (visible in the task list, not counted in the capsule)
        case idle
    }

    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    /// Start time of the current turn (baseline for the elapsed timer; reset by a new turn after
    /// idle)
    public var startedAt: Date
    /// When the session was first created (unchanged across turns/resume; shown in "start time"
    /// mode)
    public var sessionStartedAt: Date?
    public var lastActivityAt: Date
    public var phase: Phase
    /// Most recently run tool (brought by the PostToolUse heartbeat; "what it's doing")
    public var currentActivity: String?
    /// Context-window usage percentage (0-100); nil = unknown
    public var contextUsedPercent: Double?
    /// Terminal the session currently runs in (for the island's jump button); nil = unknown (no
    /// hook and probing missed)
    public var terminal: TerminalBinding?
    /// The current tool's **concrete target** (first command line / file path / URL), brought by
    /// PreToolUse. Lets the island show "Edit src/main.swift" rather than just "Edit", and the
    /// permission card say what is being requested. UI display only, never written to the history
    /// DB: raw tool_input may contain credentials.
    public var currentToolDetail: String?
    /// Context is being compacted (set on PreCompact, cleared on the next tool activity).
    /// No other events arrive during compaction; unmarked, the island looks frozen.
    public var isCompacting = false
    /// Claude subagents spawned this turn (empty if none; always empty for Codex)
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

/// A finished task (history record and finished card)
public struct FinishedTask: Equatable, Sendable, Identifiable {
    public var id: String
    public var source: AgentSource
    public var sessionId: String
    public var title: String?
    public var cwd: String?
    public var startedAt: Date?
    /// When the session was first created (unchanged across turns/resume; for "start time"
    /// sorting/display in the history list)
    public var sessionStartedAt: Date?
    public var finishedAt: Date
    public var outcome: TaskOutcome
    /// Extra detail such as the error message / interruption reason
    public var detail: String?
    /// Terminal the session ran in (history list display + smart-mute checks; carried over from the
    /// task on finish)
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
