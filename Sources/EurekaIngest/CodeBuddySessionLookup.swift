import Foundation

/// What a product's own records say about one CodeBuddy-family session. Only WorkBuddy has such
/// records (`~/.workbuddy/workbuddy.db`); every field is optional because a session can be newer
/// than its database row, and the database can be unreadable for a moment.
public struct CodeBuddySessionHints: Equatable, Sendable {
    /// `sessions.is_background_automation`: a scheduled automation run
    public var isAutomation: Bool?
    /// The title the product shows (`custom_title`, else `title`)
    public var title: String?
    /// The context window the session runs with (`sessions.context_window`)
    public var contextWindow: Int?

    public init(isAutomation: Bool? = nil, title: String? = nil, contextWindow: Int? = nil) {
        self.isAutomation = isAutomation
        self.title = title
        self.contextWindow = contextWindow
    }
}

/// Session id → hints; nil when nothing is known (no row, or the read failed)
public typealias CodeBuddySessionLookup = @Sendable (String) -> CodeBuddySessionHints?
