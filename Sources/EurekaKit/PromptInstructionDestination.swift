import Foundation

/// 「升级为指令」的落点：把一条反复在问的提问沉淀成 agent **每次会话都会加载**的持久指令。
/// 写到哪、写完落到哪个知识页由这里统一裁定 —— UI 的目标源列表、reveal 的 kind、
/// 文件说明文案都从这里取，不各写一份。
///
/// 只开放两个源，且都是"追加一节到共享指令文件"：
/// - claude → `~/.claude/CLAUDE.md`（用户级指令）。**不是** `~/.claude/memories/`：官方
///   `.claude` 目录参考（code.claude.com/docs/en/claude-directory）与 memory 页列出的加载项
///   只有 CLAUDE.md 系列、`.claude/rules/` 与 `projects/<project>/memory/` 自动记忆，
///   写进 memories/ 的东西 Claude Code 永远读不到（Eureka 自己索引它不等于 Claude 会加载）。
/// - codex → `~/.codex/AGENTS.md`；存在 `AGENTS.override.md` 时追加到它（Codex 每级目录只加载
///   两者中第一个存在的，写 AGENTS.md 等于写进黑洞）。
///
/// 其余源不开放：kimi/hermes 是有格式约束的共享单文件（hermes 外部写入会触发它的漂移保护），
/// cursor/antigravity 没有全局指令文件。两个落点在索引里都是指令类，reveal 落指令页。
public enum PromptInstructionDestination: Equatable, Sendable, CaseIterable {
    case claudeUserInstructions
    case codexAgentsFile

    public static func destination(for source: AgentSource) -> PromptInstructionDestination? {
        switch source {
        case .claude: return .claudeUserInstructions
        case .codex: return .codexAgentsFile
        default: return nil
        }
    }

    /// 支持毕业为指令的源（顺序稳定，供目标选择器用）
    public static var supportedSources: [AgentSource] {
        AgentSource.allCases.filter { destination(for: $0) != nil }
    }

    /// `.eurekaRevealKnowledge` 的 kind：两个落点都是指令文件
    public var knowledgeKind: String { "instruction" }

    /// 给用户看的目标文件（Codex 的 override 分支在写盘时才知道，文案不展开）
    public var fileLabel: String {
        switch self {
        case .claudeUserInstructions: return "~/.claude/CLAUDE.md"
        case .codexAgentsFile: return "~/.codex/AGENTS.md"
        }
    }

    /// 目标文件不存在时新建文件的一级标题
    public var defaultHeader: String {
        switch self {
        case .claudeUserInstructions: return "# CLAUDE.md"
        case .codexAgentsFile: return "# AGENTS.md"
        }
    }
}
