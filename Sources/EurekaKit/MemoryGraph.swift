import Foundation

/// The **relationship graph of a memory library**: nodes = index / category / memory entry /
/// origin session; edges = index inclusion, `[[wiki link]]` references, and the session an
/// entry was born in.
///
/// Pure value types + a pure-function builder, living in EurekaKit (following `TurnGraph`):
/// no IO, no AppKit, reproducible output => unit-testable, and usable as a stable baseline for
/// offscreen rendering.
///
/// The input is deliberately **not** `MemoryEntry`: that is an EurekaIngest type, and the module
/// direction is `EurekaIngest → EurekaStore → EurekaKit`, so the reverse dependency is not
/// allowed. The mapping happens on the EurekaIngest side (`MemoryLibrary.graphInput()`), the
/// same split as `TurnInput` ← `TurnMetricsIndexer`.
public struct MemoryGraphInput: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// Stable identifier (the memory file's absolute path)
        public var id: String
        public var title: String
        /// Subtitle: description summary
        public var subtitle: String
        public var type: MemoryType
        /// Matchable aliases for `[[link]]`: file basename, frontmatter `name` (case-insensitive)
        public var aliases: [String]
        /// Raw `[[…]]` text found in the body
        public var links: [String]
        public var originSessionId: String?
        /// Whether the origin session's transcript still exists (missing = greyed out on the
        /// graph, not navigable)
        public var originSessionExists: Bool
        public var modifiedAt: Date
        /// The memory library's index file (MEMORY.md), not a regular entry
        public var isIndex: Bool
        /// Not listed in `MEMORY.md` -- an agent reading the index never sees it, so it is a
        /// dead memory
        public var isUnindexed: Bool

        public init(
            id: String, title: String, subtitle: String = "",
            type: MemoryType = .other, aliases: [String] = [], links: [String] = [],
            originSessionId: String? = nil, originSessionExists: Bool = false,
            modifiedAt: Date = .distantPast, isIndex: Bool = false,
            isUnindexed: Bool = false
        ) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.type = type
            self.aliases = aliases
            self.links = links
            self.originSessionId = originSessionId
            self.originSessionExists = originSessionExists
            self.modifiedAt = modifiedAt
            self.isIndex = isIndex
            self.isUnindexed = isUnindexed
        }
    }

    /// Memory library name (project name)
    public var title: String
    public var items: [Item]

    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }
}

public enum MemoryGraph {
    // MARK: - Nodes

    public enum NodeKind: Equatable, Sendable {
        /// Memory library index MEMORY.md
        case index
        /// Category swimlane header
        case category(MemoryType)
        /// A single memory
        case entry(MemoryType)
        /// Origin session; `exists == false` = transcript is gone (47 of the 84 origins on
        /// this machine)
        case session(exists: Bool)

        public var memoryType: MemoryType? {
            switch self {
            case .category(let type), .entry(let type): return type
            default: return nil
            }
        }
    }

    public struct NodeID: Hashable, Sendable, CustomStringConvertible {
        public var raw: String
        public init(_ raw: String) { self.raw = raw }
        public var description: String { raw }
    }

    public struct Node: Equatable, Sendable, Identifiable {
        public var id: NodeID
        public var kind: NodeKind
        public var title: String
        public var subtitle: String
        /// Memory file path for entry nodes (the UI uses it to open details); nil for others
        public var path: String?
        /// Session id for session nodes (the UI uses it to jump to the session page)
        public var sessionId: String?
        public var modifiedAt: Date?
        /// Edge count (references + referenced-by + origin); the UI uses it to show heat
        public var degree: Int
        /// Member count for category nodes
        public var memberCount: Int
        /// Entry nodes: not listed in `MEMORY.md` (UI draws a dashed border + explanation)
        public var isUnindexed: Bool

        public init(
            id: NodeID, kind: NodeKind, title: String, subtitle: String = "",
            path: String? = nil, sessionId: String? = nil, modifiedAt: Date? = nil,
            degree: Int = 0, memberCount: Int = 0, isUnindexed: Bool = false
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.path = path
            self.sessionId = sessionId
            self.modifiedAt = modifiedAt
            self.degree = degree
            self.memberCount = memberCount
            self.isUnindexed = isUnindexed
        }
    }

    // MARK: - Edges

    public enum EdgeRole: String, Equatable, Sendable, CaseIterable {
        /// Index → category (listed in MEMORY.md)
        case contains
        /// Entry → entry (`[[wiki link]]`)
        case link
        /// Entry → origin session
        case origin

        public var label: String {
            switch self {
            case .contains: return L10n.text("Contains", zhHans: "收录")
            case .link: return L10n.text("References", zhHans: "引用")
            case .origin: return L10n.text("Origin", zhHans: "来源")
            }
        }
    }

