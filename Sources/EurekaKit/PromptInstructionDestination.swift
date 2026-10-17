import Foundation

/// Destination for "promote to instruction": turns a repeatedly asked prompt into a persistent
/// instruction the agent **loads every session**. Where it is written and which knowledge page it
/// lands on afterwards are decided here alone; the UI's target-source list, the reveal kind, and
/// the file description copy all come from here rather than each keeping its own copy.
///
/// Only two sources are offered, both "append a section to a shared instruction file":
/// - claude → `~/.claude/CLAUDE.md` (user-level instructions). **Not** `~/.claude/memories/`: the
///   official `.claude` directory reference (code.claude.com/docs/en/claude-directory) and the
///   memory page list as loaded only the CLAUDE.md family, `.claude/rules/`, and the
///   `projects/<project>/memory/` auto memory; anything written to memories/ is never read by
///   Claude Code (Eureka indexing it doesn't mean Claude loads it).
/// - codex → `~/.codex/AGENTS.md`; appends to `AGENTS.override.md` when it exists (at each
///   directory level Codex loads only the first of the two that exists, so writing AGENTS.md would
///   go into a black hole).
///
/// Other sources are not offered: kimi/hermes use shared single files with format constraints (an
/// external write trips hermes's drift protection), and cursor/antigravity have no global
/// instruction file. Both destinations index as instructions, so reveal lands on the Instructions
/// page.
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

    /// Sources that support graduating to an instruction (stable order, for the target picker)
    public static var supportedSources: [AgentSource] {
        AgentSource.allCases.filter { destination(for: $0) != nil }
    }

    /// Kind for `.eurekaRevealKnowledge`: both destinations are instruction files
    public var knowledgeKind: String { "instruction" }

    /// Target file shown to the user (Codex's override branch is only known at write time, so the
    /// copy doesn't spell it out)
    public var fileLabel: String {
        switch self {
        case .claudeUserInstructions: return "~/.claude/CLAUDE.md"
        case .codexAgentsFile: return "~/.codex/AGENTS.md"
        }
    }

    /// Top-level heading for a newly created target file when it doesn't exist
    public var defaultHeader: String {
        switch self {
        case .claudeUserInstructions: return "# CLAUDE.md"
        case .codexAgentsFile: return "# AGENTS.md"
        }
    }
}
