import Foundation

/// 一轮的**血缘图**：节点 = 提问/思考/工具/子代理/回答，边 = 因果与数据流。
///
/// 纯值类型 + 纯函数构图，放 EurekaKit（照 `IslandGeometry` 的先例）：
/// 无 IO、无 AppKit、结果可复现 ⇒ 能单测，也能被离屏渲染当作稳定基准。
public enum TurnGraph {
    // MARK: - 节点

    public enum NodeKind: Equatable, Sendable {
        case prompt
        /// 明文思考（Codex/Kimi/Qwen 有；Claude 落盘被剥离，不会出现）
        case thinking
        /// 结构性分叉/汇合点。两种情形插入：
        /// ①「一个节点 → 多个并行节点」且上游不是思考节点（标出一次看不见的决策）；
        /// ②「多 → 多」（否则边数是 N×M，插一个点降到 N+M）。
        case fork
        case tool(ToolKind)
        case subagent
        /// 同层同类兄弟过多时的聚合节点（`Read ×6`，可展开）
        case folded(ToolKind)
        case answer
        case error

        /// 排版用：折叠节点按被折叠的那类工具算宽
        public var toolKind: ToolKind? {
            switch self {
            case .tool(let kind), .folded(let kind): return kind
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
        /// 主标（Read / Grep / Explore / 回答）
        public var title: String
        /// 副标（目标摘要：a.swift / validateToken）
        public var subtitle: String
        /// 同一操作在本轮出现的次数（去重后的 ×N）
        public var occurrences: Int
        public var isError: Bool
        /// 首次出现序号。**这是拓扑序**：环打破、分层全靠它单调。
        public var seq: Int
        /// 跳消息锚点
        public var messageId: Int?
        /// 命中的原始步骤下标（详情条展开用）
        public var stepIndices: [Int]
        /// 折叠节点的成员
        public var foldedIDs: [NodeID]
        public var subagentType: String?

        public init(
            id: NodeID, kind: NodeKind, title: String, subtitle: String = "",
            occurrences: Int = 1, isError: Bool = false, seq: Int = 0,
            messageId: Int? = nil, stepIndices: [Int] = [], foldedIDs: [NodeID] = [],
            subagentType: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.subtitle = subtitle
            self.occurrences = occurrences
            self.isError = isError
            self.seq = seq
            self.messageId = messageId
            self.stepIndices = stepIndices
            self.foldedIDs = foldedIDs
            self.subagentType = subagentType
        }
    }

    // MARK: - 边

    public enum EdgeRole: String, Equatable, Sendable, CaseIterable {
        /// 因果推进
        case causal
        /// 回读同一文件 / 重复同一检索 —— 「上下文没一次给够」的证据
        case dataFlow
        /// 失败重试环 —— 「需求或验收标准不清」的证据
        case retry
        /// 改完又回去读 —— 「改之前没看清」的证据
        case rework
        /// 派生子代理
        case spawn

        public var label: String {
            switch self {
            case .causal: return "推进"
            case .dataFlow: return "回读"
            case .retry: return "重试"
            case .rework: return "返工"
            case .spawn: return "派生"
            }
        }
    }

    public struct Edge: Equatable, Sendable {
        public var from: NodeID
        public var to: NodeID
        public var role: EdgeRole
        /// 同一条边重复出现的次数（重试 ×3）
        public var repeatCount: Int
        /// 回边（指向更早的节点）。**由 `seq` 判定，构图期就定死**，
        /// 布局器据此把它摘出主图走专用边道。
        public var isBack: Bool

        public init(
            from: NodeID, to: NodeID, role: EdgeRole,
            repeatCount: Int = 1, isBack: Bool = false
        ) {
            self.from = from
            self.to = to
            self.role = role
            self.repeatCount = repeatCount
            self.isBack = isBack
        }
    }

    // MARK: - 图

    public struct Graph: Equatable, Sendable {
        public var turnIndex: Int
        public var promptMessageId: Int?
        /// 按 `seq` 升序
        public var nodes: [Node]
        public var edges: [Edge]
        /// 本轮是否拿得到思考明文（拿不到时 UI 要明说原因，而不是让用户以为没思考）
        public var hasThinking: Bool

        public init(
            turnIndex: Int, promptMessageId: Int? = nil,
            nodes: [Node] = [], edges: [Edge] = [], hasThinking: Bool = false
        ) {
            self.turnIndex = turnIndex
            self.promptMessageId = promptMessageId
            self.nodes = nodes
            self.edges = edges
            self.hasThinking = hasThinking
        }

        public func node(_ id: NodeID) -> Node? { nodes.first { $0.id == id } }
        public var forwardEdges: [Edge] { edges.filter { !$0.isBack } }
        public var backEdges: [Edge] { edges.filter(\.isBack) }
    }
}

// MARK: - 构图

/// `TurnInput` → `TurnGraph.Graph`。纯函数、确定性（同输入必得同输出）。
public enum TurnGraphBuilder {
    public struct Options: Equatable, Sendable {
        /// 每层最大列数（由 `TurnGraphLayout.Metrics` 按视口反推后传入）——折叠阈值的来源
        public var maxColumns: Int
        /// 展开的折叠组
        public var expandedFolds: Set<TurnGraph.NodeID>
        /// 展开的子代理（按 `subagent_type + description` 标识）。展开后子代理的内部步骤
        /// 会**并进同一张图**而不是画成嵌套子图 —— 因为最有价值的那条边
        /// （子代理去读了主流程已经读过的文件）正好跨越子图边界，
        /// 画成独立子图会把它剪掉。
        public var expandedSubagents: Set<String>
        /// 节点数硬上限，超了不排版直接降级
        public var maxNodes: Int

