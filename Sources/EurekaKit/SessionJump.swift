import Foundation

/// A direct link to a session inside its host app (read from local records, see
/// `SessionAppLinkResolver`).
///
/// Both URL formats come from the apps' own code:
/// - Claude Desktop: `claude://code/continue?session=local_…`. Desktop looks the session up by its
///   own `local_` id (never the CLI session id) among unarchived sessions; an archived one falls
///   through to the Code home page.
/// - Codex Desktop: `codex://threads/<id>`, where the id is the rollout `session_meta` id (the
///   app's own "copy link" builds it the same way).
public enum SessionAppLink: Equatable, Sendable {
    case claudeDesktop(localSessionId: String)
    case codexDesktop(threadId: String)

    public static let claudeDesktopBundleId = "com.anthropic.claudefordesktop"
    public static let codexDesktopBundleId = "com.openai.codex"

    /// The app that handles this link
    public var bundleId: String {
        switch self {
        case .claudeDesktop: return Self.claudeDesktopBundleId
        case .codexDesktop: return Self.codexDesktopBundleId
        }
    }

    /// nil when the id is malformed: ids come from local files and must be validated before they
    /// go into a URL
    public var url: URL? {
        switch self {
        case .claudeDesktop(let localSessionId):
            guard Self.isClaudeDesktopSessionId(localSessionId) else { return nil }
            var components = URLComponents()
            components.scheme = "claude"
            components.host = "code"
            components.path = "/continue"
            components.queryItems = [URLQueryItem(name: "session", value: localSessionId)]
            return components.url
        case .codexDesktop(let threadId):
            guard Self.isUUID(threadId) else { return nil }
            return URL(string: "codex://threads/\(threadId.lowercased())")
        }
    }

    /// Same rule as the Desktop deep-link handler: `^local_[A-Za-z0-9-]{1,64}$`
    public static func isClaudeDesktopSessionId(_ value: String) -> Bool {
        let prefix = "local_"
        guard value.hasPrefix(prefix) else { return false }
        let rest = value.dropFirst(prefix.count)
        return (1...64).contains(rest.count) && rest.unicodeScalars.allSatisfy { scalar in
            scalar == "-" || (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
        }
    }

    /// Claude CLI and Codex session ids are both UUIDs
    public static func isUUID(_ value: String) -> Bool {
        value.count == 36 && UUID(uuidString: value) != nil
    }
}

/// Where the island's "open session" button goes
public enum SessionJumpTarget: Equatable, Sendable {
    /// Deep link straight into the session
    case appLink(SessionAppLink)
    /// Only bring the host app (terminal / IDE) to the front, without selecting a tab
    case hostApp(TerminalBinding)

    /// Picks the target by priority:
    /// 1. A hook-captured host that is not the link's app → that host. The session runs there right
    ///    now (e.g. a Desktop session resumed in iTerm with `claude --resume`); the Desktop entry is
    ///    only an old record.
    /// 2. A direct link → the link.
    /// 3. Any host (probed ones included) → the host app. Probing matches processes by cwd and can
    ///    pick the wrong one, so it ranks below the link.
    /// 4. Nothing → nil, and the island shows no button.
    public static func resolve(terminal: TerminalBinding?, link: SessionAppLink?) -> SessionJumpTarget? {
        if let terminal, terminal.origin == .hook, let link, terminal.bundleId != link.bundleId {
            return .hostApp(terminal)
        }
        if let link { return .appLink(link) }
        if let terminal { return .hostApp(terminal) }
        return nil
    }
}
