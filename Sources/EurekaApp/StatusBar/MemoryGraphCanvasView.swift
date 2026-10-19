import EurekaKit
import SwiftUI

/// Memory graph canvas: draws a `MemoryGraphLayout.Result`.
///
/// The rendering trade-offs are exactly those of `TurnGraphCanvasView`, for the same reasons:
/// **ZStack absolute positioning + one
/// `Shape` per edge role, no `Canvas`**: this project verifies via `NSHostingView + cacheDisplay`
/// (see `PreviewRenderer`), and `Canvas` is equivalent to an implicit `drawingGroup()` (Metal
/// offscreen compositing),
/// so if it renders blank there is no fallback. Nodes are real Views, so `.onHover` /
/// `onTapGesture` / `.help()` all come for free.
struct MemoryGraphCanvasView: View {
    let result: MemoryGraphLayout.Result
    /// Currently selected node (the detail strip is shown by the parent)
    @Binding var selected: MemoryGraph.NodeID?
    /// Tap an entry node → open that memory (the argument is the memory file path)
    var onOpenMemory: ((String) -> Void)?
    /// Tap a session node → jump to the Sessions page; never called for nodes whose transcript was
    /// deleted
    var onRevealSession: ((String) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Swim-lane base tracks at the very bottom: category membership is expressed by "column
            // + base track", not one line per entry
            ForEach(result.rails) { rail in
                railView(rail)
                    .frame(width: rail.rect.width, height: rail.rect.height)
                    .offset(x: rail.rect.minX, y: rail.rect.minY)
            }
            // Edges under the nodes: edges start and end at node borders, so they must sit below to
            // avoid covering the rounded corners
            ForEach(MemoryGraph.EdgeRole.allCases, id: \.self) { role in
                let edges = result.edges.filter { $0.role == role }
                if !edges.isEmpty {
                    MemoryEdgeShape(edges: edges)
                        .stroke(style: strokeStyle(role))
                        .foregroundStyle(color(role))
                    MemoryArrowShape(edges: edges)
                        .fill(color(role))
                    // Mutual reference: draw an arrow at the start too, instead of drawing a second
                    // overlapping line
                    MemoryArrowShape(
                        edges: edges.filter(\.isBidirectional), atStart: true)
                        .fill(color(role))
                }
            }
            ForEach(result.nodes) { placed in
                MemoryGraphNodeView(
                    placed: placed,
                    isSelected: selected == placed.id,
                    onTap: { tap(placed) })
                    .frame(width: placed.frame.width, height: placed.frame.height)
                    // offset rather than position: position has center-coordinate semantics and
                    // fights with frame
                    .offset(x: placed.frame.minX, y: placed.frame.minY)
            }
        }
        .frame(
            width: result.canvasSize.width, height: result.canvasSize.height,
            alignment: .topLeading)
    }

    private func tap(_ placed: MemoryGraphLayout.PlacedNode) {
        switch placed.node.kind {
        case .entry, .index:
            if let path = placed.node.path, let onOpenMemory {
                onOpenMemory(path)
            } else {
                selected = selected == placed.id ? nil : placed.id
            }
        case .session(let exists):
            // No transcript means no target to jump to: better not to respond than to jump to an
            // empty session page
            if exists, let sessionId = placed.node.sessionId, let onRevealSession {
                onRevealSession(sessionId)
            } else {
                selected = selected == placed.id ? nil : placed.id
            }
        case .category:
            selected = selected == placed.id ? nil : placed.id
        }
    }

    @ViewBuilder
    private func railView(_ rail: MemoryGraphLayout.LaneRail) -> some View {
        let tint = rail.type == nil ? Theme.gold : Theme.brand
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(tint.opacity(0.045))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(tint.opacity(0.16), lineWidth: 0.8))
            .overlay(alignment: .top) {
                // Category lane titles are carried by header nodes; the session lane has no header
                // node, so its title is drawn at the top of the track
                if rail.type == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(Theme.font.themed(9))
                        Text("\(rail.title) \(rail.count)")
                            .font(Theme.font.themed(10, .semibold))
                    }
                    .foregroundStyle(Theme.goldFg)
                    .padding(.top, 6)
                }
            }
    }

    private func color(_ role: MemoryGraph.EdgeRole) -> Color {
        switch role {
        case .contains: return Theme.brand.opacity(0.28)
        case .link: return Theme.brand.opacity(0.55)
        case .origin: return Theme.gold.opacity(0.7)
        }
    }

    /// Solid = references between memories (the star of this graph); dashed = structural inclusion
    /// and origin
    private func strokeStyle(_ role: MemoryGraph.EdgeRole) -> StrokeStyle {
        switch role {
        case .link:
            return StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
        case .contains:
            return StrokeStyle(
                lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [2, 3])
        case .origin:
            return StrokeStyle(
                lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [3.5, 3])
        }
    }
}

// MARK: - Edges (aggregated into one Shape per role, independent of edge count)

