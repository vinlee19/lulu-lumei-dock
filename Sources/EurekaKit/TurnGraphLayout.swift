import CoreGraphics
import Foundation

/// Lineage-graph layout engine: `TurnGraph.Graph` → node rects + edge polylines.
///
/// Pure functions, no AppKit (following `IslandGeometry`), so invariants like "edges never cross nodes"
/// are unit-testable and offscreen rendering gets a **reproducible** baseline -- force-directed layout
/// can do neither, which is why it wasn't chosen.
///
/// Four steps (all single-pass O(V+E), no recursion):
///  1. **Cycle breaking**: monotonic `seq` is the topological order; a back edge points to a node
///     that is not later. That is decided at build time; here back edges are only pulled out of the
///     main graph onto dedicated lanes, **never reversed back into the DAG**.
///  2. **Layering**: longest-path, one pass in ascending `seq` (predecessors are always layered
///     already). Edges spanning >1 layer get dummy placeholders -- the **structural** guarantee
///     that edges never cross nodes, not after-the-fact avoidance.
///  3. **In-layer ordering**: 4 median sweeps to reduce crossings. A fixed sweep count ⇒ bounded
///     cost, no degeneration.
///  4. **Coordinates**: max columns per layer are derived from the viewport (so layer width is
///     bounded and nothing is ever clipped horizontally).
///
/// Every edge is an **orthogonal polyline**: horizontal segments run only along the middle of the gutter
/// between layers, which by definition holds no nodes, so "never crosses a node" is provable; Bezier
/// control points rely on heuristics and can only be detected and retried after the fact.
public enum TurnGraphLayout {
    // MARK: - Metrics

    public struct Metrics: Equatable, Sendable {
        /// Viewport width (from GeometryReader)
        public var canvasWidth: CGFloat
        public var nodeHeight: CGFloat = 30
        public var layerGap: CGFloat = 34
        public var columnGap: CGFloat = 14
        public var minNodeWidth: CGFloat = 92
        public var maxNodeWidth: CGFloat = 156
        /// Half-width character advance (10.5pt SF ≈ 5.8). EurekaKit can't use CoreText, so widths
        /// are estimated.
        public var charWidth: CGFloat = 5.8
        public var nodePadding: CGFloat = 18
        /// Spacing between back-edge lanes
        public var backLaneGap: CGFloat = 11
        public var maxLanesPerSide: Int = 3
        public var orderingSweeps: Int = 4
        public var maxNodes: Int = 120
        public var margin: CGFloat = 12

        public init(canvasWidth: CGFloat) { self.canvasWidth = canvasWidth }

        public static func standard(width: CGFloat) -> Metrics { Metrics(canvasWidth: width) }

        /// Compact preset: the same graph in a narrower viewport (shorter, narrower nodes, hence
        /// more columns)
        public static func compact(width: CGFloat) -> Metrics {
            var metrics = Metrics(canvasWidth: width)
            metrics.nodeHeight = 24
            metrics.layerGap = 24
            metrics.columnGap = 10
            metrics.minNodeWidth = 70
            metrics.maxNodeWidth = 118
            metrics.nodePadding = 12
            return metrics
        }

        /// Total width taken by the back-edge lanes on both sides
        public var laneReserve: CGFloat { backLaneGap * CGFloat(maxLanesPerSide) * 2 }

        /// **Max columns per layer**: the sole source of the folding threshold. Layer width is
        /// therefore bounded ⇒ never clipped horizontally.
        public var maxColumns: Int {
            let usable = canvasWidth - laneReserve - margin * 2
            let perColumn = maxNodeWidth + columnGap
            let raw = Int(((usable + columnGap) / perColumn).rounded(.down))
            return min(6, max(3, raw))
        }
    }

    // MARK: - Output

    public struct PlacedNode: Equatable, Sendable, Identifiable {
        /// Origin at top-left, matching SwiftUI's coordinate system
        public var frame: CGRect
        public var layer: Int
        public var column: Int
        public var node: TurnGraph.Node
        public var id: TurnGraph.NodeID { node.id }
    }