        public init(
            maxColumns: Int = 4, expandedFolds: Set<TurnGraph.NodeID> = [],
            expandedSubagents: Set<String> = [], maxNodes: Int = 120
        ) {
            self.maxColumns = maxColumns
            self.expandedFolds = expandedFolds
            self.expandedSubagents = expandedSubagents
            self.maxNodes = maxNodes
        }

        public static let standard = Options()
    }

    public static func build(
        _ turn: TurnInput, options: Options = .standard
    ) -> TurnGraph.Graph {
        var builder = Builder(turn: turn, options: options)
        return builder.run()
    }

    // MARK: - 内部状态机

    fileprivate struct Builder {
        let turn: TurnInput
        let options: Options

        var nodes: [TurnGraph.Node] = []
        var indexByID: [TurnGraph.NodeID: Int] = [:]
        /// 操作身份 → 节点。**去重的地基**：同一操作在一轮里只有一个节点。
        var nodeByIdentity: [String: TurnGraph.NodeID] = [:]
        /// canonicalTarget → 节点（回读/返工检测用，按 kind 分桶）
        var readNodeByTarget: [String: TurnGraph.NodeID] = [:]
        var editNodeByTarget: [String: TurnGraph.NodeID] = [:]
        /// (from, to, role) → 边下标，用于合并重复边并累加 repeatCount
        var edgeIndex: [String: Int] = [:]
        var edges: [TurnGraph.Edge] = []
        var seq = 0

        mutating func run() -> TurnGraph.Graph {
            var frontier: [TurnGraph.NodeID] = []

            if let promptId = turn.promptMessageId {
                frontier = [add(
                    kind: .prompt, title: "提问",
                    subtitle: summary(turn.promptText), messageId: promptId)]
            }

            // 思考在工具之前：模型先想再动手（Qwen/Kimi/Codex 的落盘顺序也如此）
            for text in turn.thinkingTexts {
                let node = add(kind: .thinking, title: "思考", subtitle: summary(text))
                connect(frontier, to: [node])
                frontier = [node]
            }

            for stage in stages() {
                // **先给分叉点预留 seq**：分叉在语义上先于它的分支发生，而
                // `seq` 单调即拓扑序是分层算法的地基 —— 如果等分支都建完再插分叉，
                // 分叉的 seq 会大于分支，分层时它的孩子找不到已定层的父节点，
                // 整层就会被错排到第 0 层。用不上的预留只是留个空号，无害。
                let forkSeq = reserveSeq()
                let produced = materialize(stage, frontier: frontier)
                guard !produced.isEmpty else { continue }
                frontier = connectStage(frontier, to: produced, forkSeq: forkSeq)
            }

            if !turn.answerMessageIds.isEmpty || !turn.answerText.isEmpty {
                let node = add(
                    kind: .answer, title: "回答", subtitle: summary(turn.answerText),
                    messageId: turn.answerMessageIds.first)
                connect(frontier, to: [node])
                frontier = [node]
            }
            for text in turn.errorTexts {
                let node = add(kind: .error, title: "错误", subtitle: summary(text), isError: true)
                connect(frontier, to: [node])
            }

            return TurnGraph.Graph(
                turnIndex: turn.turnIndex, promptMessageId: turn.promptMessageId,
                nodes: nodes, edges: edges, hasThinking: !turn.thinkingTexts.isEmpty)
        }

        // MARK: 阶段切分（同 batch = 同一次模型输出 = 真并行）

        func stages() -> [[TurnInput.Step]] {
            var result: [[TurnInput.Step]] = []
            for step in turn.steps {
                if let last = result.last, last[0].batch == step.batch {
                    result[result.count - 1].append(step)
                } else {
                    result.append([step])
                }
            }
            return result
        }

        /// 一个阶段 → 节点集合（含去重命中、折叠、以及回读/返工/重试回边）
        mutating func materialize(
            _ stage: [TurnInput.Step], frontier: [TurnGraph.NodeID]
        ) -> [TurnGraph.NodeID] {
            var produced: [TurnGraph.NodeID] = []
            for step in stage {
                let target = canonicalTarget(step)
                let identity = "\(step.kind.rawValue)|\(step.name)|\(target ?? "#\(step.stepIndex)")"

                if let existing = nodeByIdentity[identity] {
                    // 命中已有操作：不建新节点，只累计次数并连一条回边
                    bump(existing, step: step)
                    linkRevisit(existing, step: step, frontier: frontier)
                    produced.append(existing)
                    continue
                }

                let kind: TurnGraph.NodeKind = step.kind == .agent ? .subagent : .tool(step.kind)
                var subtitle = displaySubtitle(step)
                // 收起态的子代理把内部步数写在副标上：不点开也知道它干了多少活
                if step.kind == .agent, !step.subSteps.isEmpty,
                    !options.expandedSubagents.contains(subagentKey(step)) {
                    subtitle = subtitle.isEmpty
                        ? "\(step.subSteps.count) 步" : "\(subtitle) · \(step.subSteps.count) 步"
                }
                let node = add(
                    kind: kind, title: step.name, subtitle: subtitle,
                    isError: step.isError, messageId: step.messageId,
                    stepIndices: [step.stepIndex],
                    subagentType: step.kind == .agent ? step.name : nil)
                nodeByIdentity[identity] = node
                if let target {
                    switch step.kind {
                    case .read, .search: readNodeByTarget[target] = node
                    case .edit: editNodeByTarget[target] = node
                    default: break
                    }
                }
                linkNewStep(node, step: step)
                produced.append(node)

                // 展开的子代理：内部步骤**并进同一张图**，接在子代理节点之后。
                // 于是「子代理去读了主流程读过的文件」会自然命中去重、连出一条回读边 ——
                // 这正是把它做成内联而不是独立子图的理由。
                if step.kind == .agent, options.expandedSubagents.contains(subagentKey(step)) {
                    var branch = [node]
                    for stage in subStages(step.subSteps) {
                        // 与外层同理：分叉的 seq 必须**先**预留。放到分支建完再取，
                        // 分叉的 seq 会大于它的分支，那条边被判成回边、分支因此失去前向父节点，
                        // 表现为子代理读的文件被甩到第 0 层。
                        let forkSeq = reserveSeq()
                        let inner = materialize(stage, frontier: branch)
                        guard !inner.isEmpty else { continue }
                        branch = connectStage(branch, to: inner, forkSeq: forkSeq)
                    }
                    // **内部节点不进 produced**：它们已经从子代理节点连过边了，
                    // 再让外层 frontier 连一次会把它们错拉到子代理的同一层
                    // （表现为「子代理读的文件挂到了思考节点下」）。
                }
            }
            return fold(produced)
        }

        /// 子代理的步骤也按 batch 分阶段（同一批 = 它自己的并行调用）
        func subStages(_ steps: [TurnInput.Step]) -> [[TurnInput.Step]] {
            var result: [[TurnInput.Step]] = []
            for step in steps {
                if let last = result.last, last[0].batch == step.batch {
                    result[result.count - 1].append(step)
                } else {
                    result.append([step])
                }
            }
            return result
        }

        /// 子代理的稳定标识（类型 + 描述）。不用 callId：那是每次运行都变的。
        func subagentKey(_ step: TurnInput.Step) -> String {
            "\(step.name)|\(step.detail)"
        }

        /// 新建节点时的语义回边：返工 / 重试
        mutating func linkNewStep(_ node: TurnGraph.NodeID, step: TurnInput.Step) {
            guard let target = canonicalTarget(step) else { return }
            switch step.kind {
            case .read, .search:
                // 改完又回去读 ⇒ 改之前没看清
                if let edited = editNodeByTarget[target] {
                    addEdge(from: node, to: edited, role: .rework)
                }
            case .command where step.isError:
                addRetryEdge(from: node, target: target)
            default:
                break
            }
        }

        /// 命中已有节点时的语义回边：回读 / 重试
        mutating func linkRevisit(
            _ node: TurnGraph.NodeID, step: TurnInput.Step, frontier: [TurnGraph.NodeID]
        ) {
            switch step.kind {
            case .read, .search:
                // 回读同一文件/检索 ⇒ 上下文没一次给够
                for source in frontier where source != node {
                    addEdge(from: source, to: node, role: .dataFlow)
                }
            case .command where step.isError:
                if let target = canonicalTarget(step) {
                    addRetryEdge(from: node, target: target)
                }
            default:
                break
            }
        }

        /// 失败命令 → 最近一次编辑：构成「改→构建失败→再改」的重试环
        mutating func addRetryEdge(from node: TurnGraph.NodeID, target: String) {
            // 同文件优先（命令的 target 通常不是文件路径，退回最近一次编辑）
            let edited = editNodeByTarget[target] ?? lastEditNode()
            guard let edited, edited != node else { return }
            addEdge(from: node, to: edited, role: .retry)
        }

        func lastEditNode() -> TurnGraph.NodeID? {
            nodes.last { $0.kind == .tool(.edit) }?.id
        }

        // MARK: 折叠（层宽有上界的机制保证）

        mutating func fold(_ produced: [TurnGraph.NodeID]) -> [TurnGraph.NodeID] {
            guard produced.count > options.maxColumns else { return produced }
            // 按工具类别分组，只折同类；数量最多的那一类先折
            var byKind: [ToolKind: [TurnGraph.NodeID]] = [:]
            var others: [TurnGraph.NodeID] = []
            for id in produced {
                if let kind = self[id]?.kind.toolKind {
                    byKind[kind, default: []].append(id)
                } else {
                    others.append(id)
                }
            }
            var result = others
            for kind in byKind.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let group = byKind[kind]!
                // 只有超过 1 个、且当前仍然超宽才折；展开过的组不再折
                let foldID = TurnGraph.NodeID("fold.\(kind.rawValue).\(group[0].raw)")
                if group.count > 1, result.count + group.count > options.maxColumns,
                    !options.expandedFolds.contains(foldID) {
                    result.append(collapse(group, kind: kind, id: foldID))
                } else {
                    result.append(contentsOf: group)
                }
            }
            return result.sorted { (self[$0]?.seq ?? 0) < (self[$1]?.seq ?? 0) }
        }

