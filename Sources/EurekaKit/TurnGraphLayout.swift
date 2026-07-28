import CoreGraphics
import Foundation

/// 血缘图布局引擎：`TurnGraph.Graph` → 节点矩形 + 边折线。
///
/// 纯函数、无 AppKit（照 `IslandGeometry` 的先例），所以能单测「边不穿节点」这类不变量，
/// 也能让离屏渲染拿到**可复现**的基准图 —— 力导向布局做不到这两点，所以没选。
///
/// 四步（全 O(V+E) 单遍，无递归）：
///  1. **环打破**：`seq` 单调即拓扑序，回边 = 指向不更晚的节点。构图期就判好了，
///     这里只是把回边摘出主图走专用边道，**不反向塞回 DAG**。
///  2. **分层**：longest-path，按 `seq` 升序一遍扫（前驱必已定层）。跨层 >1 的边插
///     dummy 占位 —— 这是「边不穿节点」的**结构性**保证，不是事后避让。
///  3. **层内排序**：4 趟中位数扫描降交叉。趟数固定 ⇒ 代价有上界，不会退化。
///  4. **坐标**：每层最大列数由视口反推（层宽因此有上界，横向永不裁剪）。
///
/// 边一律走**正交折线**：水平段只走层间 gutter 的正中，那里按定义没有节点，
/// 于是「不穿节点」是可证的；贝塞尔的控制点靠启发式，只能事后检测再重试。
public enum TurnGraphLayout {
    // MARK: - 度量

    public struct Metrics: Equatable, Sendable {
        /// 视口宽度（由 GeometryReader 给）
        public var canvasWidth: CGFloat
        public var nodeHeight: CGFloat = 30
        public var layerGap: CGFloat = 34
        public var columnGap: CGFloat = 14
        public var minNodeWidth: CGFloat = 92
        public var maxNodeWidth: CGFloat = 156
        /// 半角字符步进（10.5pt SF ≈ 5.8）。EurekaKit 不能用 CoreText，只能按字宽估。
        public var charWidth: CGFloat = 5.8
        public var nodePadding: CGFloat = 18
        /// 回边道间距
        public var backLaneGap: CGFloat = 11
        public var maxLanesPerSide: Int = 3
        public var orderingSweeps: Int = 4
        public var maxNodes: Int = 120
        public var margin: CGFloat = 12

        public init(canvasWidth: CGFloat) { self.canvasWidth = canvasWidth }

        public static func standard(width: CGFloat) -> Metrics { Metrics(canvasWidth: width) }

        /// 紧凑档：同样的图塞进更窄的视口（节点更矮更窄，列数因此更多）
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

        /// 两侧回边道占用的总宽
        public var laneReserve: CGFloat { backLaneGap * CGFloat(maxLanesPerSide) * 2 }

        /// **每层最大列数**：折叠阈值的唯一来源。层宽因此有上界 ⇒ 横向永不裁剪。
        public var maxColumns: Int {
            let usable = canvasWidth - laneReserve - margin * 2
            let perColumn = maxNodeWidth + columnGap
            let raw = Int(((usable + columnGap) / perColumn).rounded(.down))
            return min(6, max(3, raw))
        }
    }

    // MARK: - 输出

    public struct PlacedNode: Equatable, Sendable, Identifiable {
        /// 原点左上，与 SwiftUI 坐标系一致
        public var frame: CGRect
        public var layer: Int
        public var column: Int
        public var node: TurnGraph.Node
        public var id: TurnGraph.NodeID { node.id }
    }

    public struct RoutedEdge: Equatable, Sendable {
        public var from: TurnGraph.NodeID
        public var to: TurnGraph.NodeID
        /// 折线顶点（≥2 个，含贴边起止点）
        public var points: [CGPoint]
        public var arrowTip: CGPoint
        /// 箭头朝向（单位向量）
        public var arrowDirection: CGVector
        public var role: TurnGraph.EdgeRole
        public var isBack: Bool
        /// 回边道号；nil = 走 gutter
        public var laneIndex: Int?
        /// 边上的角标（"×3"）
        public var badge: String?
    }

    public enum Degradation: Equatable, Sendable {
        /// 节点太多，不排版（调用方退回步骤列表）
        case tooManyNodes(count: Int, limit: Int)
        /// 折叠后层宽仍超列数上限（调用方退回分层时间轴）
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
        /// 边道用尽而降级成角标的回边：目标节点 → 角标文案
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

    // MARK: - 入口

