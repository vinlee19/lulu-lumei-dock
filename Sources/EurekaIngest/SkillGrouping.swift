import EurekaKit
import Foundation

/// Usage recorded for one `(source, normalized name)` pair; built by the app layer
/// from the tool-call ledger and handed in as a dictionary keyed by
/// `SkillGrouping.usageKey(source:name:)`.
public struct SkillUsage: Equatable, Sendable {
    public var count: Int
    public var lastTs: Date?

    public init(count: Int, lastTs: Date?) {
        self.count = count
        self.lastTs = lastTs
    }
}

/// One row of the Skills list: every copy of a skill that shares a normalized name,
/// regardless of which tool or project it is installed in. The list shows a group
/// once; the detail pane lists each copy with its own switch.
public struct SkillGroup: Identifiable, Equatable, Sendable {
    public var id: String { key }
    /// `SkillMemoryIndexer.normalizeSkillName` of the name (also the lookup key).
    public var key: String
    /// Display name, taken from the primary copy.
    public var name: String
    /// Enabled copies first, then system scope before project scope, then source
    /// declaration order, then path — so `primary` is the copy a user most likely means.
    public var copies: [SkillEntry]
    /// Distinct sources in `copies` order.
    public var sources: [AgentSource]
    public var enabledCount: Int
    /// Set only when every copy is project-scoped to the same project; a group with a
    /// global copy is "available everywhere" and shows no project tag.
    public var projectName: String?
    /// Sum over the copies' usage; `lastUsedAt` is the latest of them.
    public var usageCount: Int
    public var lastUsedAt: Date?

    public var primary: SkillEntry { copies[0] }
    public var isAllEnabled: Bool { enabledCount == copies.count }
    public var isAllDisabled: Bool { enabledCount == 0 }

    public func contains(path: String) -> Bool {
        copies.contains { $0.path == path }
    }
}

public enum SkillSectionKind: Equatable, Sendable {
    /// Used within the recent window (30 days by default), most used first.
    case frequent
    /// Enabled (at least one copy) but not used recently, by name.
    case enabled
    /// Every copy disabled, by name.
    case disabled
}

public struct SkillSection: Identifiable, Equatable, Sendable {
    public var id: SkillSectionKind { kind }
    public var kind: SkillSectionKind
    public var groups: [SkillGroup]
}

/// Pure grouping / sectioning for the Skills list. No IO: the app layer hands in the
/// entries (already filtered by search and source) and the usage dictionary.
public enum SkillGrouping {
    public static func usageKey(source: AgentSource, name: String) -> String {
        "\(source.rawValue):\(SkillMemoryIndexer.normalizeSkillName(name))"
    }

    public static func groups(_ skills: [SkillEntry], usage: [String: SkillUsage]) -> [SkillGroup] {
        var order: [String] = []
        var buckets: [String: [SkillEntry]] = [:]
        for entry in skills {
            let key = SkillMemoryIndexer.normalizeSkillName(entry.name)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { key in
            let copies = buckets[key]!.sorted(by: copyOrder)
            var sources: [AgentSource] = []
            for copy in copies where !sources.contains(copy.source) { sources.append(copy.source) }
            let projects = Set(copies.map { $0.scope.projectName })
            var count = 0
            var last: Date?
            for copy in copies {
                guard let stat = usage[usageKey(source: copy.source, name: copy.name)]
                    ?? usage[usageKey(source: copy.source,
                                      name: URL(fileURLWithPath: copy.directory).lastPathComponent)]
                else { continue }
                count += stat.count
                if let ts = stat.lastTs, last.map({ ts > $0 }) ?? true { last = ts }
            }
            return SkillGroup(
                key: key,
                name: copies[0].name,
                copies: copies,
                sources: sources,
                enabledCount: copies.filter(\.enabled).count,
                projectName: projects.count == 1 ? projects.first! : nil,
                usageCount: count,
                lastUsedAt: last)
        }
    }

    public static func sections(
        _ groups: [SkillGroup], now: Date, recentWindow: TimeInterval = 30 * 86_400
    ) -> [SkillSection] {
        let cutoff = now.addingTimeInterval(-recentWindow)
        var frequent: [SkillGroup] = []
        var enabled: [SkillGroup] = []
        var disabled: [SkillGroup] = []
        for group in groups {
            if group.isAllDisabled {
                disabled.append(group)
            } else if group.usageCount > 0, let last = group.lastUsedAt, last >= cutoff {
                frequent.append(group)
            } else {
                enabled.append(group)
            }
        }
        frequent.sort {
            if $0.usageCount != $1.usageCount { return $0.usageCount > $1.usageCount }
            return nameOrder($0, $1)
        }
        enabled.sort(by: nameOrder)
        disabled.sort(by: nameOrder)
        return [
            SkillSection(kind: .frequent, groups: frequent),
            SkillSection(kind: .enabled, groups: enabled),
            SkillSection(kind: .disabled, groups: disabled),
        ].filter { !$0.groups.isEmpty }
    }

    // MARK: - ordering

    private static func nameOrder(_ a: SkillGroup, _ b: SkillGroup) -> Bool {
        let l = a.name.lowercased(), r = b.name.lowercased()
        return l == r ? a.key < b.key : l < r
    }

    private static func copyOrder(_ a: SkillEntry, _ b: SkillEntry) -> Bool {
        if a.enabled != b.enabled { return a.enabled }
        if a.scope.isProject != b.scope.isProject { return !a.scope.isProject }
        let la = AgentSource.allCases.firstIndex(of: a.source) ?? .max
        let lb = AgentSource.allCases.firstIndex(of: b.source) ?? .max
        if la != lb { return la < lb }
        return a.path < b.path
    }
}
