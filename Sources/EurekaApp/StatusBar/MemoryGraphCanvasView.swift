import EurekaKit
import SwiftUI

/// 记忆图谱画布：把 `MemoryGraphLayout.Result` 画出来。
///
/// 渲染取舍与 `TurnGraphCanvasView` 完全一致，理由也一样：**ZStack 绝对定位 + 每种边角色一个
/// `Shape`，不用 `Canvas`** —— 本项目的验收手段是 `NSHostingView + cacheDisplay`
/// （见 `PreviewRenderer`），而 `Canvas` 等价隐式 `drawingGroup()`（Metal 离屏合成），
/// 渲成空白就没有 fallback。节点是真 View 于是 `.onHover` / `onTapGesture` / `.help()` 全部免费。
struct MemoryGraphCanvasView: View {
    let result: MemoryGraphLayout.Result
    /// 当前选中的节点（详情条由外层展示）
    @Binding var selected: MemoryGraph.NodeID?
    /// 点条目节点 → 打开这条记忆（参数是记忆文件路径）
    var onOpenMemory: ((String) -> Void)?
    /// 点会话节点 → 跳「会话」页；transcript 已删除的节点不会调用
    var onRevealSession: ((String) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 泳道底轨在最底层：分类归属靠「列 + 底轨」表达，不靠每条一根连线
            ForEach(result.rails) { rail in
                railView(rail)
                    .frame(width: rail.rect.width, height: rail.rect.height)
                    .offset(x: rail.rect.minX, y: rail.rect.minY)
            }
            // 边在节点之下：边贴着节点边缘起止，压在下面才不会盖住圆角
            ForEach(MemoryGraph.EdgeRole.allCases, id: \.self) { role in
                let edges = result.edges.filter { $0.role == role }
                if !edges.isEmpty {
                    MemoryEdgeShape(edges: edges)
                        .stroke(style: strokeStyle(role))
                        .foregroundStyle(color(role))
                    MemoryArrowShape(edges: edges)
                        .fill(color(role))
                    // 互相引用：起点也画一个箭头，而不是画第二条重合的线
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
                    // 用 offset 而不是 position：position 是中心坐标语义，会和 frame 打架
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
            // transcript 不在了就没有可跳的目标：宁可不响应，也别跳去一个空会话页
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
                // 分类道的标题由 header 节点承载；会话道没有 header 节点，标题画在轨顶
                if rail.type == nil {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 9))
                        Text("\(rail.title) \(rail.count)")
                            .font(.system(size: 10, weight: .semibold))
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

    /// 实线 = 记忆之间的引用（这张图的主角）；虚线 = 结构性的收录与来源
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

// MARK: - 边（按角色聚合成一个 Shape，与边数无关）

/// 折线段。引擎保证每段严格水平或竖直、且不穿节点，这里只负责描出来。
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

/// 箭头单独一层：`fill` 出实心三角，不跟着虚线样式走（虚线箭头认不出方向）
struct MemoryArrowShape: Shape {
    let edges: [MemoryGraphLayout.RoutedEdge]
    /// true = 画在起点（双向边用）
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

// MARK: - 节点

/// 一个节点。hover / 选中的视觉沿用 `KnowledgeCard`（换描边 + 0.12 easeOut），
/// 悬停详情走 `.help()` 而**不用 popover** —— popover 依赖真实窗口，离屏渲染时不被光栅化。
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
                Image(systemName: icon).font(.system(size: 9.5))
                Text(node.title).font(.system(size: 10.5, weight: .semibold))
                Text(node.subtitle)
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(tint)
        } else {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 0) {
                    Text(node.title)
                        // 契约：标签必须放进引擎给的固定 frame，绝不让文字反向影响布局
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !node.subtitle.isEmpty {
                        Text(node.subtitle)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 0)
                if node.degree > 1, case .entry = node.kind {
                    Text("\(node.degree)")
                        .font(.system(size: 9, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.brandFg)
                        .fixedSize()
                }
            }
        }
    }

    // MARK: 视觉

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

    /// 虚线描边 = 「这个节点有问题」：已删除的会话（点不开）、未被索引收录的记忆（agent 读不到）
    private var isDashed: Bool { isMissingSession || node.isUnindexed }

    private var helpText: String {
        var lines: [String] = []
        switch node.kind {
        case .index:
            lines.append("记忆库索引 MEMORY.md（点击查看）")
        case .category(let type):
            lines.append("\(type.label) · \(node.memberCount) 条")
        case .entry:
            lines.append(node.title)
            if !node.subtitle.isEmpty { lines.append(node.subtitle) }
            if node.isUnindexed {
                lines.append("⚠️ MEMORY.md 没收录这条 —— agent 读索引时看不到它")
            }
            if node.degree > 0 { lines.append("关联 \(node.degree) 处（引用 / 来源会话）") }
            lines.append("点击查看这条记忆")
        case .session(let exists):
            lines.append(exists ? "来源会话（点击跳到会话页）" : "来源会话的记录文件已不在，无法跳转")
            if let sessionId = node.sessionId { lines.append(sessionId) }
        }
        return lines.joined(separator: "\n")
    }
}