        /// 把一组同类节点换成一个聚合节点（成员从 nodes 里摘掉，指向它们的边改指聚合体）
        mutating func collapse(
            _ group: [TurnGraph.NodeID], kind: ToolKind, id: TurnGraph.NodeID
        ) -> TurnGraph.NodeID {
            let members = group.compactMap { self[$0] }
            let seqs = members.map(\.seq)
            let folded = TurnGraph.Node(
                id: id, kind: .folded(kind),
                title: "\(kind.label) ×\(members.count)",
                subtitle: members.prefix(3).map(\.subtitle).filter { !$0.isEmpty }
                    .joined(separator: " / "),
                occurrences: members.reduce(0) { $0 + $1.occurrences },
                isError: members.contains(where: \.isError),
                seq: seqs.min() ?? seq,
                messageId: members.first?.messageId,
                stepIndices: members.flatMap(\.stepIndices).sorted(),
                foldedIDs: group)
            let removed = Set(group)
            nodes.removeAll { removed.contains($0.id) }
            nodes.append(folded)
            nodes.sort { $0.seq < $1.seq }
            reindex()
            // 边改指聚合体，并去掉自环
            for index in edges.indices {
                if removed.contains(edges[index].from) { edges[index].from = id }
                if removed.contains(edges[index].to) { edges[index].to = id }
            }
            edges.removeAll { $0.from == $0.to }
            rebuildEdgeIndex()
            for identity in nodeByIdentity.keys
            where removed.contains(nodeByIdentity[identity]!) {
                nodeByIdentity[identity] = id
            }
            return id
        }