    public struct RoutedEdge: Equatable, Sendable {
        public var from: TurnGraph.NodeID
        public var to: TurnGraph.NodeID
        /// Polyline vertices (≥2, including the start/end points on the node edges)
        public var points: [CGPoint]
        public var arrowTip: CGPoint
        /// Arrow direction (unit vector)
        public var arrowDirection: CGVector
        public var role: TurnGraph.EdgeRole
        public var isBack: Bool
        /// Back-edge lane index; nil = routed through the gutter
        public var laneIndex: Int?
        /// Badge on the edge ("×3")
        public var badge: String?
    }

    public enum Degradation: Equatable, Sendable {
        /// Too many nodes, no layout (the caller falls back to the step list)
        case tooManyNodes(count: Int, limit: Int)
        /// Layer width still exceeds the column cap after folding (the caller falls back to a
        /// layered timeline)
        case tooWide(maxLayerWidth: Int, columns: Int)
    }

    public struct Result: Equatable, Sendable {
        public var nodes: [PlacedNode]
        public var edges: [RoutedEdge]
        public var canvasSize: CGSize
        public var layerCount: Int
        public var maxLayerWidth: Int
        public var crossings: Int
        public var degraded: Degradation?
        /// Back edges degraded to badges because lanes ran out: target node → badge text
        public var overflowBadges: [TurnGraph.NodeID: [String]]

        public init(
            nodes: [PlacedNode] = [], edges: [RoutedEdge] = [],
            canvasSize: CGSize = .zero, layerCount: Int = 0, maxLayerWidth: Int = 0,
            crossings: Int = 0, degraded: Degradation? = nil,
            overflowBadges: [TurnGraph.NodeID: [String]] = [:]
        ) {
            self.nodes = nodes
            self.edges = edges
            self.canvasSize = canvasSize
            self.layerCount = layerCount
            self.maxLayerWidth = maxLayerWidth
            self.crossings = crossings
            self.degraded = degraded
            self.overflowBadges = overflowBadges
        }
    }

    // MARK: - Entry point

    public static func layout(_ graph: TurnGraph.Graph, metrics: Metrics) -> Result {
        guard !graph.nodes.isEmpty else { return Result() }
        guard graph.nodes.count <= metrics.maxNodes else {
            return Result(degraded: .tooManyNodes(
                count: graph.nodes.count, limit: metrics.maxNodes))
        }
        var engine = Engine(graph: graph, metrics: metrics)
        return engine.run()
    }

    // MARK: - Engine

    private struct Engine {
        let graph: TurnGraph.Graph
        let metrics: Metrics

        /// Layout unit: a real node or a dummy placeholder (a dummy only reserves a column slot so
        /// edges never cross nodes)
        struct Cell {
            var id: TurnGraph.NodeID
            var isDummy: Bool
            var layer: Int
            var order: Int = 0
            var width: CGFloat
            var x: CGFloat = 0
            /// Which edge a dummy belongs to (chained in order during routing)
            var edgeKey: String?
        }

        var cells: [Cell] = []
        var indexByID: [TurnGraph.NodeID: Int] = [:]
        var layerOf: [TurnGraph.NodeID: Int] = [:]
        /// Edges of the layered graph (including segments split by dummies)
        var segments: [(from: TurnGraph.NodeID, to: TurnGraph.NodeID)] = []
        /// Original forward edge → the dummy chain it was split into
        var dummyChain: [String: [TurnGraph.NodeID]] = [:]

        init(graph: TurnGraph.Graph, metrics: Metrics) {
            self.graph = graph
            self.metrics = metrics
        }

        mutating func run() -> Result {
            assignLayers()
            insertDummies()
            orderLayers()
            assignCoordinates()

            let placed = placedNodes()
            let (routed, overflow) = routeEdges(placed)
            let height = CGFloat(layerBuckets().count)
                * (metrics.nodeHeight + metrics.layerGap) - metrics.layerGap
            let canvas = CGSize(
                width: metrics.canvasWidth,
                height: max(metrics.nodeHeight, height) + metrics.margin * 2)
            // **Count real nodes only**: dummies are just placeholders so edges never cross nodes;
            // counting them in layer width would report "too wide" when everything actually fits.
            let realWidths = layerBuckets().map { bucket in
                bucket.filter { self[$0]?.isDummy == false }.count
            }
            let maxWidth = realWidths.max() ?? 0
            return Result(
                nodes: placed, edges: routed, canvasSize: canvas,
                layerCount: layerBuckets().count, maxLayerWidth: maxWidth,
                crossings: countCrossings(),
                degraded: overflowingLayer().map {
                    .tooWide(maxLayerWidth: $0, columns: metrics.maxColumns)
                },
                overflowBadges: overflow)
        }

