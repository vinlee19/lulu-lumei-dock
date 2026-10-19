import EurekaKit
import SwiftUI

/// Lineage graph canvas: draws a `TurnGraphLayout.Result`.
///
/// **Uses `ZStack` absolute positioning + one `Shape` per edge role, not `Canvas`.** The deciding
/// reason is offscreen rendering -- this project verifies UI via `NSHostingView + cacheDisplay`
/// (see `PreviewRenderer.snap`), while `Canvas` is internally equivalent to an implicit
/// `drawingGroup()` (Metal offscreen compositing); that combination has zero precedent in the repo,
/// and if it renders blank there's no fallback. `ZStack`+`Shape` is doubly proven: `renderShell`
/// has rendered `AuditView` containing a `GeometryReader`, and `IconRenderer` has rendered icons
/// with `Shape`. Side benefit: nodes are real Views, so `.onHover` / `onTapGesture` / `.help()` all
/// come for free -- and the main window has no gesture infrastructure of its own.
///
/// Edge layers are aggregated by role into 4+4 Shapes (lines + arrows), **independent of edge count**: 60 edges are still 8 Views.
struct TurnGraphCanvasView: View {
    let result: TurnGraphLayout.Result
    /// Currently selected node (the detail strip is shown by the outer view)
    @Binding var selected: TurnGraph.NodeID?
    /// "Jump to message" on a node; nil = not offered
    var onJumpToMessage: ((Int) -> Void)?
    /// Click a fold node to expand it
    var onToggleFold: ((TurnGraph.NodeID) -> Void)?
    /// Click a subagent node to expand/collapse its internal steps (merged into the same graph)
    var onToggleSubagent: ((TurnGraph.Node) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Edges below, nodes on top: edges start and end at node borders, and only underneath
            // do they not cover the rounded corners
            ForEach(TurnGraph.EdgeRole.allCases, id: \.self) { role in
                let edges = result.edges.filter { $0.role == role }
                if !edges.isEmpty {
                    TurnEdgeShape(edges: edges)
                        .stroke(style: strokeStyle(role))
                        .foregroundStyle(color(role))
                    TurnArrowShape(edges: edges)
                        .fill(color(role))
                }
            }
            ForEach(result.nodes) { placed in
                TurnGraphNodeView(
                    placed: placed,
                    isSelected: selected == placed.id,
                    overflowBadges: result.overflowBadges[placed.id] ?? [],
                    onTap: {
                        switch placed.node.kind {
                        case .folded:
                            onToggleFold?(placed.id)
                        case .subagent where onToggleSubagent != nil:
                            onToggleSubagent?(placed.node)
                        default:
                            selected = selected == placed.id ? nil : placed.id
                        }
                    })
                    .frame(width: placed.frame.width, height: placed.frame.height)
                    // offset rather than position: position has center-coordinate semantics and
                    // would fight the frame
                    .offset(x: placed.frame.minX, y: placed.frame.minY)
            }
        }
        .frame(width: result.canvasSize.width, height: result.canvasSize.height,
               alignment: .topLeading)
    }

    private func color(_ role: TurnGraph.EdgeRole) -> Color {
        switch role {
        case .causal: return Theme.brandFg.opacity(0.35)
        case .dataFlow: return Theme.brandFg.opacity(0.6)
        case .retry: return Theme.failureRed.opacity(0.8)
        case .rework: return Theme.goldFg.opacity(0.85)
        case .spawn: return Theme.brandFg.opacity(0.55)
        }
    }

    /// Solid = progress; dashed = problem loops (re-read/retry/rework), distinguishable at a glance
    private func strokeStyle(_ role: TurnGraph.EdgeRole) -> StrokeStyle {
        switch role {
        case .causal, .spawn:
            return StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        case .dataFlow, .retry, .rework:
            return StrokeStyle(
                lineWidth: 1.2, lineCap: .round, lineJoin: .round, dash: [3.5, 3])
        }
    }
}

// MARK: - Edges (aggregated by role into one Shape, independent of edge count)

/// Polyline segments. The engine guarantees each segment is strictly horizontal or vertical and
/// never crosses a node; this only strokes them.
struct TurnEdgeShape: Shape {
    let edges: [TurnGraphLayout.RoutedEdge]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            guard let first = edge.points.first else { continue }
            path.move(to: first)
            for point in edge.points.dropFirst() { path.addLine(to: point) }
        }
        return path
    }
}