    public struct Edge: Equatable, Sendable {
        public var from: NodeID
        public var to: NodeID
        public var role: EdgeRole
        /// Two memories reference each other (merged into one bidirectional edge instead of
        /// two overlapping lines)
        public var isBidirectional: Bool

        public init(
            from: NodeID, to: NodeID, role: EdgeRole, isBidirectional: Bool = false
        ) {
            self.from = from
            self.to = to
            self.role = role
            self.isBidirectional = isBidirectional
        }
    }

    // MARK: - Graph

    public struct Graph: Equatable, Sendable {
        public var title: String
        public var nodes: [Node]
        public var edges: [Edge]
        /// Number of `[[…]]` whose target can't be resolved (bodies that use `[[…]]` for
        /// emphasis land here; no edge is created)
        public var unresolvedLinkCount: Int
        /// Number of entries whose origin session has been deleted
        public var missingSessionCount: Int

        public init(
            title: String = "", nodes: [Node] = [], edges: [Edge] = [],
            unresolvedLinkCount: Int = 0, missingSessionCount: Int = 0
        ) {
            self.title = title
            self.nodes = nodes
            self.edges = edges
            self.unresolvedLinkCount = unresolvedLinkCount
            self.missingSessionCount = missingSessionCount
        }

        public func node(_ id: NodeID) -> Node? { nodes.first { $0.id == id } }

        /// Finds a node by memory file path (callers only have a `MemoryEntry` and shouldn't
        /// guess how node ids are spelled)
        public func nodeID(forPath path: String) -> NodeID? {
            nodes.first { $0.path == path }?.id
        }
        public var isEmpty: Bool { nodes.isEmpty }
        public var entryCount: Int {
            nodes.filter { if case .entry = $0.kind { return true } else { return false } }.count
        }
        public var sessionCount: Int {
            nodes.filter { if case .session = $0.kind { return true } else { return false } }.count
        }

        /// One-hop subgraph centred on a node (used by the "Related" mini graph on the memory
        /// detail page). Keeps only the focus + direct neighbours and **drops index/category
        /// nodes**: they are the structural skeleton and just noise in a one-hop view.
        public func subgraph(around focus: NodeID) -> Graph {
            let related = edges.filter { $0.from == focus || $0.to == focus }
            var keep: Set<NodeID> = [focus]
            for edge in related {
                keep.insert(edge.from)
                keep.insert(edge.to)
            }
            let structural: (Node) -> Bool = { node in
                switch node.kind {
                case .index, .category: return true
                default: return false
                }
            }
            let kept = nodes.filter { keep.contains($0.id) && !structural($0) }
            let keptIDs = Set(kept.map(\.id))
            return Graph(
                title: node(focus)?.title ?? title,
                nodes: kept,
                edges: related.filter { keptIDs.contains($0.from) && keptIDs.contains($0.to) },
                unresolvedLinkCount: 0, missingSessionCount: 0)
        }
    }
}

// MARK: - Building