        // MARK: Steps 1+2 · Layering (one pass in ascending seq; predecessors are always layered already)

        mutating func assignLayers() {
            var incoming: [TurnGraph.NodeID: [TurnGraph.NodeID]] = [:]
            for edge in graph.forwardEdges {
                incoming[edge.to, default: []].append(edge.from)
            }
            for node in graph.nodes.sorted(by: { $0.seq < $1.seq }) {
                let parents = incoming[node.id] ?? []
                let layer = parents.compactMap { layerOf[$0] }.max().map { $0 + 1 } ?? 0
                layerOf[node.id] = layer
            }
            for node in graph.nodes.sorted(by: { $0.seq < $1.seq }) {
                cells.append(Cell(
                    id: node.id, isDummy: false, layer: layerOf[node.id] ?? 0,
                    width: nodeWidth(node)))
            }
            reindex()
        }

        /// Split forward edges spanning >1 layer into per-layer segments, with one dummy in each
        /// layer between
        mutating func insertDummies() {
            var counter = 0
            for edge in graph.forwardEdges {
                guard let from = layerOf[edge.from], let to = layerOf[edge.to] else { continue }
                let key = edgeKey(edge)
                if to - from <= 1 {
                    segments.append((edge.from, edge.to))
                    continue
                }
                var previous = edge.from
                var chain: [TurnGraph.NodeID] = []
                for layer in (from + 1)..<to {
                    let id = TurnGraph.NodeID("dummy.\(counter)")
                    counter += 1
                    cells.append(Cell(
                        id: id, isDummy: true, layer: layer,
                        width: 10, edgeKey: key))
                    layerOf[id] = layer
                    chain.append(id)
                    segments.append((previous, id))
                    previous = id
                }
                segments.append((previous, edge.to))
                dummyChain[key] = chain
            }
            reindex()
        }

        // MARK: Step 3 · In-layer ordering (fixed 4 median sweeps, bounded cost)

        mutating func orderLayers() {
            // Initial order = seq order (chronological, already very good on this kind of topology)
            for bucket in layerBuckets() {
                for (order, id) in bucket.enumerated() { setOrder(id, order) }
            }
            var best = snapshotOrders()
            var bestCrossings = countCrossings()
            for sweep in 0..<metrics.orderingSweeps {
                let downward = sweep % 2 == 0
                medianSweep(downward: downward)
                let crossings = countCrossings()
                if crossings < bestCrossings {
                    bestCrossings = crossings
                    best = snapshotOrders()
                }
            }
            restoreOrders(best)
        }

        mutating func medianSweep(downward: Bool) {
            let buckets = layerBuckets()
            let range = downward
                ? Array(buckets.indices) : Array(buckets.indices.reversed())
            for layerIndex in range {
                let bucket = buckets[layerIndex]
                guard bucket.count > 1 else { continue }
                let medians = bucket.map { id -> (TurnGraph.NodeID, Double) in
                    let neighbours = downward ? predecessors(id) : successors(id)
                    let orders = neighbours.compactMap { self[$0]?.order }.sorted()
                    guard !orders.isEmpty else {
                        return (id, Double(self[id]?.order ?? 0))
                    }
                    let middle = orders.count / 2
                    let median = orders.count % 2 == 1
                        ? Double(orders[middle])
                        : Double(orders[middle - 1] + orders[middle]) / 2
                    return (id, median)
                }
                // Stable sort: equal medians keep their original order (guarantees determinism)
                let sorted = medians.enumerated()
                    .sorted { lhs, rhs in
                        lhs.element.1 == rhs.element.1
                            ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1
                    }
                    .map(\.element.0)
                for (order, id) in sorted.enumerated() { setOrder(id, order) }
            }
        }

