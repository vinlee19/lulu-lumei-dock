import Foundation

/// 事件来源：哪个 CLI 工具
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

    /// 会话是否存在一个**共享数据库文件**里（opencode / hermes 各自只有一个 `.db`，
    /// cursor 全部会话都在 `state.vscdb` 一个库里，trae 全部会话都在
    /// `ModularData/ai-agent/database.db` 一个库里 —— 而且那个库是 SQLCipher 加密的，
    /// zcode 的会话也全在 `~/.zcode/cli/db/db.sqlite` 一个库里）。
    /// 由此派生两件事：不支持单条删除，且没有「本会话的转录文件」可展示。
    public var usesSharedSessionDatabase: Bool {
        self == .opencode || self == .hermes || self == .cursor || self == .trae || self == .zcode
    }

    /// 是否支持单条删除会话。共享库的源一律不支持：删文件会连坐全部会话，
    /// 而往运行中的库写 DELETE 要碰 WAL、外键级联与 FTS 触发器（本 app 对外部库始终只读）。
    /// 服务层与 UI 的可删判定共用这一处，避免 UI 提供一个删不掉的按钮。
    public var supportsSessionDeletion: Bool {
        !usesSharedSessionDatabase
    }
}