/// `MemoryGraphInput` → `MemoryGraph.Graph`. Pure and deterministic (same input, same output).
public enum MemoryGraphBuilder {
    public static func build(_ input: MemoryGraphInput) -> MemoryGraph.Graph {
        let indexItem = input.items.first(where: \.isIndex)
        let entries = input.items.filter { !$0.isIndex }
        guard !entries.isEmpty || indexItem != nil else {
            return MemoryGraph.Graph(title: input.title)
        }

        var nodes: [MemoryGraph.Node] = []
        var edges: [MemoryGraph.Edge] = []
        var degree: [MemoryGraph.NodeID: Int] = [:]

        // Entry nodes. **Sorted first by one deterministic order** (newest first → title → id);
        // the layout engine shares this order so the two sides never sort independently.
        let sorted = entries.sorted(by: entryOrder)
        var nodeByAlias: [String: MemoryGraph.NodeID] = [:]
        var entryNodeIDs: [String: MemoryGraph.NodeID] = [:]
        for item in sorted {
            let id = entryID(item)
            entryNodeIDs[item.id] = id
            nodes.append(MemoryGraph.Node(
                id: id, kind: .entry(item.type), title: item.title, subtitle: item.subtitle,
                path: item.id, sessionId: item.originSessionId, modifiedAt: item.modifiedAt,
                isUnindexed: item.isUnindexed))
            // Aliases are first come, first served: on a clash keep the earlier-sorted entry
            // (deterministic)
            for alias in aliasKeys(of: item) where nodeByAlias[alias] == nil {
                nodeByAlias[alias] = id
            }
        }

        // Index + category swimlane headers (the index contains categories; category
        // membership is expressed by column -- see the rails in MemoryGraphLayout)
        let presentTypes = Set(sorted.map(\.type))
            .sorted { $0.laneOrder < $1.laneOrder }
        if let indexItem {
            let id = MemoryGraph.NodeID("index")
            nodes.insert(MemoryGraph.Node(
                id: id, kind: .index, title: indexItem.title.isEmpty ? "MEMORY.md" : indexItem.title,
                subtitle: L10n.format("%@ memories", zhHans: "%@ 条记忆", String(sorted.count)), path: indexItem.id,
                modifiedAt: indexItem.modifiedAt, memberCount: sorted.count), at: 0)
        }
        for type in presentTypes {
            let id = categoryID(type)
            let count = sorted.filter { $0.type == type }.count
            nodes.append(MemoryGraph.Node(
                id: id, kind: .category(type), title: type.label,
                subtitle: L10n.format("%@ items", zhHans: "%@ 条", String(count)), memberCount: count))
            if indexItem != nil {
                edges.append(MemoryGraph.Edge(
                    from: MemoryGraph.NodeID("index"), to: id, role: .contains))
            }
        }

        // `[[link]]` → reference edges. Unresolvable links are only counted; no edge is made.
        var unresolved = 0
        var seenLinks: [String: Int] = [:]  // "from->to" → index into edges
        for item in sorted {
            guard let from = entryNodeIDs[item.id] else { continue }
            for raw in item.links {
                guard let to = nodeByAlias[normalizeKey(raw)], to != from else {
                    if nodeByAlias[normalizeKey(raw)] == nil { unresolved += 1 }
                    continue
                }
                if let existing = seenLinks["\(to.raw)->\(from.raw)"] {
                    // Mutual reference: merge into one bidirectional edge, no second
                    // overlapping line
                    if !edges[existing].isBidirectional {
                        edges[existing].isBidirectional = true
                        degree[from, default: 0] += 1
                        degree[to, default: 0] += 1
                    }
                    continue
                }
                let key = "\(from.raw)->\(to.raw)"
                guard seenLinks[key] == nil else { continue }
                seenLinks[key] = edges.count
                edges.append(MemoryGraph.Edge(from: from, to: to, role: .link))
                degree[from, default: 0] += 1
                degree[to, default: 0] += 1
            }
        }

        // Origin session nodes (deduped by session id; the first entry referencing one
        // decides its sort position)
        var sessionNodeIDs: [String: MemoryGraph.NodeID] = [:]
        var missingSessions = 0
        for item in sorted {
            guard let sessionId = item.originSessionId, !sessionId.isEmpty,
                  let from = entryNodeIDs[item.id] else { continue }
            if !item.originSessionExists { missingSessions += 1 }
            let id: MemoryGraph.NodeID
            if let existing = sessionNodeIDs[sessionId] {
                id = existing
            } else {
                id = MemoryGraph.NodeID("session:\(sessionId)")
                sessionNodeIDs[sessionId] = id
                nodes.append(MemoryGraph.Node(
                    id: id, kind: .session(exists: item.originSessionExists),
                    title: L10n.format("Session %@", zhHans: "会话 %@", String(sessionId.prefix(8))),
                    subtitle: item.originSessionExists ? "" : L10n.text("Deleted", zhHans: "已删除"),
                    sessionId: sessionId))
            }
            edges.append(MemoryGraph.Edge(from: from, to: id, role: .origin))
            degree[from, default: 0] += 1
            degree[id, default: 0] += 1
        }

        for index in nodes.indices {
            nodes[index].degree = degree[nodes[index].id] ?? 0
        }
        return MemoryGraph.Graph(
            title: input.title, nodes: nodes, edges: edges,
            unresolvedLinkCount: unresolved, missingSessionCount: missingSessions)
    }

    // MARK: - Ordering and identifiers (shared with the layout engine; must be pure)

    /// Entry order: most recently modified first → title → id (identical input yields an
    /// identical graph and layout)
    public static func entryOrder(_ lhs: MemoryGraphInput.Item, _ rhs: MemoryGraphInput.Item) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id < rhs.id
    }

    static func entryID(_ item: MemoryGraphInput.Item) -> MemoryGraph.NodeID {
        MemoryGraph.NodeID("entry:\(item.id)")
    }

    static func categoryID(_ type: MemoryType) -> MemoryGraph.NodeID {
        MemoryGraph.NodeID("cat:\(type.rawValue)")
    }

    /// All matchable aliases of a memory (file basename, frontmatter name, title)
    static func aliasKeys(of item: MemoryGraphInput.Item) -> [String] {
        var seen = Set<String>()
        return (item.aliases + [item.title])
            .map(normalizeKey)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Link match key: lowercased + trimmed + `_` treated as `-`.
    /// The latter comes from observing real data: file names use underscores
    /// (`project_query_history.md`) while frontmatter `name` uses hyphens
    /// (`project-query-history`), and the same memory gets referenced both ways.
    public static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
