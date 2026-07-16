import Foundation

/// 工具/操作分类。原为 EurekaIngest 的 `ToolStep.Kind`，上移到域层供审计与轨迹共用
/// （`ToolStep.Kind` 保留为本类型的 typealias，源码兼容）。
public enum ToolKind: String, Equatable, Sendable, CaseIterable, Codable {
    case read      // 读文件（Read / view_image）
    case search    // 本地检索（Grep / Glob）
    case command   // 命令（Bash / exec_command / shell / shell_command / write_stdin）
    case edit      // 编辑（Edit / Write / MultiEdit / NotebookEdit / apply_patch）
    case web       // 联网（WebSearch / WebFetch / web_search_call）
    case mcp       // MCP 工具
    case agent     // 子代理（Task / Agent）
    case skill     // 技能（Skill）
    case other     // 其余（TodoWrite / update_plan / …）

    /// 中文标签（分类速览 / Markdown 导出 / 审计筛选共用）
    public var label: String {
        switch self {
        case .read: return "读取"
        case .search: return "检索"
        case .command: return "命令"
        case .edit: return "编辑"
        case .web: return "联网"
        case .mcp: return "MCP"
        case .agent: return "子代理"
        case .skill: return "技能"
        case .other: return "工具"
        }
    }
}

/// 风险等级。0（无风险）不建模，只用 notice / high 两档。
public enum RiskLevel: Int, Codable, Sendable, Comparable {
    case notice = 1   // 提醒：只标记入库，不弹卡/通知
    case high = 2     // 高危：弹岛卡 + 系统通知

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var label: String {
        switch self {
        case .notice: return "提醒"
        case .high: return "高危"
        }
    }
}

/// 一条审计事件：agent 执行的一次操作（命令/读写文件/联网/MCP…）。
/// detail 存操作参数全文（命令全文 / 文件路径 / URL / pattern），**不含任何执行输出正文**。
public struct AuditEvent: Equatable, Sendable {
    /// 幂等键：Claude 的 tool_use_id / Codex 的 call_id / 合成 hash。跨重放稳定。
    public var opId: String
    public var source: AgentSource
    public var sessionId: String
    public var timestamp: Date
    public var kind: ToolKind
    public var tool: String       // 展示用工具名（Bash / Edit / server.tool / 子代理类型…）
    public var detail: String     // 操作参数全文（不截断）
    public var cwd: String?
    public var exitCode: Int?     // Codex function_call_output.metadata.exit_code；无则 nil
    public var isError: Bool
    public var riskLevel: RiskLevel?
    public var riskRule: String?  // 命中规则 id（如 "sudo" / "rm-rf"）

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

/// 风险命中结果（规则引擎的输出）。
public struct RiskHit: Equatable, Sendable {
    public var ruleId: String
    public var title: String    // 中文规则标题（「sudo 提权执行」）
    public var level: RiskLevel

    public init(ruleId: String, title: String, level: RiskLevel) {
        self.ruleId = ruleId
        self.title = title
        self.level = level
    }
}

/// 高危告警：命中 high 规则、需在岛上/系统通知呈现的一次事件。
/// id 用 opId，供岛卡队列去重。
public struct RiskAlert: Equatable, Sendable, Identifiable {
    public var id: String { opId }
    public var opId: String
    public var source: AgentSource
    public var sessionId: String
    public var ruleId: String
    public var ruleTitle: String
    public var tool: String
    public var detail: String     // 命令/路径摘要（岛卡展示，视图侧再截断）
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
