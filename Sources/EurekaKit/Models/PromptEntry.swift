import Foundation

/// Prompt library entry: one user prompt extracted from a session transcript.
///
/// `id = "source:sessionId:msgIdx"`: deterministic and stable across scans (message indexes
/// increase monotonically within a file; resume appends only create new ids and never renumber old
/// ones). Favorites/tags/use counts are facts the user wrote; an extraction refresh only updates
/// the body and timestamps and never touches the user-annotation columns.
public struct PromptEntry: Equatable, Sendable, Identifiable {
    public let id: String
    public let source: AgentSource
    public let sessionId: String
    /// Message index within the transcript (for jumping back to the session; fed to
    /// revealMessage(sessionId:messageIdx:))
    public let messageIdx: Int
    public let text: String
    public let timestamp: Date?
    public let cwd: String?
    // MARK: User annotations (never overwritten by extraction)
    public var favorite: Bool
    /// JSON-encoded tag array (for storage); in memory read/write the array directly
    public var tags: [String]
    public var useCount: Int
    public var lastUsedAt: Date?
    /// First extraction time (default sort key for the list)
    public let firstSeen: Date

    public init(
        id: String, source: AgentSource, sessionId: String, messageIdx: Int,
        text: String, timestamp: Date?, cwd: String?,
        favorite: Bool = false, tags: [String] = [],
        useCount: Int = 0, lastUsedAt: Date? = nil, firstSeen: Date
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.messageIdx = messageIdx
        self.text = text
        self.timestamp = timestamp
        self.cwd = cwd
        self.favorite = favorite
        self.tags = tags
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.firstSeen = firstSeen
    }

    /// List title: first line with whitespace collapsed, truncated (counted in characters for CJK;
    /// 60 is enough to tell entries apart)
    public var title: String {
        let firstLine = text.split(
            separator: "\n", maxSplits: 1, omittingEmptySubsequences: true
        ).first.map(String.init) ?? text
        let flattened = firstLine
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "\t", with: " ")
        return flattened.count <= 60 ? flattened : String(flattened.prefix(60)) + "…"
    }

    /// Project name (last path component of cwd)
    public var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    public static func makeId(
        source: AgentSource, sessionId: String, messageIdx: Int
    ) -> String {
        "\(source.rawValue):\(sessionId):\(messageIdx)"
    }
}
