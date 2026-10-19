import Foundation

/// The **lineage graph** of one turn: nodes = prompt / thinking / tool / subagent / answer,
/// edges = causality and data flow.
///
/// Pure value types + a pure-function builder, kept in EurekaKit (following `IslandGeometry`):
/// no IO, no AppKit, reproducible output ⇒ unit-testable, and a stable baseline for offscreen rendering.
public enum TurnGraph {
    // MARK: - Nodes

    public enum NodeKind: Equatable, Sendable {
        case prompt
        /// Plaintext thinking (Codex/Kimi/Qwen have it; Claude strips it when persisting, so it
        /// never appears)
        case thinking
        /// Structural fork/join point. Inserted in two cases:
        /// (1) "one node → several parallel nodes" when the upstream is not a thinking node (marks
        ///     a decision that is otherwise invisible);
        /// (2) "many → many" (otherwise the edge count is N×M; one inserted point brings it down to
        ///     N+M).
        case fork
        case tool(ToolKind)
        case subagent
        /// Aggregate node for too many same-kind siblings in one layer (`Read ×6`, expandable)
        case folded(ToolKind)
        case answer
        case error

        /// For layout: a folded node is sized by the tool kind it folds
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
        /// Main label (Read / Grep / Explore / Answer)
        public var title: String
        /// Secondary label (target summary: a.swift / validateToken)
        public var subtitle: String
        /// Times this operation occurs in the turn (the ×N after dedup)
        public var occurrences: Int
        public var isError: Bool
        /// First-occurrence sequence number. **This is the topological order**: cycle breaking and
        /// layering both rely on it being monotonic.
        public var seq: Int
        /// Anchor for jumping to the message
        public var messageId: Int?
        /// Indices of the raw steps this node matched (used when the detail bar expands)
        public var stepIndices: [Int]
        /// Members of a folded node
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

    // MARK: - Edges

    public enum EdgeRole: String, Equatable, Sendable, CaseIterable {
        /// Causal progress
        case causal
        /// Rereading the same file / repeating the same search -- evidence that "context wasn't
        /// given in one go"
        case dataFlow
        /// Failure retry loop -- evidence that "requirements or acceptance criteria are unclear"
        case retry
        /// Reading again after editing -- evidence that "it wasn't understood before editing"
        case rework
        /// Spawning a subagent
        case spawn

        public var label: String {
            switch self {
            case .causal: return L10n.text("Progress", zhHans: "推进")
            case .dataFlow: return L10n.text("Reread", zhHans: "回读")
            case .retry: return L10n.text("Retry", zhHans: "重试")
            case .rework: return L10n.text("Rework", zhHans: "返工")
            case .spawn: return L10n.text("Spawn", zhHans: "派生")
            }
        }
    }

    public struct Edge: Equatable, Sendable {
        public var from: NodeID
        public var to: NodeID
        public var role: EdgeRole
        /// How many times the same edge repeats (retry ×3)
        public var repeatCount: Int
        /// Back edge (points to an earlier node). **Decided from `seq`, fixed at build time**;
        /// the layout engine uses it to pull the edge out of the main graph onto a dedicated lane.
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

    // MARK: - Graph

    public struct Graph: Equatable, Sendable {
        public var turnIndex: Int
        public var promptMessageId: Int?
        /// Ascending by `seq`
        public var nodes: [Node]
        public var edges: [Edge]
        /// Whether this turn's thinking plaintext is available (when it isn't, the UI must say why
        /// instead of letting the user think there was no thinking)
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

// MARK: - Building

/// `TurnInput` → `TurnGraph.Graph`. Pure and deterministic (same input, same output).
public enum TurnGraphBuilder {
    public struct Options: Equatable, Sendable {
        /// Max columns per layer (derived from the viewport by `TurnGraphLayout.Metrics`) -- the
        /// source of the folding threshold
        public var maxColumns: Int
        /// Expanded fold groups
        public var expandedFolds: Set<TurnGraph.NodeID>
        /// Expanded subagents (keyed by `subagent_type + description`). Once expanded, a subagent's
        /// inner steps are **merged into the same graph** rather than drawn as a nested subgraph --
        /// because the most valuable edge (the subagent reading a file the main flow already read)
        /// crosses exactly that subgraph boundary, and a separate subgraph would cut it.
        public var expandedSubagents: Set<String>
        /// Hard cap on node count; above it, skip layout and degrade
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

    // MARK: - Internal state machine

