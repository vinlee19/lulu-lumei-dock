import CoreGraphics
import Foundation

/// 记忆图谱布局引擎：`MemoryGraph.Graph` → 节点矩形 + 泳道底轨 + 边折线。
///
/// 纯函数、无 AppKit（照 `TurnGraphLayout` 的先例），所以「边不穿节点」这类不变量能单测，
/// 离屏渲染也拿得到**可复现**的基准图 —— 力导向布局两条都做不到，所以没选。
///
/// 排版是一张**均匀网格**，不是分层 DAG：
///  - **列 = 分类泳道**（`MemoryType.laneOrder` 写死顺序）+ 末列「来源会话」道；
///  - **行 0 = 索引**（MEMORY.md）、**行 1 = 泳道头**、行 2 起是条目（时间倒序）；
///  - 分类归属靠**列 + 一条淡色底轨**表达，不给每个条目画一条 contains 边 ——
///    73 条竖线会盖掉真正要看的引用边，而列位置已经把归属说清楚了。
///
/// 边一律走正交折线：**水平段只落在行 gutter 带、竖直段只落在列 gutter 带**。
/// 那两种带按定义没有节点（节点只占行带 × 列宽），于是「不穿节点」是可证的。
public enum MemoryGraphLayout {
    // MARK: - 度量

    public struct Metrics: Equatable, Sendable {
        /// 视口宽度（由 GeometryReader 给）
        public var canvasWidth: CGFloat
        public var nodeHeight: CGFloat = 38
        /// 泳道头行高
        public var headerHeight: CGFloat = 24
        public var rowGap: CGFloat = 16
        public var columnGap: CGFloat = 22
        public var minColumnWidth: CGFloat = 116
        public var maxColumnWidth: CGFloat = 210
        public var margin: CGFloat = 14
        public var maxNodes: Int = 300
        /// 同一 gutter 里错开的子道数（避免多条边重合成一条）
        public var lanesPerGutter: Int = 3

        public init(canvasWidth: CGFloat) { self.canvasWidth = canvasWidth }

        public static func standard(width: CGFloat) -> Metrics { Metrics(canvasWidth: width) }

        /// 紧凑档：记忆详情页的一跳关联小图
        public static func compact(width: CGFloat) -> Metrics {
            var metrics = Metrics(canvasWidth: width)
            metrics.nodeHeight = 32
            metrics.headerHeight = 20
            metrics.rowGap = 12
            metrics.columnGap = 16
            metrics.minColumnWidth = 92
            metrics.maxColumnWidth = 156
            metrics.margin = 10
            metrics.maxNodes = 40
            return metrics
        }
    }

    // MARK: - 输出

    public struct PlacedNode: Equatable, Sendable, Identifiable {
        /// 原点左上，与 SwiftUI 坐标系一致
        public var frame: CGRect
        public var row: Int
        public var column: Int
        public var node: MemoryGraph.Node
        public var id: MemoryGraph.NodeID { node.id }
    }

    public struct RoutedEdge: Equatable, Sendable {
        public var from: MemoryGraph.NodeID
        public var to: MemoryGraph.NodeID
        public var role: MemoryGraph.EdgeRole
        /// 折线顶点（≥2 个，含贴边起止点）
        public var points: [CGPoint]
        public var arrowTip: CGPoint
        /// 箭头朝向（单位向量）
        public var arrowDirection: CGVector
        public var isBidirectional: Bool
    }

    /// 泳道底轨：一列的背景带 + 标题（分类归属的视觉载体）
    public struct LaneRail: Equatable, Sendable, Identifiable {
        public var id: String
        public var rect: CGRect
        public var title: String
        /// nil = 「来源会话」道
        public var type: MemoryType?
        public var count: Int
    }

    public enum Degradation: Equatable, Sendable {
        /// 节点太多，不排版（调用方退回列表）
        case tooManyNodes(count: Int, limit: Int)
    }

    public struct Result: Equatable, Sendable {
        public var nodes: [PlacedNode]
        public var edges: [RoutedEdge]
        public var rails: [LaneRail]
        public var canvasSize: CGSize
        public var columnCount: Int
        public var rowCount: Int
        public var degraded: Degradation?
        /// 泳道按最小列宽也塞不进视口 ⇒ 画布比视口宽，调用方要开横向滚动并提示一句。
        /// **不是**降级：宁可横向滚动，也不能因为多一条泳道就整张图不画。
        public var overflowsViewport: Bool

