import Foundation

/// Pure data model + aggregation logic for ⌘K global search (merge/dedup, snippet cropping
/// around the match).
///
/// It lives in EurekaKit rather than alongside its companion `CommandPaletteService`
/// (Sources/EurekaApp) because of a lesson from `KnowledgeSearchIndexer`: `eureka-tests` can
/// only link library targets (EurekaKit/EurekaStore/EurekaIngest/…), not the object code of
/// the app shell `eureka` (an `.executableTarget`) -- type checking passes, but
/// `swift run eureka-tests` is guaranteed to blow up at link time with `Undefined symbols`.
/// The two functions here have no IO and no AppKit -- pure value types + pure functions --
/// so they naturally belong in this layer; the service that actually holds `EurekaStore` /
/// the debounce queue / `@Published` state stays in the app shell and re-exports these types
/// via typealias (following `TurnGraph`).
public enum CommandPalette {
    public enum Kind: Int, CaseIterable, Sendable {
        case session, skill, memory, instruction, plan, prompt

        public var label: String {
            switch self {
            case .session: return L10n.text("Session", zhHans: "会话")
            case .skill: return L10n.text("Skill", zhHans: "技能")
            case .memory: return L10n.text("Memory", zhHans: "记忆")
            case .instruction: return L10n.text("Instruction", zhHans: "指令")
            case .plan: return L10n.text("Plan", zhHans: "计划")
            case .prompt: return L10n.text("Prompt", zhHans: "Prompt")
            }
        }

        /// String used for userInfo["kind"] in the reveal notification (consumed by
        /// PopoverRootView routing, reused by the CommandPaletteView sender, so the two ends
        /// don't hand-write literals that drift apart). Session/plan/prompt reveal
        /// notifications carry no kind, hence nil.
        public var revealKind: String? {
            switch self {
            case .session, .plan, .prompt: return nil
            case .skill: return "skill"
            case .memory: return "memory"
            case .instruction: return "instruction"
            }
        }
    }

    public struct Hit: Identifiable, Equatable, Sendable {
        public var kind: Kind
        /// Dedup key: knowledge surfaces / plans = file path; sessions = session id
        public var key: String
        public var title: String
        public var subtitle: String?
        /// Context snippet for a body match (nil for metadata matches)
        public var snippet: String?
        public var sessionId: String?
        /// Message position for a session body match
        public var messageIdx: Int?
        public var id: String { "\(kind.rawValue):\(key)" }

        public init(
            kind: Kind, key: String, title: String, subtitle: String?,
            snippet: String?, sessionId: String?, messageIdx: Int?
        ) {
            self.kind = kind
            self.key = key
            self.title = title
            self.subtitle = subtitle
            self.snippet = snippet
            self.sessionId = sessionId
            self.messageIdx = messageIdx
        }
    }

    /// Merge/dedup: for the same (kind, key) keep the first occurrence (metadata first →
    /// title matches win); each group is capped
    public static func merge(_ hits: [Hit], perKindCap: Int) -> [Hit] {
        var seen = Set<String>()
        var byKind: [Kind: [Hit]] = [:]
        for hit in hits {
            guard seen.insert(hit.id).inserted else { continue }
            if byKind[hit.kind, default: []].count < perKindCap {
                byKind[hit.kind, default: []].append(hit)
            }
        }
        return Kind.allCases.flatMap { byKind[$0] ?? [] }
    }

    /// Crops around the match: radius characters on each side of the hit. Locate the hit in
    /// the original text and cut a window first, then flatten newlines/tabs only inside the
    /// window -- bodies can reach 256KB, so running `replacingOccurrences` over the whole text
    /// before locating would be pure waste.
    public static func snippet(_ text: String, query: String, radius: Int = 40) -> String {
        guard let range = text.range(of: query, options: .caseInsensitive) else {
            let end = text.index(
                text.startIndex, offsetBy: radius * 2, limitedBy: text.endIndex) ?? text.endIndex
            return flatten(text[text.startIndex..<end])
        }
        let start = text.index(
            range.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(
            range.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex
        return flatten(text[start..<end])
    }

    /// Flattens newlines/carriage returns/tabs in the window to spaces (bodies may contain
    /// all three)
    private static func flatten(_ window: Substring) -> String {
        String(window)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
    }
}