    fileprivate struct Builder {
        let turn: TurnInput
        let options: Options

        var nodes: [TurnGraph.Node] = []
        var indexByID: [TurnGraph.NodeID: Int] = [:]
        /// Operation identity → node. **The foundation of dedup**: one operation has exactly one
        /// node per turn.
        var nodeByIdentity: [String: TurnGraph.NodeID] = [:]
        /// canonicalTarget → node (for reread/rework detection, bucketed by kind)
        var readNodeByTarget: [String: TurnGraph.NodeID] = [:]
        var editNodeByTarget: [String: TurnGraph.NodeID] = [:]
        /// (from, to, role) → edge index, used to merge duplicate edges and accumulate repeatCount
        var edgeIndex: [String: Int] = [:]
        var edges: [TurnGraph.Edge] = []
        var seq = 0

        mutating func run() -> TurnGraph.Graph {
            var frontier: [TurnGraph.NodeID] = []

            if let promptId = turn.promptMessageId {
                frontier = [add(
                    kind: .prompt, title: L10n.text("Prompt", zhHans: "提问"),
                    subtitle: summary(turn.promptText), messageId: promptId)]
            }

            // Thinking comes before tools: the model thinks, then acts (Qwen/Kimi/Codex persist in
            // this order too)
            for text in turn.thinkingTexts {
                let node = add(kind: .thinking, title: L10n.text("Thinking", zhHans: "思考"), subtitle: summary(text))
                connect(frontier, to: [node])
                frontier = [node]
            }

            for stage in stages() {
                // **Reserve the fork's seq first**: semantically a fork happens before its
                // branches, and monotonic `seq` == topological order is the foundation of layering
                // -- if the fork were inserted after the branches were built, its seq would exceed
                // theirs, its children would find no already-layered parent, and the whole layer
                // would be misplaced at layer 0. An unused reservation just leaves a gap; harmless.
                let forkSeq = reserveSeq()
                let produced = materialize(stage, frontier: frontier)
                guard !produced.isEmpty else { continue }
                frontier = connectStage(frontier, to: produced, forkSeq: forkSeq)
            }

            if !turn.answerMessageIds.isEmpty || !turn.answerText.isEmpty {
                let node = add(
                    kind: .answer, title: L10n.text("Answer", zhHans: "回答"), subtitle: summary(turn.answerText),
                    messageId: turn.answerMessageIds.first)
                connect(frontier, to: [node])
                frontier = [node]
            }
            for text in turn.errorTexts {
                let node = add(kind: .error, title: L10n.text("Error", zhHans: "错误"), subtitle: summary(text), isError: true)
                connect(frontier, to: [node])
            }

            return TurnGraph.Graph(
                turnIndex: turn.turnIndex, promptMessageId: turn.promptMessageId,
                nodes: nodes, edges: edges, hasThinking: !turn.thinkingTexts.isEmpty)
        }

        // MARK: Stage splitting (same batch = same model output = truly parallel)

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

        /// One stage → set of nodes (including dedup hits, folding, and reread/rework/retry back
        /// edges)
        mutating func materialize(
            _ stage: [TurnInput.Step], frontier: [TurnGraph.NodeID]
        ) -> [TurnGraph.NodeID] {
            var produced: [TurnGraph.NodeID] = []
            for step in stage {
                let target = canonicalTarget(step)
                let identity = "\(step.kind.rawValue)|\(step.name)|\(target ?? "#\(step.stepIndex)")"

                if let existing = nodeByIdentity[identity] {
                    // Hit an existing operation: no new node, just bump the count and add a back
                    // edge
                    bump(existing, step: step)
                    linkRevisit(existing, step: step, frontier: frontier)
                    produced.append(existing)
                    continue
                }

                let kind: TurnGraph.NodeKind = step.kind == .agent ? .subagent : .tool(step.kind)
                var subtitle = displaySubtitle(step)
                // A collapsed subagent shows its inner step count in the subtitle: you see how much
                // work it did without expanding it
                if step.kind == .agent, !step.subSteps.isEmpty,
                    !options.expandedSubagents.contains(subagentKey(step)) {
                    subtitle = subtitle.isEmpty
                        ? L10n.format("%@ steps", zhHans: "%@ 步", String(step.subSteps.count))
                        : L10n.format("%@ · %@ steps", zhHans: "%@ · %@ 步", subtitle, String(step.subSteps.count))
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

                // Expanded subagent: inner steps are **merged into the same graph**, after the
                // subagent node. So "the subagent read a file the main flow already read" naturally
                // hits dedup and yields a reread edge -- which is exactly why it is inlined instead
                // of drawn as a separate subgraph.
                if step.kind == .agent, options.expandedSubagents.contains(subagentKey(step)) {
                    var branch = [node]
                    for stage in subStages(step.subSteps) {
                        // Same as the outer loop: the fork's seq must be reserved **first**. Taking
                        // it after the branch is built makes the fork's seq larger than its branch,
                        // the edge gets classified as a back edge, the branch loses its forward
                        // parent, and the files the subagent read get thrown to layer 0.
                        let forkSeq = reserveSeq()
                        let inner = materialize(stage, frontier: branch)
                        guard !inner.isEmpty else { continue }
                        branch = connectStage(branch, to: inner, forkSeq: forkSeq)
                    }
                    // **Inner nodes do not go into produced**: they are already connected from the
                    // subagent node; connecting them again from the outer frontier would wrongly
                    // pull them into the subagent's layer (showing up as "files the subagent read
                    // hang under the thinking node").
                }
            }
            return fold(produced)
        }

        /// Subagent steps are also staged by batch (same batch = its own parallel calls)
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

        /// Stable subagent key (type + description). Not callId: that changes on every run.
        func subagentKey(_ step: TurnInput.Step) -> String {
            "\(step.name)|\(step.detail)"
        }

        /// Semantic back edges for a newly created node: rework / retry
        mutating func linkNewStep(_ node: TurnGraph.NodeID, step: TurnInput.Step) {
            guard let target = canonicalTarget(step) else { return }
            switch step.kind {
            case .read, .search:
                // Reading again after editing ⇒ it wasn't understood before editing
                if let edited = editNodeByTarget[target] {
                    addEdge(from: node, to: edited, role: .rework)
                }
            case .command where step.isError:
                addRetryEdge(from: node, target: target)
            default:
                break
            }
        }

        /// Semantic back edges when an existing node is hit: reread / retry
        mutating func linkRevisit(
            _ node: TurnGraph.NodeID, step: TurnInput.Step, frontier: [TurnGraph.NodeID]
        ) {
            switch step.kind {
            case .read, .search:
                // Rereading the same file/search ⇒ context wasn't given in one go
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

        /// Failed command → most recent edit: forms the "edit → build fails → edit again" retry
        /// loop
        mutating func addRetryEdge(from node: TurnGraph.NodeID, target: String) {
            // Same file first (a command's target is usually not a file path, so fall back to the
            // latest edit)
            let edited = editNodeByTarget[target] ?? lastEditNode()
            guard let edited, edited != node else { return }
            addEdge(from: node, to: edited, role: .retry)
        }

        func lastEditNode() -> TurnGraph.NodeID? {
            nodes.last { $0.kind == .tool(.edit) }?.id
        }

        // MARK: Folding (the mechanism that bounds layer width)

        mutating func fold(_ produced: [TurnGraph.NodeID]) -> [TurnGraph.NodeID] {
            guard produced.count > options.maxColumns else { return produced }
            // Group by tool kind and fold only within a kind; the largest kind folds first
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
                // Fold only groups of more than 1 while the layer is still too wide; expanded
                // groups never fold again
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

        /// Replace a group of same-kind nodes with one aggregate node (members are removed from
        /// nodes, edges pointing at them are redirected to the aggregate)
        mutating func collapse(
            _ group: [TurnGraph.NodeID], kind: ToolKind, id: TurnGraph.NodeID
        ) -> TurnGraph.NodeID {
            let members = group.compactMap { self[$0] }
            let seqs = members.map(\.seq)
            let folded = TurnGraph.Node(
                id: id, kind: .folded(kind),
                title: L10n.format("%@ ×%@", zhHans: "%@ ×%@", kind.label, String(members.count)),
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
            // Redirect edges to the aggregate and drop self-loops
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

        // MARK: Edges

        /// Edges between stages. **For many-to-many, insert a fork point**, reducing N×M edges to
        /// N+M -- this is the mechanism that bounds edge count, not cosmetics.
        mutating func connectStage(
            _ from: [TurnGraph.NodeID], to targets: [TurnGraph.NodeID], forkSeq: Int
        ) -> [TurnGraph.NodeID] {
            guard !from.isEmpty else { return targets }
            let sourceIsThinking = from.count == 1 && self[from[0]]?.kind == .thinking
            let needsFork = (from.count > 1 && targets.count > 1)
                || (targets.count > 1 && !sourceIsThinking)
            if needsFork {
                let fork = add(kind: .fork, title: L10n.text("Fork", zhHans: "分叉"), subtitle: "", at: forkSeq)
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
            // Back-edge test: pointing at a node whose seq is not larger = returning to something
            // already done
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

        // MARK: Node table maintenance

        subscript(id: TurnGraph.NodeID) -> TurnGraph.Node? {
            indexByID[id].map { nodes[$0] }
        }

        /// Take a seq number (can be reserved before use; an unused one just leaves a gap -- seq
        /// only needs to be monotonic, not contiguous)
        mutating func reserveSeq() -> Int {
            defer { seq += 1 }
            return seq
        }

        /// `at` = use a reserved seq (fork points only); nil = take a fresh one
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
            // After inserting a reserved number, keep nodes sorted by seq (layering and folding
            // depend on this order)
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

// MARK: - Operation identity and display

extension TurnGraphBuilder {
    /// Canonical target of an operation: **the node dedup key**.
    /// nil = this step has no comparable target (e.g. TodoWrite), so each step gets its own node.
    static func canonicalTarget(_ step: TurnInput.Step) -> String? {
        let detail = step.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !detail.isEmpty else { return nil }
        switch step.kind {
        case .read, .edit:
            // File path: strip trailing slashes and repeated separators so `/a/b/` and `/a/b` are
            // the same target
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

    /// Node subtitle: files show only the last path component (horizontal space is expensive in the
    /// graph), everything else shows a summary
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