        // MARK: Step 4 · Coordinates

        mutating func assignCoordinates() {
            let laneReserve = metrics.backLaneGap * CGFloat(metrics.maxLanesPerSide)
            let left = metrics.margin + laneReserve
            let right = metrics.canvasWidth - metrics.margin - laneReserve

            for bucket in layerBuckets() {
                // Lay out at minimum spacing first, then center the whole layer
                var total: CGFloat = 0
                for id in bucket { total += (self[id]?.width ?? 0) + metrics.columnGap }
                total -= metrics.columnGap
                var cursor = max(left, (left + right - total) / 2)
                for id in bucket {
                    setX(id, cursor)
                    cursor += (self[id]?.width ?? 0) + metrics.columnGap
                }
            }
            // 2 passes of "move toward the neighbours' median x", subject to no overlap
            for _ in 0..<2 { alignToNeighbours(left: left, right: right) }
        }

        mutating func alignToNeighbours(left: CGFloat, right: CGFloat) {
            for bucket in layerBuckets() {
                var desired: [(TurnGraph.NodeID, CGFloat)] = []
                for id in bucket {
                    let neighbours = predecessors(id) + successors(id)
                    let centers = neighbours.compactMap { neighbour -> CGFloat? in
                        guard let cell = self[neighbour] else { return nil }
                        return cell.x + cell.width / 2
                    }
                    guard !centers.isEmpty, let cell = self[id] else {
                        desired.append((id, self[id]?.x ?? 0))
                        continue
                    }
                    let target = centers.reduce(0, +) / CGFloat(centers.count) - cell.width / 2
                    desired.append((id, target))
                }
                // One left-to-right sweep guarantees no overlap and no overflow past the bounds
                var cursor = left
                for (id, target) in desired {
                    guard let cell = self[id] else { continue }
                    let x = min(max(target, cursor), right - cell.width)
                    setX(id, max(x, cursor))
                    cursor = max(x, cursor) + cell.width + metrics.columnGap
                }
                // The non-overlap sweep is **left-anchored**: when 3 siblings all want the parent's
                // center line, the first takes it and the rest are pushed right, skewing the whole
                // layer. So after the sweep, shift the layer back to the target center.
                recenter(bucket, desired: desired, left: left, right: right)
            }
        }

        /// Shift a whole layer so its bounding-box center matches the mean of the nodes' desired
        /// centers (clamped to the left/right bounds)
        mutating func recenter(
            _ bucket: [TurnGraph.NodeID], desired: [(TurnGraph.NodeID, CGFloat)],
            left: CGFloat, right: CGFloat
        ) {
            guard bucket.count > 1 else { return }
            let placedCenters = bucket.compactMap { id -> (CGFloat, CGFloat)? in
                guard let cell = self[id] else { return nil }
                return (cell.x, cell.x + cell.width)
            }
            guard let minX = placedCenters.map(\.0).min(),
                let maxX = placedCenters.map(\.1).max()
            else { return }
            let wantCenters = desired.compactMap { id, target -> CGFloat? in
                guard let cell = self[id] else { return nil }
                return target + cell.width / 2
            }
            guard !wantCenters.isEmpty else { return }
            let wantCenter = wantCenters.reduce(0, +) / CGFloat(wantCenters.count)
            var shift = wantCenter - (minX + maxX) / 2
            shift = max(shift, left - minX)
            shift = min(shift, right - maxX)
            guard abs(shift) > 0.01 else { return }
            for id in bucket {
                guard let cell = self[id] else { continue }
                setX(id, cell.x + shift)
            }
        }

        // MARK: Output

        func placedNodes() -> [PlacedNode] {
            cells.filter { !$0.isDummy }.compactMap { cell in
                guard let node = graph.node(cell.id) else { return nil }
                return PlacedNode(
                    frame: CGRect(
                        x: cell.x, y: layerY(cell.layer),
                        width: cell.width, height: metrics.nodeHeight),
                    layer: cell.layer, column: cell.order, node: node)
            }
        }

