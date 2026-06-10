import Foundation

/// 事件来源：哪个 CLI 工具
public enum AgentSource: String, Codable, Sendable, CaseIterable {
    case claude
    case codex

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }
}
