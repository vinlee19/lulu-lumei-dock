import Foundation

/// Event source: which CLI tool
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case grok
    case antigravity
    case kimi
    case gemini
    case qwen
    case hermes
    case codebuddy
    case qoder
    case cursor
    case trae
    case zcode

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen CLI"
        case .hermes: return "Hermes"
        case .codebuddy: return "CodeBuddy"
        case .qoder: return "Qoder"
        case .cursor: return "Cursor"
        case .trae: return "Trae"
        case .zcode: return "ZCode"
        }
    }

    /// Whether sessions live in a **shared database file** (opencode / hermes each have a single
    /// `.db`, all cursor sessions sit in the one `state.vscdb`, all trae sessions sit in the one
    /// `ModularData/ai-agent/database.db`, which is SQLCipher-encrypted on top of that, and zcode's
    /// sessions all sit in `~/.zcode/cli/db/db.sqlite`). Two things follow: no per-session
    /// deletion, and no "this session's transcript file" to show.
    public var usesSharedSessionDatabase: Bool {
        self == .opencode || self == .hermes || self == .cursor || self == .trae || self == .zcode
    }

    /// Whether a single session can be deleted. Shared-DB sources never can: deleting the file
    /// would take every session with it, and writing DELETE into a live DB touches WAL, foreign-key
    /// cascades and FTS triggers (this app is always read-only on external DBs). The service layer
    /// and the UI share this one check so the UI never offers a delete button that can't work.
    public var supportsSessionDeletion: Bool {
        !usesSharedSessionDatabase
    }
}