        public init(
            nodes: [PlacedNode] = [], edges: [RoutedEdge] = [], rails: [LaneRail] = [],
            canvasSize: CGSize = .zero, columnCount: Int = 0, rowCount: Int = 0,
            degraded: Degradation? = nil, overflowsViewport: Bool = false
        ) {
            self.nodes = nodes
            self.edges = edges
            self.rails = rails
            self.canvasSize = canvasSize
            self.columnCount = columnCount
            self.rowCount = rowCount
            self.degraded = degraded
            self.overflowsViewport = overflowsViewport
        }

        public func placed(_ id: MemoryGraph.NodeID) -> PlacedNode? {
            nodes.first { $0.id == id }
        }
    }

    // MARK: - 入口

    public static func layout(_ graph: MemoryGraph.Graph, metrics: Metrics) -> Result {
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
        let graph: MemoryGraph.Graph
        let metrics: Metrics

        /// 泳道列的类型（末列会话道不在此列表里，靠 sessionColumn 指出）
        var laneTypes: [MemoryType] = []
        var sessionColumn: Int?
        var columnWidth: CGFloat = 0
        var gridLeft: CGFloat = 0
        var gridWidth: CGFloat = 0
        /// 行高表（行 0 可能是索引、其后可能是泳道头，再往后全是条目）
        var rowHeights: [CGFloat] = []
        var hasIndex = false
        var hasHeaders = false
        var overflowsViewport = false
        /// 节点 → (row, column)
        var slots: [MemoryGraph.NodeID: (row: Int, column: Int)] = [:]
        var frames: [MemoryGraph.NodeID: CGRect] = [:]

        init(graph: MemoryGraph.Graph, metrics: Metrics) {
            self.graph = graph
            self.metrics = metrics
        }

        mutating func run() -> Result {
            // MARK: 1 · 列
            var seenTypes = Set<MemoryType>()
            for node in graph.nodes {
                guard case .entry(let type) = node.kind else { continue }
                seenTypes.insert(type)
            }
            // 子图里可能只剩会话 + 一条记忆；分类节点缺失也照样按 entry 的 type 推出泳道
            laneTypes = seenTypes.sorted { $0.laneOrder < $1.laneOrder }
            let sessionNodes = graph.nodes.filter {
                if case .session = $0.kind { return true } else { return false }
            }
            if !sessionNodes.isEmpty { sessionColumn = laneTypes.count }
            let columnCount = laneTypes.count + (sessionColumn == nil ? 0 : 1)
            guard columnCount > 0 else { return Result() }

            let usable = metrics.canvasWidth - metrics.margin * 2
            let gaps = metrics.columnGap * CGFloat(columnCount - 1)
            let raw = (usable - gaps) / CGFloat(columnCount)
            columnWidth = max(metrics.minColumnWidth, min(metrics.maxColumnWidth, raw))
            gridWidth = columnWidth * CGFloat(columnCount) + gaps
            // 塞不下就让画布比视口宽（调用方横向滚动），而不是整张图不画
            overflowsViewport = gridWidth + metrics.margin * 2 > metrics.canvasWidth
            gridLeft = overflowsViewport
                ? metrics.margin : metrics.margin + (usable - gridWidth) / 2

            // MARK: 2 · 行
            hasIndex = graph.nodes.contains { $0.kind == .index }
            let categoryNodes = graph.nodes.filter {
                if case .category = $0.kind { return true } else { return false }
            }
            hasHeaders = !categoryNodes.isEmpty
            let firstEntryRow = (hasIndex ? 1 : 0) + (hasHeaders ? 1 : 0)

            if hasIndex, let index = graph.nodes.first(where: { $0.kind == .index }) {
                slots[index.id] = (row: 0, column: 0)
            }
            for node in categoryNodes {
                guard let type = node.kind.memoryType,
                      let column = laneTypes.firstIndex(of: type) else { continue }
                slots[node.id] = (row: hasIndex ? 1 : 0, column: column)
            }
            // 条目：graph.nodes 里的次序已经是 MemoryGraphBuilder.entryOrder 排好的
            var nextRow = Array(repeating: firstEntryRow, count: laneTypes.count)
            for node in graph.nodes {
                guard case .entry(let type) = node.kind,
                      let column = laneTypes.firstIndex(of: type) else { continue }
                slots[node.id] = (row: nextRow[column], column: column)
                nextRow[column] += 1
            }
            // 会话：落在「首个引用它的条目」所在行；被占则顺延（确定性）
            if let sessionColumn {
                var firstRow: [MemoryGraph.NodeID: Int] = [:]
                for edge in graph.edges where edge.role == .origin {
                    guard let row = slots[edge.from]?.row else { continue }
                    firstRow[edge.to] = min(firstRow[edge.to] ?? Int.max, row)
                }
                var taken = Set<Int>()
                let ordered = sessionNodes.sorted { lhs, rhs in
                    let lr = firstRow[lhs.id] ?? Int.max
                    let rr = firstRow[rhs.id] ?? Int.max
                    return lr == rr ? lhs.id.raw < rhs.id.raw : lr < rr
                }
                for node in ordered {
                    var row = max(firstEntryRow, firstRow[node.id] ?? firstEntryRow)
                    while taken.contains(row) { row += 1 }
                    taken.insert(row)
                    slots[node.id] = (row: row, column: sessionColumn)
                }
            }

            let rowCount = (slots.values.map(\.row).max() ?? 0) + 1
            rowHeights = (0..<rowCount).map { row in
                if hasIndex, row == 0 { return metrics.nodeHeight }
                if hasHeaders, row == (hasIndex ? 1 : 0) { return metrics.headerHeight }
                return metrics.nodeHeight
            }

            // MARK: 3 · 坐标
            for node in graph.nodes {
                guard let slot = slots[node.id] else { continue }
                let height = rowHeights[slot.row]
                if node.kind == .index {
                    // 索引横跨网格中线：它是这张图的题眼，用一列宽会显得和条目同级
                    let width = min(gridWidth, columnWidth * 1.6 + metrics.columnGap)
                    frames[node.id] = CGRect(
                        x: gridLeft + (gridWidth - width) / 2, y: rowY(slot.row),
                        width: width, height: height)
                } else {
                    frames[node.id] = CGRect(
                        x: columnX(slot.column), y: rowY(slot.row),
                        width: columnWidth, height: height)
                }
            }

            let placed = graph.nodes.compactMap { node -> PlacedNode? in
                guard let slot = slots[node.id], let frame = frames[node.id] else { return nil }
                return PlacedNode(frame: frame, row: slot.row, column: slot.column, node: node)
            }
            let canvasHeight = (rowY(rowCount - 1) + rowHeights[rowCount - 1] + metrics.margin)
            return Result(
                nodes: placed, edges: routeEdges(), rails: buildRails(placed),
                canvasSize: CGSize(
                    width: max(metrics.canvasWidth, gridWidth + metrics.margin * 2),
                    height: canvasHeight),
                columnCount: columnCount, rowCount: rowCount,
                overflowsViewport: overflowsViewport)
        }

        // MARK: 网格几何

        func columnX(_ column: Int) -> CGFloat {
            gridLeft + CGFloat(column) * (columnWidth + metrics.columnGap)
        }

        func rowY(_ row: Int) -> CGFloat {
            var y = metrics.margin
            for index in 0..<max(0, row) { y += rowHeights[index] + metrics.rowGap }
            return y
        }

        /// 第 row 行下方那条行 gutter 的中线（该带按定义无节点）
        func rowGutterY(below row: Int) -> CGFloat {
            rowY(row) + rowHeights[min(row, rowHeights.count - 1)] + metrics.rowGap / 2
        }

        /// 第 0 行**上方**那条带。目标就在第 0 行时必须从这里进 ——
        /// 走「下方 gutter」会让最后一竖段从节点内部穿出来（子图里第 0 行就是条目行）。
        func topGutterY() -> CGFloat {
            max(metrics.rowGap / 4, rowY(0) - metrics.rowGap / 2)
        }

        /// 第 column 列右侧那条列 gutter 的中线；`column == -1` = 网格最左侧那条
        func columnGutterX(after column: Int) -> CGFloat {
            if column < 0 { return gridLeft - metrics.columnGap / 2 }
            return columnX(column) + columnWidth + metrics.columnGap / 2
        }

        // MARK: 边路由

        mutating func routeEdges() -> [RoutedEdge] {
            var routed: [RoutedEdge] = []
            // 同一 gutter 内按到达次序取子道错开（确定性，不用随机也不用哈希）
            var rowLane: [Int: Int] = [:]
            var columnLane: [Int: Int] = [:]
            func offset(_ counter: inout [Int: Int], key: Int, span: CGFloat) -> CGFloat {
                let index = counter[key] ?? 0
                counter[key] = index + 1
                let lanes = max(1, metrics.lanesPerGutter)
                let step = span / CGFloat(lanes + 1)
                // 0, +step, -step, +2step, … 始终留在 gutter 带内
                let slot = index % lanes
                let magnitude = CGFloat((slot + 1) / 2) * step
                return slot == 0 ? 0 : (slot % 2 == 1 ? magnitude : -magnitude)
            }

            for edge in graph.edges {
                guard let fromSlot = slots[edge.from], let toSlot = slots[edge.to],
                      let fromFrame = frames[edge.from], let toFrame = frames[edge.to]
                else { continue }
                let exitY = rowGutterY(below: fromSlot.row)
                    + offset(&rowLane, key: fromSlot.row, span: metrics.rowGap)
                var points: [CGPoint] = [
                    CGPoint(x: fromFrame.midX, y: fromFrame.maxY),
                    CGPoint(x: fromFrame.midX, y: exitY),
                ]
                if toSlot.row == fromSlot.row + 1 {
                    // 紧邻下一行：水平段就在同一条行 gutter 里，不必绕列 gutter
                    points.append(CGPoint(x: toFrame.midX, y: exitY))
                } else {
                    let gutter = gutterColumn(from: fromSlot.column, to: toSlot.column)
                    let laneX = columnGutterX(after: gutter)
                        + offset(&columnLane, key: gutter, span: metrics.columnGap)
                    // 目标在第 0 行 → 从网格上方那条带进；否则从它上一行的 gutter 进
                    let enterY = toSlot.row == 0
                        ? topGutterY() + offset(&rowLane, key: -1, span: metrics.rowGap)
                        : rowGutterY(below: toSlot.row - 1)
                            + offset(&rowLane, key: toSlot.row - 1, span: metrics.rowGap)
                    points.append(CGPoint(x: laneX, y: exitY))
                    points.append(CGPoint(x: laneX, y: enterY))
                    points.append(CGPoint(x: toFrame.midX, y: enterY))
                }
                points.append(CGPoint(x: toFrame.midX, y: toFrame.minY))
                let cleaned = Engine.simplify(points)
                guard cleaned.count >= 2 else { continue }
                let tip = cleaned[cleaned.count - 1]
                let previous = cleaned[cleaned.count - 2]
                let dx = tip.x - previous.x
                let dy = tip.y - previous.y
                let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
                routed.append(RoutedEdge(
                    from: edge.from, to: edge.to, role: edge.role, points: cleaned,
                    arrowTip: tip,
                    arrowDirection: CGVector(dx: dx / length, dy: dy / length),
                    isBidirectional: edge.isBidirectional))
            }
            return routed
        }

        /// 竖直段走哪条列 gutter：**紧贴目标列**那一条（横跨的列数最少）
        func gutterColumn(from source: Int, to target: Int) -> Int {
            if target > source { return target - 1 }
            if target < source { return target }
            let columnCount = laneTypes.count + (sessionColumn == nil ? 0 : 1)
            return target < columnCount - 1 ? target : target - 1
        }

        /// 去掉重合点并合并共线段（保证每一段严格水平或竖直）
        static func simplify(_ raw: [CGPoint]) -> [CGPoint] {
            var points: [CGPoint] = []
            for point in raw {
                if let last = points.last,
                   abs(last.x - point.x) < 0.001, abs(last.y - point.y) < 0.001 {
                    continue
                }
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

        // MARK: 泳道底轨

        func buildRails(_ placed: [PlacedNode]) -> [LaneRail] {
            var rails: [LaneRail] = []
            let headerRow = hasIndex ? 1 : 0
            for (column, type) in laneTypes.enumerated() {
                let members = placed.filter { $0.column == column && $0.node.kind != .index }
                guard let top = members.map(\.frame.minY).min(),
                      let bottom = members.map(\.frame.maxY).max() else { continue }
                let count = members.filter {
                    if case .entry = $0.node.kind { return true } else { return false }
                }.count
                rails.append(LaneRail(
                    id: "cat:\(type.rawValue)",
                    rect: CGRect(
                        x: columnX(column) - 5, y: top - 5,
                        width: columnWidth + 10, height: bottom - top + 10),
                    title: type.label, type: type, count: count))
            }
            if let sessionColumn {
                let members = placed.filter { $0.column == sessionColumn }
                if let top = members.map(\.frame.minY).min(),
                   let bottom = members.map(\.frame.maxY).max() {
                    rails.append(LaneRail(
                        id: "sessions",
                        rect: CGRect(
                            x: columnX(sessionColumn) - 5,
                            y: min(top, rowY(headerRow)) - 5,
                            width: columnWidth + 10,
                            height: bottom - min(top, rowY(headerRow)) + 10),
                        title: "来源会话", type: nil, count: members.count))
                }
            }
            return rails
        }
    }
}