        // MARK: 连边

        /// 阶段间连边。**多对多时插一个 fork 点**，把 N×M 条边降成 N+M 条 ——
        /// 这是边数有上界的机制保证，不是美化。
        mutating func connectStage(
            _ from: [TurnGraph.NodeID], to targets: [TurnGraph.NodeID], forkSeq: Int
        ) -> [TurnGraph.NodeID] {
            guard !from.isEmpty else { return targets }
            let sourceIsThinking = from.count == 1 && self[from[0]]?.kind == .thinking
            let needsFork = (from.count > 1 && targets.count > 1)
                || (targets.count > 1 && !sourceIsThinking)
            if needsFork {
                let fork = add(kind: .fork, title: "分叉", subtitle: "", at: forkSeq)
                connect(from, to: [fork])
                connect([fork], to: targets)
            } else {
                connect(from, to: targets)
            }
            return targets
        }

        mutating func connect(_ from: [TurnGraph.NodeID], to targets: [TurnGraph.NodeID]) {
            for source in from {
                for target in targets where source != target {
                    let role: TurnGraph.EdgeRole =
                        self[target]?.kind == .subagent ? .spawn : .causal
                    addEdge(from: source, to: target, role: role)
                }
            }
        }

        mutating func addEdge(
            from: TurnGraph.NodeID, to: TurnGraph.NodeID, role: TurnGraph.EdgeRole
        ) {
            guard from != to else { return }
            let key = "\(from.raw)->\(to.raw)|\(role.rawValue)"
            if let index = edgeIndex[key] {
                edges[index].repeatCount += 1
                return
            }
            // 回边判据：指向 seq 不更大的节点 = 回到已经做过的事
            let isBack = (self[to]?.seq ?? 0) <= (self[from]?.seq ?? 0)
            edgeIndex[key] = edges.count
            edges.append(TurnGraph.Edge(from: from, to: to, role: role, isBack: isBack))
        }

