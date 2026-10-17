import EurekaKit
import Foundation

/// Category breakdown of a session's context usage (data model for the "Context usage" card on the
/// session detail page). Transcripts only record the conversation body and (for some sources)
/// per-request tokens; the real footprint of the system prompt / tool schemas / MCP / skills is
/// unavailable, so apart from the total flagged by totalIsReal every category is a heuristic
/// estimate.
public struct ContextBreakdown: Equatable, Sendable {
    /// Five categories, in the same order as the reference layout (shared by the stacked bar and
    /// the legend)
    public enum Category: String, CaseIterable, Sendable {
        case systemPrompt
        case tools
        case messages
        case mcp
        case skills

        public var label: String {
            switch self {
            case .systemPrompt: return L10n.text("System prompt", zhHans: "系统提示词")
            case .tools: return L10n.text("Tools and subagents", zhHans: "工具及子智能体")
            case .messages: return L10n.text("Conversation messages", zhHans: "对话消息")
            case .mcp: return L10n.text("Connectors and MCP", zhHans: "连接器及MCP")
            case .skills: return L10n.text("Skills", zhHans: "技能")
            }
        }
    }

    public struct Entry: Equatable, Sendable, Identifiable {
        public var category: Category
        public var tokens: Int
        public var id: String { category.rawValue }

        public init(category: Category, tokens: Int) {
            self.category = category
            self.tokens = tokens
        }
    }

    /// Fixed five categories, in Category declaration order
    public var entries: [Entry]
    /// Total context usage: the last turn's real value when totalIsReal, otherwise the estimated
    /// sum
    public var totalTokens: Int
    /// Context window size (the percentage denominator): prefer the real value carried by session
    /// data (codex model_context_window / kimi config.toml max_context_size), else look up the
    /// model in the ContextWindows table, finally fall back to the default
    public var windowTokens: Int
    /// Whether the total is the last turn's real value (false = pure estimate; the UI shows an
    /// "estimated" badge)
    public var totalIsReal: Bool

    public init(entries: [Entry], totalTokens: Int, windowTokens: Int, totalIsReal: Bool) {
        self.entries = entries
        self.totalTokens = totalTokens
        self.windowTokens = windowTokens
        self.totalIsReal = totalIsReal
    }

    public func tokens(for category: Category) -> Int {
        entries.first { $0.category == category }?.tokens ?? 0
    }
}

/// Heuristic token count estimate. **Rough estimate**: no tokenizer dependency, only for category
/// proportions.
public enum TokenEstimator {
    /// ASCII runs count ~4 chars per token; non-ASCII (CJK etc.) counts 1 char per token
    public static func estimate(_ text: String) -> Int {
        var ascii = 0
        var nonASCII = 0
        for scalar in text.unicodeScalars {
            if scalar.isASCII {
                ascii += 1
            } else {
                nonASCII += 1
            }
        }
        // Round ASCII up so short text never estimates to 0
        return (ascii + 3) / 4 + nonASCII
    }
}