/// Arrows get their own layer: `fill` draws solid triangles that don't follow the dash style (a
/// dashed arrow has no recognizable direction)
struct TurnArrowShape: Shape {
    let edges: [TurnGraphLayout.RoutedEdge]
    var size: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            let tip = edge.arrowTip
            let direction = edge.arrowDirection
            // Open the triangle along the normal
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let base = CGPoint(
                x: tip.x - direction.dx * size, y: tip.y - direction.dy * size)
            path.move(to: tip)
            path.addLine(to: CGPoint(
                x: base.x + normal.dx * size * 0.55, y: base.y + normal.dy * size * 0.55))
            path.addLine(to: CGPoint(
                x: base.x - normal.dx * size * 0.55, y: base.y - normal.dy * size * 0.55))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Nodes

/// One node. Hover / selection visuals are copied verbatim from `KnowledgeCard` (stroke swap + 0.12
/// easeOut); hover detail uses `.help()` and **not a popover** -- popovers depend on a real window
/// and aren't rasterized in offscreen renders.
struct TurnGraphNodeView: View {
    let placed: TurnGraphLayout.PlacedNode
    var isSelected = false
    var overflowBadges: [String] = []
    let onTap: () -> Void

    @State private var hovering = false

    private var node: TurnGraph.Node { placed.node }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(Theme.font.themed(10, .medium))
                .foregroundStyle(tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title)
                    .font(Theme.font.themed(10.5, .semibold))
                    // Contract: the label must fit the fixed frame the engine gives; text must
                    // never feed back into layout
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if node.occurrences > 1 {
                Text("×\(node.occurrences)")
                    .font(Theme.font.themedMono(9, .semibold))
                    .foregroundStyle(Theme.goldFg)
                    .fixedSize()
            }
            if node.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(Theme.font.themed(9))
                    .foregroundStyle(Theme.failureRed)
                    .fixedSize()
            }
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(fill))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(
                    borderColor,
                    style: StrokeStyle(
                        lineWidth: isSelected ? 1.5 : (hovering ? 1 : 0.6),
                        dash: isDashed ? [3, 2.5] : [])))
        .overlay(alignment: .topTrailing) {
            // When edge lanes run out, degrade to corner badges instead of drawing an illegible
            // line
            if !overflowBadges.isEmpty {
                Text("↩︎\(overflowBadges.count)")
                    .font(Theme.font.themed(8, .semibold))
                    .foregroundStyle(Theme.goldFg)
                    .padding(.horizontal, 3)
                    .background(Capsule().fill(Theme.gold.opacity(0.18)))
                    .offset(x: 4, y: -5)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onTap)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
        }
        .help(helpText)
    }

    // MARK: Visuals

    private var icon: String {
        switch node.kind {
        case .prompt: return "person.crop.circle"
        case .thinking: return "brain"
        case .fork: return "arrow.triangle.branch"
        case .tool(let kind), .folded(let kind): return kind.icon
        case .subagent: return "person.2.fill"
        case .answer: return "text.bubble"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .error: return Theme.failureRed
        case .prompt, .answer: return Theme.brandFg
        case .thinking, .fork: return Theme.brandFg.opacity(0.7)
        case .subagent: return Theme.goldFg
        case .tool, .folded: return node.isError ? Theme.failureRed : Theme.brandFg.opacity(0.8)
        }
    }

    private var fill: Color {
        if isSelected { return Theme.brandFill(0.16) }
        if hovering { return Theme.brandFill(0.09) }
        switch node.kind {
        case .prompt, .answer: return Theme.brandFill(0.07)
        case .error: return Theme.failureRed.opacity(0.08)
        default: return Theme.surface
        }
    }

    private var borderColor: Color {
        if isSelected { return Theme.brandFg }
        if hovering { return Theme.brandFg.opacity(0.6) }
        if node.isError { return Theme.failureRed.opacity(0.5) }
        return Theme.cardBorder
    }

    /// Thinking and forks get a dashed stroke: they're "process", not "action"
    private var isDashed: Bool {
        node.kind == .thinking || node.kind == .fork
    }

    private var helpText: String {
        var lines: [String] = []
        switch node.kind {
        case .fork:
            lines.append(L10n.text("Fork: several actions started here at once", zhHans: "分叉：这里同时发起了多个操作"))
            lines.append(L10n.text("(Claude strips the thinking text and keeps only an encrypted signature, so the decision point is inferred from the parallel batch)", zhHans: "（Claude 的思考明文被 CLI 剥离，只能按并行批次推断决策点）"))
        case .thinking:
            lines.append(L10n.text("Thinking", zhHans: "思考"))
        case .folded:
            lines.append(L10n.format("%@ (click to expand)", zhHans: "%@（点击展开）", node.title))
        case .subagent:
            lines.append(L10n.format(
                "Subagent %@ (click to expand or collapse what it did)",
                zhHans: "子代理 %@（点击展开/收起它做了什么）",
                node.title))
        default:
            lines.append(node.title)
        }
        if !node.subtitle.isEmpty { lines.append(node.subtitle) }
        if node.occurrences > 1 {
            lines.append(L10n.format(
                "Seen %@ times this turn",
                zhHans: "本轮出现 %@ 次",
                String(node.occurrences)))
        }
        if node.isError { lines.append(L10n.text("Has failures", zhHans: "有失败")) }
        lines.append(contentsOf: overflowBadges)
        return lines.joined(separator: "\n")
    }
}