        mutating func rebuildEdgeIndex() {
            edgeIndex.removeAll(keepingCapacity: true)
            for (index, edge) in edges.enumerated() {
                edgeIndex["\(edge.from.raw)->\(edge.to.raw)|\(edge.role.rawValue)"] = index
            }
        }

        // MARK: 节点表维护

        subscript(id: TurnGraph.NodeID) -> TurnGraph.Node? {
            indexByID[id].map { nodes[$0] }
        }

        /// 取一个 seq 号（可先占后用；用不上就留个空号，seq 只需单调不需连续）
        mutating func reserveSeq() -> Int {
            defer { seq += 1 }
            return seq
        }

        /// `at` = 用预留的 seq（分叉点专用）；nil = 现取一个
        mutating func add(
            kind: TurnGraph.NodeKind, title: String, subtitle: String,
            isError: Bool = false, messageId: Int? = nil, stepIndices: [Int] = [],
            subagentType: String? = nil, at reserved: Int? = nil
        ) -> TurnGraph.NodeID {
            let value = reserved ?? reserveSeq()
            let id = TurnGraph.NodeID("n\(value)")
            nodes.append(TurnGraph.Node(
                id: id, kind: kind, title: title, subtitle: subtitle,
                isError: isError, seq: value, messageId: messageId,
                stepIndices: stepIndices, subagentType: subagentType))
            // 预留号插进来后要保持 nodes 按 seq 有序（分层与折叠都依赖这个顺序）
            if reserved != nil {
                nodes.sort { $0.seq < $1.seq }
                reindex()
            } else {
                indexByID[id] = nodes.count - 1
            }
            return id
        }

