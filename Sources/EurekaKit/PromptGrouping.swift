import Foundation

/// A group of repeated prompts (clustered by normalized fingerprint): "you keep asking the same
/// thing", the top candidate for templating / promotion to a skill.
public struct PromptGroup: Identifiable, Equatable, Sendable {
    public var id: String { fingerprint }
    public let fingerprint: String
    /// Representative entry (the newest in the group)
    public let representative: PromptEntry
    public let count: Int
    /// How many projects it spans (cross-project repeats = stronger case for graduating to a global
    /// skill/instruction)
    public let projectCount: Int
    /// Every entry id in the group (newest first)
    public let memberIds: [String]

    public init(
        fingerprint: String, representative: PromptEntry,
        count: Int, projectCount: Int, memberIds: [String]
    ) {
        self.fingerprint = fingerprint
        self.representative = representative
        self.count = count
        self.projectCount = projectCount
        self.memberIds = memberIds
    }
}

public enum PromptGrouping {
    /// Cluster by fingerprint; `keeping` is filtered by the caller (noise/trivial entries shouldn't
    /// group: locally the top of the repeat chart was all `<command-name>` ×57 and "continue" ×41
    /// and the like, so noise must be removed first). Only counts ≥ minCount form a group; groups
    /// sort by count descending, ties by representative entry time descending.
    public static func groups(
        from entries: [PromptEntry], minCount: Int = 3,
        keeping: (PromptEntry) -> Bool
    ) -> [PromptGroup] {
        var buckets: [String: [PromptEntry]] = [:]
        for entry in entries where keeping(entry) {
            let fingerprint = PromptClassifier.normalizedFingerprint(entry.text)
            guard !fingerprint.isEmpty else { continue }
            buckets[fingerprint, default: []].append(entry)
        }
        var result: [PromptGroup] = []
        for (fingerprint, members) in buckets where members.count >= minCount {
            let sorted = members.sorted {
                ($0.timestamp ?? $0.firstSeen) > ($1.timestamp ?? $1.firstSeen)
            }
            result.append(PromptGroup(
                fingerprint: fingerprint,
                representative: sorted[0],
                count: members.count,
                projectCount: Set(members.compactMap(\.projectName)).count,
                memberIds: sorted.map(\.id)))
        }
        return sorted(result)
    }

    /// After the user removes an entry, sync the in-memory groups without reclustering the whole
    /// DB: drop the member from its group, make the newest remaining member the representative
    /// (memberIds is already newest first), recount projects from the remaining members; groups
    /// that fall below minCount vanish; finally re-sort in the same order as groups(from:) (a
    /// changed count may move a group). `entry` resolves member ids to entries (using the caller's
    /// index); members that don't resolve are treated as gone.
    public static func removing(
        memberId: String, from groups: [PromptGroup], minCount: Int = 3,
        entry: (String) -> PromptEntry?
    ) -> [PromptGroup] {
        guard let index = groups.firstIndex(where: { $0.memberIds.contains(memberId) }) else {
            return groups
        }
        var result = groups
        let group = result.remove(at: index)
        let members = group.memberIds.filter { $0 != memberId }.compactMap(entry)
        if members.count >= minCount, let representative = members.first {
            result.append(PromptGroup(
                fingerprint: group.fingerprint,
                representative: representative,
                count: members.count,
                projectCount: Set(members.compactMap(\.projectName)).count,
                memberIds: members.map(\.id)))
        }
        return sorted(result)
    }

    /// Group order: count descending, ties by representative entry firstSeen descending (shared by
    /// groups(from:) and removing)
    static func sorted(_ groups: [PromptGroup]) -> [PromptGroup] {
        groups.sorted {
            $0.count == $1.count
                ? $0.representative.firstSeen > $1.representative.firstSeen
                : $0.count > $1.count
        }
    }
}