        /// Whether any layer **really** doesn't fit (required width exceeds the usable width).
        /// Measure width directly instead of counting columns: column count is only a proxy for the
        /// folding threshold; what actually hurts the user is nodes being clipped horizontally.
        /// Returns that layer's real node count.
        func overflowingLayer() -> Int? {
            let laneReserve = metrics.backLaneGap * CGFloat(metrics.maxLanesPerSide)
            let usable = metrics.canvasWidth - metrics.margin * 2 - laneReserve * 2
            for bucket in layerBuckets() {
                let real = bucket.filter { self[$0]?.isDummy == false }
                guard real.count > 1 else { continue }
                let required = real.reduce(CGFloat(0)) { $0 + (self[$1]?.width ?? 0) }
                    + CGFloat(real.count - 1) * metrics.columnGap
                if required > usable { return real.count }
            }
            return nil
        }

        func layerY(_ layer: Int) -> CGFloat {
            metrics.margin + CGFloat(layer) * (metrics.nodeHeight + metrics.layerGap)
        }

        /// Middle of the gutter between layers: **horizontal segments run only along this line**,
        /// which by definition holds no nodes ⇒ never crossing a node is provable
        func gutterY(below layer: Int) -> CGFloat {
            layerY(layer) + metrics.nodeHeight + metrics.layerGap / 2
        }

        func rect(_ id: TurnGraph.NodeID) -> CGRect? {
            guard let cell = self[id] else { return nil }
            return CGRect(
                x: cell.x, y: layerY(cell.layer),
                width: cell.width, height: metrics.nodeHeight)
        }

        // MARK: Edge routing

        func routeEdges(
            _ placed: [PlacedNode]
        ) -> ([RoutedEdge], [TurnGraph.NodeID: [String]]) {
            var routed: [RoutedEdge] = []
            for edge in graph.forwardEdges {
                guard let points = forwardPoints(edge) else { continue }
                routed.append(makeEdge(edge, points: points, lane: nil))
            }

            // Back-edge lanes hug the outside of the **node bounding box**, not the outermost
            // canvas edge -- hugging the canvas edge would draw every loop as a big rectangle
            // across the whole graph, hiding what it actually connects.
            let bounds = (
                minX: placed.map(\.frame.minX).min() ?? metrics.margin,
                maxX: placed.map(\.frame.maxX).max() ?? metrics.canvasWidth - metrics.margin)

            // Greedy lane assignment by y interval (overlapping ones get different lanes); when
            // lanes run out, degrade to a badge
            var overflow: [TurnGraph.NodeID: [String]] = [:]
            var laneEnds: [CGFloat] = []
            let backEdges = graph.backEdges.sorted { lhs, rhs in
                (span(lhs)?.minY ?? 0) < (span(rhs)?.minY ?? 0)
            }
            for edge in backEdges {
                guard let interval = span(edge) else { continue }
                var lane = laneEnds.firstIndex { $0 <= interval.minY }
                if lane == nil, laneEnds.count < metrics.maxLanesPerSide {
                    laneEnds.append(0)
                    lane = laneEnds.count - 1
                }
                guard let laneIndex = lane else {
                    let layer = layerOf[edge.to].map {
                        L10n.format("layer %@", zhHans: "第 %@ 层", String($0 + 1))
                    } ?? L10n.text("upstream", zhHans: "上游")
                    let times = edge.repeatCount > 1 ? " ×\(edge.repeatCount)" : ""
                    overflow[edge.to, default: []].append(L10n.format(
                        "↩︎ %@ to %@%@", zhHans: "↩︎ %@%@%@", edge.role.label, layer, times))
                    continue
                }
                laneEnds[laneIndex] = interval.maxY
                guard let points = backPoints(edge, lane: laneIndex, bounds: bounds)
                else { continue }
                routed.append(makeEdge(edge, points: points, lane: laneIndex))
            }
            return (routed, overflow)
        }

        func makeEdge(
            _ edge: TurnGraph.Edge, points: [CGPoint], lane: Int?
        ) -> RoutedEdge {
            let tip = points[points.count - 1]
            let previous = points[points.count - 2]
            let dx = tip.x - previous.x
            let dy = tip.y - previous.y
            let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
            return RoutedEdge(
                from: edge.from, to: edge.to, points: points, arrowTip: tip,
                arrowDirection: CGVector(dx: dx / length, dy: dy / length),
                role: edge.role, isBack: edge.isBack, laneIndex: lane,
                badge: edge.repeatCount > 1 ? "×\(edge.repeatCount)" : nil)
        }

