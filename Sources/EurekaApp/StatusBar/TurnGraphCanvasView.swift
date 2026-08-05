import EurekaKit
import SwiftUI

/// 血缘图画布：把 `TurnGraphLayout.Result` 画出来。
///
/// **用 `ZStack` 绝对定位 + 每种边角色一个 `Shape`，不用 `Canvas`。**
/// 决定性理由是离屏渲染 —— 本项目的验收手段是 `NSHostingView + cacheDisplay`（见
/// `PreviewRenderer.snap`），而 `Canvas` 内部等价隐式 `drawingGroup()`（Metal 离屏合成），
/// 这个组合全仓零先例；渲成空白就没有 fallback。`ZStack`+`Shape` 则是双重已证：
/// `renderShell` 渲过含 `GeometryReader` 的 `AuditView`，`IconRenderer` 用 `Shape` 渲过图标。
/// 附带收益：节点是真 View，`.onHover` / `onTapGesture` / `.help()` 全部免费 ——
/// 而主窗口侧没有任何手势基础设施。
///
/// 边层按角色聚合成 4+4 个 Shape（线 + 箭头），**与边数无关**：60 条边也还是 8 个 View。
struct TurnGraphCanvasView: View {
    let result: TurnGraphLayout.Result
    /// 当前选中的节点（详情条由外层展示）
    @Binding var selected: TurnGraph.NodeID?
    /// 点节点上的「跳到消息」；nil = 不提供
    var onJumpToMessage: ((Int) -> Void)?
    /// 点折叠节点展开
    var onToggleFold: ((TurnGraph.NodeID) -> Void)?
    /// 点子代理节点展开/收起它的内部步骤（并进同一张图）
    var onToggleSubagent: ((TurnGraph.Node) -> Void)?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 边在下、节点在上：边贴着节点边缘起止，压在下面才不会盖住圆角
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
                    // 用 offset 而不是 position：position 是中心坐标语义，会和 frame 打架
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

    /// 实线 = 推进；虚线 = 出了问题的回环（回读/重试/返工），一眼能分出来
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

// MARK: - 边（按角色聚合成一个 Shape，与边数无关）

/// 折线段。引擎保证每段严格水平或竖直、且不穿节点，这里只负责描出来。
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

/// 箭头单独一层：`fill` 出实心三角，不跟着虚线样式走（虚线箭头认不出方向）
struct TurnArrowShape: Shape {
    let edges: [TurnGraphLayout.RoutedEdge]
    var size: CGFloat = 5

    func path(in rect: CGRect) -> Path {
        var path = Path()
        for edge in edges {
            let tip = edge.arrowTip
            let direction = edge.arrowDirection
            // 法线方向张开三角
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

// MARK: - 节点

/// 一个节点。hover / 选中的视觉逐字照抄 `KnowledgeCard`（换描边 + 0.12 easeOut），
/// 悬停详情走 `.help()` 而**不用 popover** —— popover 依赖真实窗口，离屏渲染时不被光栅化。
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
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 0) {
                Text(node.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    // 契约：标签必须放进引擎给的固定 frame，绝不能让文字反向影响布局
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if node.occurrences > 1 {
                Text("×\(node.occurrences)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.goldFg)
                    .fixedSize()
            }
            if node.isError {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 9))
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
            // 边道用尽时降级成角标，而不是画一条看不清的线
            if !overflowBadges.isEmpty {
                Text("↩︎\(overflowBadges.count)")
                    .font(.system(size: 8, weight: .semibold))
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

    // MARK: 视觉

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

    /// 思考与分叉用虚线描边：它们是「过程」不是「动作」
    private var isDashed: Bool {
        node.kind == .thinking || node.kind == .fork
    }

    private var helpText: String {
        var lines: [String] = []
        switch node.kind {
        case .fork:
            lines.append("分叉：这里同时发起了多个操作")
            lines.append("（Claude 的思考明文被 CLI 剥离，只能按并行批次推断决策点）")
        case .thinking:
            lines.append("思考")
        case .folded:
            lines.append("\(node.title)（点击展开）")
        case .subagent:
            lines.append("子代理 \(node.title)（点击展开/收起它做了什么）")
        default:
            lines.append(node.title)
        }
        if !node.subtitle.isEmpty { lines.append(node.subtitle) }
        if node.occurrences > 1 { lines.append("本轮出现 \(node.occurrences) 次") }
        if node.isError { lines.append("有失败") }
        lines.append(contentsOf: overflowBadges)
        return lines.joined(separator: "\n")
    }
}