    public static func layout(_ graph: TurnGraph.Graph, metrics: Metrics) -> Result {
        guard !graph.nodes.isEmpty else { return Result() }
        guard graph.nodes.count <= metrics.maxNodes else {
            return Result(degraded: .tooManyNodes(
                count: graph.nodes.count, limit: metrics.maxNodes))
        }
        var engine = Engine(graph: graph, metrics: metrics)
        return engine.run()
    }

    // MARK: - 引擎

    private struct Engine {
        let graph: TurnGraph.Graph
        let metrics: Metrics

        /// 排版单元：真实节点或占位 dummy（dummy 只为「边不穿节点」占一个列位）
        struct Cell {
            var id: TurnGraph.NodeID
            var isDummy: Bool
            var layer: Int
            var order: Int = 0
            var width: CGFloat
            var x: CGFloat = 0
            /// dummy 属于哪条边（路由时按序串起来）
            var edgeKey: String?
        }

        var cells: [Cell] = []
        var indexByID: [TurnGraph.NodeID: Int] = [:]
        var layerOf: [TurnGraph.NodeID: Int] = [:]
        /// 分层图上的边（含被 dummy 拆开的段）
        var segments: [(from: TurnGraph.NodeID, to: TurnGraph.NodeID)] = []
        /// 原始前向边 → 它被拆成的 dummy 链
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
            // **只数真实节点**：dummy 只是为「边不穿节点」占位，
            // 把它算进层宽会在明明放得下的时候误判成「太宽」。
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

        // MARK: 步骤 1+2 · 分层（seq 升序一遍扫，前驱必已定层）

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

        /// 跨层 >1 的前向边拆成逐层的段，中间每层插一个 dummy 占位
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

        // MARK: 步骤 3 · 层内排序（固定 4 趟中位数，代价有上界）

        mutating func orderLayers() {
            // 初始序 = seq 序（时间序，在这类拓扑上已经很好）
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
                // 稳定排序：中位数相同则保持原序（保证确定性）
                let sorted = medians.enumerated()
                    .sorted { lhs, rhs in
                        lhs.element.1 == rhs.element.1
                            ? lhs.offset < rhs.offset : lhs.element.1 < rhs.element.1
                    }
                    .map(\.element.0)
                for (order, id) in sorted.enumerated() { setOrder(id, order) }
            }
        }

        // MARK: 步骤 4 · 坐标

        mutating func assignCoordinates() {
            let laneReserve = metrics.backLaneGap * CGFloat(metrics.maxLanesPerSide)
            let left = metrics.margin + laneReserve
            let right = metrics.canvasWidth - metrics.margin - laneReserve

            for bucket in layerBuckets() {
                // 先按最小间距铺开，再整体居中
                var total: CGFloat = 0
                for id in bucket { total += (self[id]?.width ?? 0) + metrics.columnGap }
                total -= metrics.columnGap
                var cursor = max(left, (left + right - total) / 2)
                for id in bucket {
                    setX(id, cursor)
                    cursor += (self[id]?.width ?? 0) + metrics.columnGap
                }
            }
            // 2 趟「向邻居中位 x 靠拢」，受不重叠约束
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
                // 左→右扫一遍，保证不重叠且不越界
                var cursor = left
                for (id, target) in desired {
                    guard let cell = self[id] else { continue }
                    let x = min(max(target, cursor), right - cell.width)
                    setX(id, max(x, cursor))
                    cursor = max(x, cursor) + cell.width + metrics.columnGap
                }
                // 非重叠扫描是**左锚**的：3 个兄弟想挤在父节点中线时，第一个占住中线、
                // 其余被推到右边，整层就偏了。所以扫完再把整层平移回目标中心。
                recenter(bucket, desired: desired, left: left, right: right)
            }
        }

        /// 把一层整体平移，使其包围盒中心对齐「各节点期望中心的均值」（受左右边界钳制）
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

        // MARK: 产出

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

        /// 有没有哪一层**真的**摆不下（所需宽度超过可用宽度）。
        /// 直接量宽度而不是数列数：列数只是折叠阈值的代理指标，
        /// 真正会伤到用户的是节点被横向裁掉。返回那一层的真实节点数。
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

        /// 层间 gutter 的正中：**水平段只走这条线**，那里按定义没有节点 ⇒ 不穿节点可证
        func gutterY(below layer: Int) -> CGFloat {
            layerY(layer) + metrics.nodeHeight + metrics.layerGap / 2
        }

        func rect(_ id: TurnGraph.NodeID) -> CGRect? {
            guard let cell = self[id] else { return nil }
            return CGRect(
                x: cell.x, y: layerY(cell.layer),
                width: cell.width, height: metrics.nodeHeight)
        }

        // MARK: 边路由