        /// Forward edge: down to the gutter middle → horizontal → down to the target's top edge
        /// (chained segment by segment through dummies)
        func forwardPoints(_ edge: TurnGraph.Edge) -> [CGPoint]? {
            let chain = dummyChain[edgeKey(edge)] ?? []
            let ids = [edge.from] + chain + [edge.to]
            var points: [CGPoint] = []
            for index in 0..<(ids.count - 1) {
                guard let from = rect(ids[index]), let to = rect(ids[index + 1]),
                    let fromLayer = layerOf[ids[index]]
                else { return nil }
                let gutter = gutterY(below: fromLayer)
                let start = CGPoint(x: from.midX, y: from.maxY)
                let end = CGPoint(x: to.midX, y: to.minY)
                if points.isEmpty { points.append(start) }
                // **Always route through the gutter**: don't connect directly when x is "close
                // enough", or sub-pixel drift produces diagonal lines, and once a diagonal appears
                // the proof "horizontal segments only in the gutter ⇒ never crosses a node" no
                // longer holds. Redundant collinear points are merged by simplify.
                points.append(CGPoint(x: start.x, y: gutter))
                points.append(CGPoint(x: end.x, y: gutter))
                points.append(end)
            }
            let cleaned = Engine.simplify(points)
            return cleaned.count >= 2 ? cleaned : nil
        }

        /// Drop duplicate points and merge collinear segments (guarantees every segment is strictly
        /// horizontal or vertical)
        static func simplify(_ raw: [CGPoint]) -> [CGPoint] {
            var points: [CGPoint] = []
            for point in raw {
                if let last = points.last,
                    abs(last.x - point.x) < 0.001, abs(last.y - point.y) < 0.001 {
                    continue
                }
                // If collinear with the previous two points, replace the middle one
                if points.count >= 2 {
                    let a = points[points.count - 2]
                    let b = points[points.count - 1]
                    let sameX = abs(a.x - b.x) < 0.001 && abs(b.x - point.x) < 0.001
                    let sameY = abs(a.y - b.y) < 0.001 && abs(b.y - point.y) < 0.001
                    if sameX || sameY { points.removeLast() }
                }
                points.append(point)
            }
            return points
        }

        /// Back edge: down to the gutter → across to the lane → vertically along the lane → across
        /// to the gutter above the target → down into the target. Horizontal segments are all in
        /// gutters and vertical segments lie outside the nodes' x range ⇒ likewise never crosses a
        /// node.
        func backPoints(
            _ edge: TurnGraph.Edge, lane: Int, bounds: (minX: CGFloat, maxX: CGFloat)
        ) -> [CGPoint]? {
            guard let from = rect(edge.from), let to = rect(edge.to),
                let fromLayer = layerOf[edge.from], let toLayer = layerOf[edge.to]
            else { return nil }
            // Left lane = data reread, right lane = retry/rework: the two failure modes are split
            // left/right so they are distinguishable at a glance
            let onLeft = edge.role == .dataFlow
            let offset = metrics.backLaneGap * CGFloat(lane + 1)
            let laneX = onLeft
                ? max(metrics.margin, bounds.minX - offset)
                : min(metrics.canvasWidth - metrics.margin, bounds.maxX + offset)
            let exitY = gutterY(below: fromLayer)
            // Target above: enter from the gutter of the layer above it; a target in layer 0 is
            // entered from the gutter under it
            let enterY = toLayer > 0
                ? gutterY(below: toLayer - 1) : layerY(0) - metrics.layerGap / 2
            return Engine.simplify([
                CGPoint(x: from.midX, y: from.maxY),
                CGPoint(x: from.midX, y: exitY),
                CGPoint(x: laneX, y: exitY),
                CGPoint(x: laneX, y: enterY),
                CGPoint(x: to.midX, y: enterY),
                CGPoint(x: to.midX, y: to.minY),
            ])
        }

