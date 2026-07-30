import Foundation

/// 一个**记忆库的关系图**：节点 = 索引 / 分类 / 记忆条目 / 来源会话，
/// 边 = 索引收录、`[[wiki 链接]]` 引用、条目诞生于哪次会话。
///
/// 纯值类型 + 纯函数构图，放 EurekaKit（照 `TurnGraph` 的先例）：无 IO、无 AppKit、
/// 结果可复现 ⇒ 能单测，也能被离屏渲染当作稳定基准。
///
/// 输入刻意**不是** `MemoryEntry`：那是 EurekaIngest 的类型，而模块方向是
/// `EurekaIngest → EurekaStore → EurekaKit`，反向依赖不允许。映射在 EurekaIngest 侧做
/// （`MemoryLibrary.graphInput()`），与 `TurnInput` ← `TurnMetricsIndexer` 的分工一致。
public struct MemoryGraphInput: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        /// 稳定标识（用记忆文件的绝对路径）
        public var id: String
        public var title: String
        /// 副标：description 摘要
        public var subtitle: String
        public var type: MemoryType
        /// `[[link]]` 的可匹配别名：文件 basename、frontmatter `name`（大小写不敏感）
        public var aliases: [String]
        /// 正文里出现的 `[[…]]` 原文
        public var links: [String]
        public var originSessionId: String?
        /// 来源会话的 transcript 是否还在（不在 = 图上置灰、不可跳转）
        public var originSessionExists: Bool
        public var modifiedAt: Date
        /// 记忆库的索引文件（MEMORY.md），不是普通条目
        public var isIndex: Bool
        /// 没被 `MEMORY.md` 收录 —— agent 读索引时看不到这条，等于死记忆
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

    /// 记忆库名（项目名）
    public var title: String
    public var items: [Item]

    public init(title: String, items: [Item]) {
        self.title = title
        self.items = items
    }
}

public enum MemoryGraph {
    // MARK: - 节点

    public enum NodeKind: Equatable, Sendable {
        /// 记忆库索引 MEMORY.md
        case index
        /// 分类泳道头
        case category(MemoryType)
        /// 一条记忆
        case entry(MemoryType)
        /// 来源会话；`exists == false` = transcript 已不在（本机 84 条来源里 47 条如此）
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
        /// 条目节点的记忆文件路径（UI 用它打开详情）；其余节点为 nil
        public var path: String?
        /// 会话节点的 session id（UI 用它跳会话页）
        public var sessionId: String?
        public var modifiedAt: Date?
        /// 连边数（引用 + 被引用 + 来源），UI 拿它标热度
        public var degree: Int
        /// 分类节点的成员数
        public var memberCount: Int
        /// 条目节点：没被 `MEMORY.md` 收录（UI 虚线描边 + 说明）
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

    // MARK: - 边

    public enum EdgeRole: String, Equatable, Sendable, CaseIterable {
        /// 索引 → 分类（MEMORY.md 收录）
        case contains
        /// 条目 → 条目（`[[wiki 链接]]`）
        case link
        /// 条目 → 来源会话
        case origin

        public var label: String {
            switch self {
            case .contains: return "收录"
            case .link: return "引用"
            case .origin: return "来源"
            }
        }
    }

    public struct Edge: Equatable, Sendable {
        public var from: NodeID
        public var to: NodeID
        public var role: EdgeRole
        /// 两条记忆互相引用（合成一条双向边，别画两条重合线）
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

    // MARK: - 图

    public struct Graph: Equatable, Sendable {
        public var title: String
        public var nodes: [Node]
        public var edges: [Edge]
        /// 解析不到目标的 `[[…]]` 条数（正文里把 `[[…]]` 当强调用会落在这儿，不造边）
        public var unresolvedLinkCount: Int
        /// 来源会话已被删除的条目数
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

        /// 按记忆文件路径找节点（调用方只有 `MemoryEntry`，不该去猜节点 id 的拼法）
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

        /// 以某个节点为中心的一跳子图（记忆详情页的「关联」小图用）。
        /// 只留焦点 + 直接邻居，**丢掉索引/分类节点**：它们是结构骨架，在一跳视野里只是噪声。
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

// MARK: - 构图

/// `MemoryGraphInput` → `MemoryGraph.Graph`。纯函数、确定性（同输入必得同输出）。
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

        // 条目节点。**先按同一套确定性次序排好**（时间倒序 → 标题 → id），
        // 布局器与这里共用这个次序，两边不会各排一套。
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
            // 别名先到先得：重名时保留排序在前的那条（确定性）
            for alias in aliasKeys(of: item) where nodeByAlias[alias] == nil {
                nodeByAlias[alias] = id
            }
        }

        // 索引 + 分类泳道头（索引收录分类，分类归属由列表达 —— 见 MemoryGraphLayout 的 rails）
        let presentTypes = Set(sorted.map(\.type))
            .sorted { $0.laneOrder < $1.laneOrder }
        if let indexItem {
            let id = MemoryGraph.NodeID("index")
            nodes.insert(MemoryGraph.Node(
                id: id, kind: .index, title: indexItem.title.isEmpty ? "MEMORY.md" : indexItem.title,
                subtitle: "\(sorted.count) 条记忆", path: indexItem.id,
                modifiedAt: indexItem.modifiedAt, memberCount: sorted.count), at: 0)
        }
        for type in presentTypes {
            let id = categoryID(type)
            let count = sorted.filter { $0.type == type }.count
            nodes.append(MemoryGraph.Node(
                id: id, kind: .category(type), title: type.label,
                subtitle: "\(count) 条", memberCount: count))
            if indexItem != nil {
                edges.append(MemoryGraph.Edge(
                    from: MemoryGraph.NodeID("index"), to: id, role: .contains))
            }
        }

        // `[[链接]]` → 引用边。解析不到就只计数、不造边。
        var unresolved = 0
        var seenLinks: [String: Int] = [:]  // "from->to" → edges 下标
        for item in sorted {
            guard let from = entryNodeIDs[item.id] else { continue }
            for raw in item.links {
                guard let to = nodeByAlias[normalizeKey(raw)], to != from else {
                    if nodeByAlias[normalizeKey(raw)] == nil { unresolved += 1 }
                    continue
                }
                if let existing = seenLinks["\(to.raw)->\(from.raw)"] {
                    // 互相引用：合成一条双向边，不画第二条重合线
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

        // 来源会话节点（按 session id 去重，首个引用它的条目决定它的排序位置）
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
                    title: "会话 \(sessionId.prefix(8))",
                    subtitle: item.originSessionExists ? "" : "已删除",
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

    // MARK: - 排序与标识（布局器共用，必须是纯函数）

    /// 条目次序：最近修改在前 → 标题 → id（全同的输入必得全同的图与排版）
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

    /// 一条记忆的全部可匹配别名（文件 basename、frontmatter name、标题）
    static func aliasKeys(of item: MemoryGraphInput.Item) -> [String] {
        var seen = Set<String>()
        return (item.aliases + [item.title])
            .map(normalizeKey)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// 链接匹配键：小写 + 去首尾空白 + `_` 视作 `-`。
    /// 后者是实勘出来的：文件名用下划线（`project_query_history.md`）而 frontmatter
    /// `name` 用连字符（`project-query-history`），同一条记忆两种写法都会被引用。
    public static func normalizeKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