        func routeEdges(
            _ placed: [PlacedNode]
        ) -> ([RoutedEdge], [TurnGraph.NodeID: [String]]) {
            var routed: [RoutedEdge] = []
            for edge in graph.forwardEdges {
                guard let points = forwardPoints(edge) else { continue }
                routed.append(makeEdge(edge, points: points, lane: nil))
            }

            // 回边道贴着**节点包围盒**外侧，而不是画布最外沿 ——
            // 贴边沿会让每个环都画成横跨整幅图的大矩形，反而看不出它连的是谁。
            let bounds = (
                minX: placed.map(\.frame.minX).min() ?? metrics.margin,
                maxX: placed.map(\.frame.maxX).max() ?? metrics.canvasWidth - metrics.margin)

            // 按 y 区间贪心分道（重叠的分到不同道），道用尽降级成角标
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
                    let layer = layerOf[edge.to].map { "第 \($0 + 1) 层" } ?? "上游"
                    let times = edge.repeatCount > 1 ? " ×\(edge.repeatCount)" : ""
                    overflow[edge.to, default: []].append("↩︎ \(edge.role.label)\(layer)\(times)")
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

        /// 前向边：下到 gutter 正中 → 水平 → 下到目标顶边（经过 dummy 时逐段串起来）
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
                // **无条件走 gutter**：不按「x 够接近就直连」判，否则亚像素偏差会产生斜线，
                // 而斜线一出现，「水平段只在 gutter 里 ⇒ 不穿节点」这个证明就不成立了。
                // 多余的共线点由 simplify 合掉。
                points.append(CGPoint(x: start.x, y: gutter))
                points.append(CGPoint(x: end.x, y: gutter))
                points.append(end)
            }
            let cleaned = Engine.simplify(points)
            return cleaned.count >= 2 ? cleaned : nil
        }

        /// 去掉重合点并合并共线段（保证每一段都严格水平或竖直）
        static func simplify(_ raw: [CGPoint]) -> [CGPoint] {
            var points: [CGPoint] = []
            for point in raw {
                if let last = points.last,
                    abs(last.x - point.x) < 0.001, abs(last.y - point.y) < 0.001 {
                    continue
                }
                // 与前两点共线则替换掉中间那个
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

        /// 回边：下到 gutter → 横到边道 → 沿边道竖走 → 横到目标上方 gutter → 下进目标。
        /// 水平段全在 gutter 里、竖直段在节点 x 区间之外 ⇒ 同样不穿节点。
        func backPoints(
            _ edge: TurnGraph.Edge, lane: Int, bounds: (minX: CGFloat, maxX: CGFloat)
        ) -> [CGPoint]? {
            guard let from = rect(edge.from), let to = rect(edge.to),
                let fromLayer = layerOf[edge.from], let toLayer = layerOf[edge.to]
            else { return nil }
            // 左道 = 数据回读，右道 = 重试/返工：两种失效模式左右分开，一眼能分辨
            let onLeft = edge.role == .dataFlow
            let offset = metrics.backLaneGap * CGFloat(lane + 1)
            let laneX = onLeft
                ? max(metrics.margin, bounds.minX - offset)
                : min(metrics.canvasWidth - metrics.margin, bounds.maxX + offset)
            let exitY = gutterY(below: fromLayer)
            // 目标在上方：从它上一层的 gutter 进；目标在第 0 层则从它下方 gutter 绕进
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

        // MARK: 交叉数（排序质量的可断言指标）

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

        // MARK: 表维护

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

        /// 每层按 order 排好的节点 id
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

        /// 节点宽 = 内边距 + 图标槽 + 文字 + 尾部角标。
        /// 角标（`×N` / 失败点）必须计进来：漏掉的话它们会挤走正文，
        /// `swift build` 会被截成 `swi…uild`。
        func nodeWidth(_ node: TurnGraph.Node) -> CGFloat {
            // 标题与副标题上下两行，取较宽的一行
            let halfWidths = max(halfWidth(node.title), halfWidth(node.subtitle))
            var raw = metrics.nodePadding + 17  // 17 = 左侧图标槽 + 间距
                + metrics.charWidth * CGFloat(halfWidths)
            if node.occurrences > 1 { raw += 22 }
            if node.isError { raw += 14 }
            return min(metrics.maxNodeWidth, max(metrics.minNodeWidth, raw))
        }

        /// CJK 记 2 个半角位（EurekaKit 不能用 CoreText，只能按字宽估）
        func halfWidth(_ text: String) -> Int {
            text.unicodeScalars.reduce(0) { $0 + ($1.value > 0x2E80 ? 2 : 1) }
        }

        func edgeKey(_ edge: TurnGraph.Edge) -> String {
            "\(edge.from.raw)->\(edge.to.raw)|\(edge.role.rawValue)"
        }
    }
}
