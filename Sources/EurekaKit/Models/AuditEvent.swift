import Foundation

/// Tool/operation category. Formerly EurekaIngest's `ToolStep.Kind`, moved up to the domain layer
/// so audit and trails can share it (`ToolStep.Kind` stays as a typealias for source
/// compatibility).
public enum ToolKind: String, Equatable, Sendable, CaseIterable, Codable {
    case read      // read files (Read / view_image)
    case search    // local search (Grep / Glob)
    case command   // commands (Bash / exec_command / shell / shell_command / write_stdin)
    case edit      // edits (Edit / Write / MultiEdit / NotebookEdit / apply_patch)
    case web       // network (WebSearch / WebFetch / web_search_call)
    case mcp       // MCP tools
    case agent     // subagents (Task / Agent)
    case skill     // skills (Skill)
    case other     // everything else (TodoWrite / update_plan / ...)

    /// Display label (shared by the category overview / Markdown export / audit filters)
    public var label: String {
        switch self {
        case .read: return L10n.text("Read", zhHans: "读取")
        case .search: return L10n.text("Search", zhHans: "检索")
        case .command: return L10n.text("Command", zhHans: "命令")
        case .edit: return L10n.text("Edit", zhHans: "编辑")
        case .web: return L10n.text("Web", zhHans: "联网")
        case .mcp: return L10n.text("MCP", zhHans: "MCP")
        case .agent: return L10n.text("Subagent", zhHans: "子代理")
        case .skill: return L10n.text("Skill", zhHans: "技能")
        case .other: return L10n.text("Tool", zhHans: "工具")
        }
    }
}

extension ToolKind {
    /// Type icon (SF Symbol) for lists/trails. Pure display data like `.label`; it lives in the
    /// model layer so the audit page and session trail share it (it used to hang only off
    /// EurekaApp's TurnTrailView).
    public var icon: String {
        switch self {
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .command: return "terminal"
        case .edit: return "pencil"
        case .web: return "globe"
        case .mcp: return "puzzlepiece.extension"
        case .agent: return "person.2"
        case .skill: return "wand.and.stars"
        case .other: return "wrench.adjustable"
        }
    }
}

/// Risk level. 0 (no risk) is not modeled; only the notice / high tiers exist.
public enum RiskLevel: Int, Codable, Sendable, Comparable {
    case notice = 1   // notice: only flagged in the DB, no card/notification
    case high = 2     // high: island card + system notification

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .notice: return L10n.text("Notice", zhHans: "提醒")
        case .high: return L10n.text("High risk", zhHans: "高危")
        }
    }
}

/// One audit event: a single operation an agent performed (command / file read-write / network /
/// MCP...). detail stores the full operation arguments (full command / file path / URL / pattern),
/// **never any execution output body**.
public struct AuditEvent: Equatable, Sendable {
    /// Idempotency key: Claude's tool_use_id / Codex's call_id / a synthesized hash. Stable across
    /// replays.
    public var opId: String
    public var source: AgentSource
    public var sessionId: String
    public var timestamp: Date
    public var kind: ToolKind
    public var tool: String       // display tool name (Bash / Edit / server.tool / subagent type...)
    public var detail: String     // full operation arguments (not truncated)
    public var cwd: String?
    public var exitCode: Int?     // Codex function_call_output.metadata.exit_code; nil if absent
    public var isError: Bool
    public var riskLevel: RiskLevel?
    public var riskRule: String?  // matched rule id (e.g. "sudo" / "rm-rf")

    public init(
        opId: String, source: AgentSource, sessionId: String, timestamp: Date,
        kind: ToolKind, tool: String, detail: String, cwd: String? = nil,
        exitCode: Int? = nil, isError: Bool = false,
        riskLevel: RiskLevel? = nil, riskRule: String? = nil
    ) {
        self.opId = opId
        self.source = source
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.kind = kind
        self.tool = tool
        self.detail = detail
        self.cwd = cwd
        self.exitCode = exitCode
        self.isError = isError
        self.riskLevel = riskLevel
        self.riskRule = riskRule
    }
}

/// Risk match result (output of the rule engine).
public struct RiskHit: Equatable, Sendable {
    public var ruleId: String
    public var title: String    // localized rule title (e.g. "sudo privilege escalation")
    public var level: RiskLevel

    public init(ruleId: String, title: String, level: RiskLevel) {
        self.ruleId = ruleId
        self.title = title
        self.level = level
    }
}

/// High-risk alert: one event that matched a high rule and must surface on the island / as a system
/// notification. id is the opId, used by the island card queue for dedup.
public struct RiskAlert: Equatable, Sendable, Identifiable {
    public var id: String { opId }
    public var opId: String
    public var source: AgentSource
    public var sessionId: String
    public var ruleId: String
    public var ruleTitle: String
    public var tool: String
    public var detail: String     // command/path summary (island card; the view truncates further)
    public var timestamp: Date

    public init(
        opId: String, source: AgentSource, sessionId: String,
        ruleId: String, ruleTitle: String, tool: String, detail: String, timestamp: Date
    ) {
        self.opId = opId
        self.source = source
        self.sessionId = sessionId
        self.ruleId = ruleId
        self.ruleTitle = ruleTitle
        self.tool = tool
        self.detail = detail
        self.timestamp = timestamp
    }
}