        func span(_ edge: TurnGraph.Edge) -> (minY: CGFloat, maxY: CGFloat)? {
            guard let from = rect(edge.from), let to = rect(edge.to) else { return nil }
            return (min(from.minY, to.minY), max(from.maxY, to.maxY))
        }

        // MARK: Crossing count (an assertable measure of ordering quality)

        func countCrossings() -> Int {
            var total = 0
            let buckets = layerBuckets()
            guard buckets.count > 1 else { return 0 }
            for index in 0..<(buckets.count - 1) {
                var pairs: [(Int, Int)] = []
                for id in buckets[index] {
                    guard let upper = self[id]?.order else { continue }
                    for child in successors(id) {
                        guard layerOf[child] == index + 1, let lower = self[child]?.order
                        else { continue }
                        pairs.append((upper, lower))
                    }
                }
                for i in 0..<max(0, pairs.count) {
                    for j in (i + 1)..<max(0, pairs.count) where
                        (pairs[i].0 - pairs[j].0) * (pairs[i].1 - pairs[j].1) < 0 {
                        total += 1
                    }
                }
            }
            return total
        }

        // MARK: Table maintenance

        subscript(id: TurnGraph.NodeID) -> Cell? {
            indexByID[id].map { cells[$0] }
        }

        mutating func reindex() {
            indexByID.removeAll(keepingCapacity: true)
            for (index, cell) in cells.enumerated() { indexByID[cell.id] = index }
        }

        mutating func setOrder(_ id: TurnGraph.NodeID, _ order: Int) {
            guard let index = indexByID[id] else { return }
            cells[index].order = order
        }

        mutating func setX(_ id: TurnGraph.NodeID, _ x: CGFloat) {
            guard let index = indexByID[id] else { return }
            cells[index].x = x
        }

        func snapshotOrders() -> [TurnGraph.NodeID: Int] {
            Dictionary(uniqueKeysWithValues: cells.map { ($0.id, $0.order) })
        }

        mutating func restoreOrders(_ orders: [TurnGraph.NodeID: Int]) {
            for index in cells.indices {
                cells[index].order = orders[cells[index].id] ?? cells[index].order
            }
        }

        /// Node ids of each layer, sorted by order
        func layerBuckets() -> [[TurnGraph.NodeID]] {
            let maxLayer = cells.map(\.layer).max() ?? 0
            var buckets: [[Cell]] = Array(repeating: [], count: maxLayer + 1)
            for cell in cells { buckets[cell.layer].append(cell) }
            return buckets.map { bucket in
                bucket.sorted { $0.order == $1.order ? $0.id.raw < $1.id.raw : $0.order < $1.order }
                    .map(\.id)
            }
        }

        func predecessors(_ id: TurnGraph.NodeID) -> [TurnGraph.NodeID] {
            segments.filter { $0.to == id }.map(\.from)
        }

        func successors(_ id: TurnGraph.NodeID) -> [TurnGraph.NodeID] {
            segments.filter { $0.from == id }.map(\.to)
        }

        /// Node width = padding + icon slot + text + trailing badges.
        /// Badges (`×N` / failure dot) must be counted: if they're left out they squeeze the text,
        /// and `swift build` gets truncated to `swi…uild`.
        func nodeWidth(_ node: TurnGraph.Node) -> CGFloat {
            // Title and subtitle are stacked on two lines; take the wider one
            let halfWidths = max(halfWidth(node.title), halfWidth(node.subtitle))
            var raw = metrics.nodePadding + 17  // 17 = left icon slot + spacing
                + metrics.charWidth * CGFloat(halfWidths)
            if node.occurrences > 1 { raw += 22 }
            if node.isError { raw += 14 }
            return min(metrics.maxNodeWidth, max(metrics.minNodeWidth, raw))
        }

        /// CJK counts as 2 half-width slots (EurekaKit can't use CoreText, so widths are estimated)
        func halfWidth(_ text: String) -> Int {
            text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
        }

        func edgeKey(_ edge: TurnGraph.Edge) -> String {
            "\(edge.from.raw)->\(edge.to.raw)|\(edge.role.rawValue)"
        }
    }
}
