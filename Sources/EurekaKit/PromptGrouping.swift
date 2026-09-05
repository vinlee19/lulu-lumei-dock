import Foundation

/// 一组重复出现的提问（按归一化指纹聚类）——「你反复在问同一件事」，
/// 是模板化 / 升级为技能的头号候选。
public struct PromptGroup: Identifiable, Equatable, Sendable {
    public var id: String { fingerprint }
    public let fingerprint: String
    /// 代表条目（组内最新的一条）
    public let representative: PromptEntry
    public let count: Int
    /// 跨了几个项目（跨项目重复 = 更该毕业成全局技能/指令）
    public let projectCount: Int
    /// 组内全部条目 id（最新在前）
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
    /// 按指纹聚类；`keeping` 由调用方过滤（噪音/琐碎不该成组——实勘重复榜
    /// top 全是 `<command-name>` ×57 与"继续" ×41 这类，必须先除噪）。
    /// 出现次数 ≥ minCount 才成组；组按次数降序、同数按代表条目时间降序。
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

    /// 用户移除一条后同步内存里的组，不必重聚全库：所在组去掉该成员、代表换成剩余
    /// 成员里最新的一条（memberIds 本就最新在前）、项目数按剩余成员重算；跌破 minCount
    /// 的组整组消失；最后按 groups(from:) 同序重排（次数变了位置可能要动）。
    /// `entry` 把成员 id 解析成条目（用调用方的索引）；解析不到的成员视为已不存在。
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

    /// 组序：次数降序、同数按代表条目 firstSeen 降序（groups(from:) 与 removing 共用）
    static func sorted(_ groups: [PromptGroup]) -> [PromptGroup] {
        groups.sorted {
            $0.count == $1.count
                ? $0.representative.firstSeen > $1.representative.firstSeen
                : $0.count > $1.count
        }
    }
}