        mutating func bump(_ id: TurnGraph.NodeID, step: TurnInput.Step) {
            guard let index = indexByID[id] else { return }
            nodes[index].occurrences += 1
            nodes[index].stepIndices.append(step.stepIndex)
            if step.isError { nodes[index].isError = true }
        }

        mutating func reindex() {
            indexByID.removeAll(keepingCapacity: true)
            for (index, node) in nodes.enumerated() { indexByID[node.id] = index }
        }
    }
}

// MARK: - 操作身份与展示

extension TurnGraphBuilder {
    /// 操作的规范化目标：**节点去重的键**。
    /// 返回 nil = 这一步没有可比较的目标（如 TodoWrite），逐步骤独立成点。
    static func canonicalTarget(_ step: TurnInput.Step) -> String? {
        let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }
        switch step.kind {
        case .read, .edit:
            // 文件路径：去掉尾斜杠与重复分隔，让 `/a/b/` 与 `/a/b` 是同一个目标
            return normalizePath(detail)
        case .search, .web, .command, .mcp, .agent, .skill:
            return detail
        case .other:
            return nil
        }
    }

    static func normalizePath(_ raw: String) -> String {
        var path = raw
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// 节点副标：文件类只显末段（图里横向很贵），其余显摘要
    static func displaySubtitle(_ step: TurnInput.Step) -> String {
        switch step.kind {
        case .read, .edit:
            let path = normalizePath(step.detail)
            return path.split(separator: "/").last.map(String.init) ?? path
        default:
            return summary(step.detail)
        }
    }

    static func summary(_ text: String, limit: Int = 60) -> String {
        let line = text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit)) + "…"
    }
}

extension TurnGraphBuilder.Builder {
    func canonicalTarget(_ step: TurnInput.Step) -> String? {
        TurnGraphBuilder.canonicalTarget(step)
    }
    func displaySubtitle(_ step: TurnInput.Step) -> String {
        TurnGraphBuilder.displaySubtitle(step)
    }
    func summary(_ text: String) -> String { TurnGraphBuilder.summary(text) }
}
