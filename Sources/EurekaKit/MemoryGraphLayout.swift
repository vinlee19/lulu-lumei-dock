import CoreGraphics
import Foundation

/// Memory graph layout engine: `MemoryGraph.Graph` → node rects + swimlane rails + edge
/// polylines.
///
/// Pure functions, no AppKit (following `TurnGraphLayout`), so invariants like "edges never
/// cross nodes" are unit-testable and offscreen rendering gets a **reproducible** baseline --
/// a force-directed layout can do neither, which is why it wasn't chosen.
///
/// The layout is a **uniform grid**, not a layered DAG:
///  - **columns = category swimlanes** (fixed order from `MemoryType.laneOrder`) + a final
///    "origin sessions" lane;
///  - **row 0 = index** (MEMORY.md), **row 1 = lane headers**, entries from row 2 on (newest
///    first);
///  - category membership is shown by **column + a faint background rail**, not a contains edge
///    per entry -- 73 vertical lines would bury the reference edges that actually matter, and
///    the column position already makes membership clear.
///
/// Every edge is an orthogonal polyline: **horizontal segments only in row gutter bands,
/// vertical segments only in column gutter bands**. Those bands contain no nodes by definition
/// (nodes only occupy row band × column width), so "never crosses a node" is provable.
public enum MemoryGraphLayout {
    // MARK: - Metrics

    public struct Metrics: Equatable, Sendable {
        /// Viewport width (supplied by GeometryReader)
        public var canvasWidth: CGFloat
        public var nodeHeight: CGFloat = 38
        /// Lane header row height
        public var headerHeight: CGFloat = 24
        public var rowGap: CGFloat = 16
        public var columnGap: CGFloat = 22
        public var minColumnWidth: CGFloat = 116
        public var maxColumnWidth: CGFloat = 210
        public var margin: CGFloat = 14
        public var maxNodes: Int = 300
        /// Number of staggered sub-lanes within one gutter (keeps edges from merging into one)
        public var lanesPerGutter: Int = 3

        public init(canvasWidth: CGFloat) { self.canvasWidth = canvasWidth }

        public static func standard(width: CGFloat) -> Metrics { Metrics(canvasWidth: width) }

        /// Compact preset: the one-hop related mini graph on the memory detail page
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

    // MARK: - Output

    public struct PlacedNode: Equatable, Sendable, Identifiable {
        /// Top-left origin, matching SwiftUI's coordinate system
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
        /// Polyline vertices (>= 2, including the start/end points touching the nodes)
        public var points: [CGPoint]
        public var arrowTip: CGPoint
        /// Arrow direction (unit vector)
        public var arrowDirection: CGVector
        public var isBidirectional: Bool
    }

    /// Swimlane rail: a column's background band + title (the visual carrier of category
    /// membership)
    public struct LaneRail: Equatable, Sendable, Identifiable {
        public var id: String
        public var rect: CGRect
        public var title: String
        /// nil = the "origin sessions" lane
        public var type: MemoryType?
        public var count: Int
    }

    public enum Degradation: Equatable, Sendable {
        /// Too many nodes, no layout (caller falls back to a list)
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
        /// The lanes don't fit the viewport even at minimum column width => the canvas is wider
        /// than the viewport; the caller must enable horizontal scrolling and show a hint.
        /// **Not** a degradation: better to scroll horizontally than to drop the whole graph
        /// because of one extra lane.
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

    // MARK: - Entry point

