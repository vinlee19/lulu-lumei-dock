import Foundation

/// 事件来源：哪个 CLI 工具
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case codex
    case opencode
    case grok
    case antigravity
    case kimi

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .grok: return "Grok"
        case .antigravity: return "Antigravity"
        case .kimi: return "Kimi"
        }
    }
}
