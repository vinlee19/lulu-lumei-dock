import Foundation

/// What a memory is for: taken from `metadata.type` in the markdown frontmatter (Claude's
/// memory-writing convention defines four: user / feedback / project / reference).
///
/// `other` takes **old memories without a type** (29 of 97 local files): no guessing, since a wrong
/// guess mixes "user preferences" into "project progress", which misleads more than leaving it
/// blank.
public enum MemoryType: String, Codable, Sendable, CaseIterable {
    case user
    case feedback
    case project
    case reference
    case other

    /// Lenient parsing: case- and surrounding-whitespace-insensitive; unknown values all map to
    /// `other` (no entries dropped).
    public init(loose raw: String?) {
        let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = MemoryType(rawValue: key) ?? .other
    }

    public var label: String {
        switch self {
        case .user: return L10n.text("User profile", zhHans: "用户画像")
        case .feedback: return L10n.text("Working style", zhHans: "工作方式")
        case .project: return L10n.text("Project progress", zhHans: "项目进展")
        case .reference: return L10n.text("External references", zhHans: "外部资料")
        case .other: return L10n.text("Uncategorized", zhHans: "未分类")
        }
    }

    /// **Fixed** left-to-right order of the graph swimlanes. Hardcoded rather than sorted by count:
    /// opening the same memory library twice must give the same lane positions, or the spatial
    /// memory the user built up is wiped on every refresh.
    public var laneOrder: Int {
        switch self {
        case .feedback: return 0
        case .project: return 1
        case .user: return 2
        case .reference: return 3
        case .other: return 4
        }
    }

    /// SF Symbol (shared by graph nodes and list chips)
    public var icon: String {
        switch self {
        case .user: return "person.crop.circle"
        case .feedback: return "quote.bubble"
        case .project: return "shippingbox"
        case .reference: return "link"
        case .other: return "questionmark.circle"
        }
    }
}