    public static func layout(_ graph: MemoryGraph.Graph, metrics: Metrics) -> Result {
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
        let graph: MemoryGraph.Graph
        let metrics: Metrics

        /// Lane column types (the final session lane isn't in this list; sessionColumn points
        /// to it)
        var laneTypes: [MemoryType] = []
        var sessionColumn: Int?
        var columnWidth: CGFloat = 0
        var gridLeft: CGFloat = 0
        var gridWidth: CGFloat = 0
        /// Row heights (row 0 may be the index, followed possibly by lane headers, then all
        /// entries)
        var rowHeights: [CGFloat] = []
        var hasIndex = false
        var hasHeaders = false
        var overflowsViewport = false
        /// Node → (row, column)
        var slots: [MemoryGraph.NodeID: (row: Int, column: Int)] = [:]
        var frames: [MemoryGraph.NodeID: CGRect] = [:]

        init(graph: MemoryGraph.Graph, metrics: Metrics) {
            self.graph = graph
            self.metrics = metrics
        }

        mutating func run() -> Result {
            // MARK: 1 · Columns
            var seenTypes = Set<MemoryType>()
            for node in graph.nodes {
                guard case .entry(let type) = node.kind else { continue }
                seenTypes.insert(type)
            }
            // A subgraph may contain only sessions + one memory; even without category nodes
            // the lanes are derived from the entries' types
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
            // If it doesn't fit, make the canvas wider than the viewport (caller scrolls
            // horizontally) instead of not drawing the graph at all
            overflowsViewport = gridWidth + metrics.margin * 2 > metrics.canvasWidth
            gridLeft = overflowsViewport
                ? metrics.margin : metrics.margin + (usable - gridWidth) / 2

            // MARK: 2 · Rows
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
            // Entries: graph.nodes is already ordered by MemoryGraphBuilder.entryOrder
            var nextRow = Array(repeating: firstEntryRow, count: laneTypes.count)
            for node in graph.nodes {
                guard case .entry(let type) = node.kind,
                      let column = laneTypes.firstIndex(of: type) else { continue }
                slots[node.id] = (row: nextRow[column], column: column)
                nextRow[column] += 1
            }
            // Sessions: placed on the row of the first entry referencing them; if taken, move
            // down (deterministic)
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

            // MARK: 3 · Coordinates
            for node in graph.nodes {
                guard let slot = slots[node.id] else { continue }
                let height = rowHeights[slot.row]
                if node.kind == .index {
                    // The index spans the grid's centre line: it is the graph's focal point,
                    // and a single column width would make it look like a peer of the entries
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

        // MARK: Grid geometry

        func columnX(_ column: Int) -> CGFloat {
            gridLeft + CGFloat(column) * (columnWidth + metrics.columnGap)
        }

        func rowY(_ row: Int) -> CGFloat {
            var y = metrics.margin
            for index in 0..<max(0, row) { y += rowHeights[index] + metrics.rowGap }
            return y
        }

        /// Centre line of the row gutter below `row` (that band has no nodes by definition)
        func rowGutterY(below row: Int) -> CGFloat {
            rowY(row) + rowHeights[min(row, rowHeights.count - 1)] + metrics.rowGap / 2
        }

        /// The band **above** row 0. When the target is on row 0 the edge must enter from here
        /// -- going through the "below" gutter would make the last vertical segment exit from
        /// inside the node (in a subgraph, row 0 is an entry row).
        func topGutterY() -> CGFloat {
            max(metrics.rowGap / 4, rowY(0) - metrics.rowGap / 2)
        }

        /// Centre line of the column gutter right of `column`; `column == -1` = the leftmost
        /// gutter of the grid
        func columnGutterX(after column: Int) -> CGFloat {
            if column < 0 { return gridLeft - metrics.columnGap / 2 }
            return columnX(column) + columnWidth + metrics.columnGap / 2
        }

        // MARK: Edge routing

        mutating func routeEdges() -> [RoutedEdge] {
            var routed: [RoutedEdge] = []
            // Within one gutter, stagger sub-lanes by arrival order (deterministic: no
            // randomness, no hashing)
            var rowLane: [Int: Int] = [:]
            var columnLane: [Int: Int] = [:]
            func offset(_ counter: inout [Int: Int], key: Int, span: CGFloat) -> CGFloat {
                let index = counter[key] ?? 0
                counter[key] = index + 1
                let lanes = max(1, metrics.lanesPerGutter)
                let step = span / CGFloat(lanes + 1)
                // 0, +step, -step, +2step, … always stays inside the gutter band
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
                    // Directly next row: the horizontal segment sits in that same row gutter,
                    // no detour through a column gutter needed
                    points.append(CGPoint(x: toFrame.midX, y: exitY))
                } else {
                    let gutter = gutterColumn(from: fromSlot.column, to: toSlot.column)
                    let laneX = columnGutterX(after: gutter)
                        + offset(&columnLane, key: gutter, span: metrics.columnGap)
                    // Target on row 0 → enter from the band above the grid; otherwise from
                    // the gutter of the row above it
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

        /// Which column gutter the vertical segment uses: the one **adjacent to the target
        /// column** (crosses the fewest columns)
        func gutterColumn(from source: Int, to target: Int) -> Int {
            if target > source { return target - 1 }
            if target < source { return target }
            let columnCount = laneTypes.count + (sessionColumn == nil ? 0 : 1)
            return target < columnCount - 1 ? target : target - 1
        }

        /// Drops duplicate points and merges collinear segments (every segment strictly
        /// horizontal or vertical)
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

        // MARK: Swimlane rails

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
                        title: L10n.text("Source sessions", zhHans: "来源会话"), type: nil, count: members.count))
                }
            }
            return rails
        }
    }
}