/// Polyline segments. The engine guarantees each segment is strictly horizontal or vertical and
/// never crosses a node; this only strokes them.
struct MemoryEdgeShape: Shape {
    let edges: [MemoryGraphLayout.RoutedEdge]

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

/// Arrowheads on their own layer: `fill` gives solid triangles that don't follow the dash style
/// (dashed arrowheads don't read as a direction)
struct MemoryArrowShape: Shape {
    let edges: [MemoryGraphLayout.RoutedEdge]
    /// true = drawn at the start (for bidirectional edges)
    var atStart = false
    var size: CGFloat = 4.5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            guard edge.points.count >= 2 else { continue }
            let tip: CGPoint
            let direction: CGVector
            if atStart {
                tip = edge.points[0]
                let next = edge.points[1]
                let dx = tip.x - next.x
                let dy = tip.y - next.y
                let length = max(0.0001, (dx * dx + dy * dy).squareRoot())
                direction = CGVector(dx: dx / length, dy: dy / length)
            } else {
                tip = edge.arrowTip
                direction = edge.arrowDirection
            }
            let normal = CGVector(dx: -direction.dy, dy: direction.dx)
            let base = CGPoint(
                x: tip.x - direction.dx * size, y: tip.y - direction.dy * size)
            path.move(to: tip)
            path.addLine(to: CGPoint(
                x: base.x + normal.dx * size * 0.6, y: base.y + normal.dy * size * 0.6))
            path.addLine(to: CGPoint(
                x: base.x - normal.dx * size * 0.6, y: base.y - normal.dy * size * 0.6))
            path.closeSubpath()
        }
        return path
    }
}

// MARK: - Nodes

/// One node. Hover / selection visuals follow `KnowledgeCard` (swap the stroke + 0.12 easeOut);
/// hover details use `.help()` and **not a popover**: a popover needs a real window and isn't
/// rasterized during offscreen rendering.
struct MemoryGraphNodeView: View {
    let placed: MemoryGraphLayout.PlacedNode
    var isSelected = false
    let onTap: () -> Void

    @State private var hovering = false

    private var node: MemoryGraph.Node { placed.node }

    var body: some View {
        content
            .padding(.horizontal, isCategory ? 4 : 7)
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
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onTapGesture(perform: onTap)
            .onHover { hover in
                withAnimation(.easeOut(duration: 0.12)) { hovering = hover }
            }
            .help(helpText)
    }

    @ViewBuilder
    private var content: some View {
        if isCategory {
            HStack(spacing: 4) {
                Image(systemName: icon).font(Theme.font.themed(9.5))
                Text(node.title).font(Theme.font.themed(10.5, .semibold))
                Text(node.subtitle)
                    .font(Theme.font.themedMono(9.5))
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
        } else {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(Theme.font.themed(10, .medium))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.title)
                        // Contract: the label must fit in the fixed frame the engine provides; text
                        // must never feed back into the layout
                        .font(Theme.font.themed(10.5, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !node.subtitle.isEmpty {
                        Text(node.subtitle)
                            .font(Theme.font.themed(9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if node.degree > 1, case .entry = node.kind {
                    Text("\(node.degree)")
                        .font(Theme.font.themedMono(9, .semibold))
                        .foregroundStyle(Theme.brandFg)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: Visuals

    private var isCategory: Bool {
        if case .category = node.kind { return true }
        return false
    }

    private var isMissingSession: Bool {
        if case .session(let exists) = node.kind { return !exists }
        return false
    }

    private var icon: String {
        switch node.kind {
        case .index: return "books.vertical.fill"
        case .category(let type), .entry(let type): return type.icon
        case .session(let exists): return exists ? "bubble.left.and.bubble.right.fill" : "trash.slash"
        }
    }

    private var tint: Color {
        switch node.kind {
        case .index: return Theme.brand
        case .category: return Theme.brand.opacity(0.75)
        case .entry: return Theme.brand.opacity(0.85)
        case .session(let exists): return exists ? Theme.gold : .secondary
        }
    }

    private var fill: Color {
        if isSelected { return Theme.brandFill(0.16) }
        if hovering { return Theme.brandFill(0.09) }
        switch node.kind {
        case .index: return Theme.brandFill(0.08)
        case .category: return .clear
        case .entry: return Theme.surface
        case .session(let exists): return exists ? Theme.gold.opacity(0.08) : Theme.surface
        }
    }

    private var borderColor: Color {
        if isSelected { return Theme.brand }
        if hovering { return Theme.brand.opacity(0.6) }
        if isCategory { return .clear }
        if isMissingSession { return Color.secondary.opacity(0.45) }
        return Theme.cardBorder
    }

    /// Dashed stroke = "this node has a problem": a deleted session (can't be opened), a memory not
    /// listed in the index (agents can't read it)
    private var isDashed: Bool { isMissingSession || node.isUnindexed }

    private var helpText: String {
        var lines: [String] = []
        switch node.kind {
        case .index:
            lines.append(L10n.text("Memory library index MEMORY.md (click to view)", zhHans: "记忆库索引 MEMORY.md（点击查看）"))
        case .category(let type):
            lines.append(L10n.format("%1$@ · %2$@ entries", zhHans: "%1$@ · %2$@ 条", type.label, String(node.memberCount)))
        case .entry:
            lines.append(node.title)
            if !node.subtitle.isEmpty { lines.append(node.subtitle) }
            if node.isUnindexed {
                lines.append(L10n.text("⚠️ MEMORY.md does not list this one — the agent will not see it when it reads the index", zhHans: "⚠️ MEMORY.md 没收录这条 —— agent 读索引时看不到它"))
            }
            if node.degree > 0 { lines.append(L10n.format("%@ links (references / source sessions)", zhHans: "关联 %@ 处（引用 / 来源会话）", String(node.degree))) }
            lines.append(L10n.text("Click to view this memory", zhHans: "点击查看这条记忆"))
        case .session(let exists):
            lines.append(exists ? L10n.text("Source session (click to open the Sessions page)", zhHans: "来源会话（点击跳到会话页）") : L10n.text("The source session transcript is gone, so this cannot be opened", zhHans: "来源会话的记录文件已不在，无法跳转"))
            if let sessionId = node.sessionId { lines.append(sessionId) }
        }
        return lines.joined(separator: "\n")
    }
}
