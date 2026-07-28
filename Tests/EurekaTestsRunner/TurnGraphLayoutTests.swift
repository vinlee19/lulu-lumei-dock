import CoreGraphics
import EurekaKit
import Foundation

/// TurnGraphLayout 的**不变量**测试。
/// 布局对不对没法靠肉眼看（图会随数据变），只能靠这几条能被机器验的性质兜住。
func turnGraphLayoutTests(_ t: TestRunner) {
    t.suite("TurnGraphLayout · 布局不变量")

    func step(
        _ kind: ToolKind, _ name: String, _ detail: String = "",
        batch: Int, index: Int, isError: Bool = false
    ) -> TurnInput.Step {
        TurnInput.Step(
            kind: kind, name: name, detail: detail, isError: isError,
            batch: batch, messageId: 1, stepIndex: index)
    }

    func acceptedTurn() -> TurnInput {
        TurnInput(
            turnIndex: 6, promptMessageId: 0, promptText: "修一下审计页的分页",
            thinkingTexts: ["先定位分页代码在哪"],
            steps: [
                step(.search, "Grep", "paginationBar", batch: 1, index: 0),
                step(.agent, "Explore", "定位分页实现", batch: 1, index: 1),
                step(.read, "Read", "/w/AuditView.swift", batch: 2, index: 2),
                step(.edit, "Edit", "/w/AuditView.swift", batch: 3, index: 3),
                step(.command, "Bash", "swift build", batch: 4, index: 4, isError: true),
                step(.read, "Read", "/w/AuditView.swift", batch: 5, index: 5),
                step(.edit, "Edit", "/w/AuditView.swift", batch: 6, index: 6),
                step(.command, "Bash", "swift build", batch: 7, index: 7),
            ],
            answerMessageIds: [9], answerText: "改好了")
    }

    /// 线段是否与矩形相交（端点贴边不算）
    func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let shrunk = rect.insetBy(dx: 0.5, dy: 0.5)
        guard !shrunk.isEmpty else { return false }
        if shrunk.contains(a) || shrunk.contains(b) { return true }
        // 折线只有水平/竖直段，逐段做区间相交即可
        if abs(a.y - b.y) < 0.001 {
            let (lo, hi) = (min(a.x, b.x), max(a.x, b.x))
            return a.y > shrunk.minY && a.y < shrunk.maxY && hi > shrunk.minX && lo < shrunk.maxX
        }
        if abs(a.x - b.x) < 0.001 {
            let (lo, hi) = (min(a.y, b.y), max(a.y, b.y))
            return a.x > shrunk.minX && a.x < shrunk.maxX && hi > shrunk.minY && lo < shrunk.maxY
        }
        return false
    }

    /// 全部不变量一次跑完（每个用例都调它，不必逐条重写）
    func checkInvariants(
        _ result: TurnGraphLayout.Result, _ metrics: TurnGraphLayout.Metrics, _ label: String
    ) throws {
        // 1. 节点互不重叠
        for i in result.nodes.indices {
            for j in (i + 1)..<result.nodes.count {
                let a = result.nodes[i].frame.insetBy(dx: 0.5, dy: 0.5)
                let b = result.nodes[j].frame.insetBy(dx: 0.5, dy: 0.5)
                try expect(
                    !a.intersects(b),
                    "\(label): 节点重叠 \(result.nodes[i].node.title)/\(result.nodes[j].node.title)")
            }
        }
        // 2. **边不穿节点**（最值钱的一条：正交折线 + gutter 正中的结构性保证）
        for edge in result.edges {
            let endpoints: Set<TurnGraph.NodeID> = [edge.from, edge.to]
            for index in 0..<(edge.points.count - 1) {
                for placed in result.nodes where !endpoints.contains(placed.id) {
                    try expect(
                        !crosses(edge.points[index], edge.points[index + 1], placed.frame),
                        "\(label): \(edge.role.label)边穿过了节点 \(placed.node.title)")
                }
            }
        }
        // 3. 不超出画布（横向裁剪就永远看不见了）
        for placed in result.nodes {
            try expect(placed.frame.minX >= 0, "\(label): 节点越左界")
            try expect(
                placed.frame.maxX <= metrics.canvasWidth + 0.5,
                "\(label): 节点越右界 \(placed.frame.maxX) > \(metrics.canvasWidth)")
            try expect(
                placed.frame.maxY <= result.canvasSize.height + 0.5, "\(label): 节点越下界")
        }
        // 4. 分层单调：前向边必然从上层指向下层
        let layerByID = Dictionary(
            uniqueKeysWithValues: result.nodes.map { ($0.id, $0.layer) })
        let frameByID = Dictionary(
            uniqueKeysWithValues: result.nodes.map { ($0.id, $0.frame) })
        for edge in result.edges where !edge.isBack {
            guard let from = layerByID[edge.from], let to = layerByID[edge.to],
                let fromFrame = frameByID[edge.from], let toFrame = frameByID[edge.to]
            else { continue }
            try expect(from < to, "\(label): 前向边层序倒挂")
            try expect(fromFrame.maxY < toFrame.minY, "\(label): 前向边 y 倒挂")
        }
        // 5. 折线闭合：每段都是水平或竖直（正交约束，斜线会破坏不穿节点的证明）
        for edge in result.edges {
            try expect(edge.points.count >= 2, "\(label): 折线点数不足")
            for index in 0..<(edge.points.count - 1) {
                let a = edge.points[index]
                let b = edge.points[index + 1]
                try expect(
                    abs(a.x - b.x) < 0.001 || abs(a.y - b.y) < 0.001,
                    "\(label): 出现斜线段")
            }
        }
    }

    t.test("验收形态：三档宽度下不变量全成立") {
        let graph = TurnGraphBuilder.build(acceptedTurn())
        for width in [674.0, 780.0, 1270.0] as [CGFloat] {
            let metrics = TurnGraphLayout.Metrics.standard(width: width)
            let result = TurnGraphLayout.layout(graph, metrics: metrics)
            try expect(result.degraded == nil, "宽度 \(width) 不该降级")
            try expect(!result.nodes.isEmpty)
            try checkInvariants(result, metrics, "宽 \(Int(width))")
        }
    }

    t.test("视口反推列数：最小窗 3 列 / 离屏基准 4 列 / 宽窗封顶 6 列") {
        try expectEqual(TurnGraphLayout.Metrics.standard(width: 638).maxColumns, 3)
        try expectEqual(TurnGraphLayout.Metrics.standard(width: 780).maxColumns, 4)
        try expectEqual(TurnGraphLayout.Metrics.standard(width: 1234).maxColumns, 6)
        // 极窄也不塌到 0（下限 3，再窄靠折叠与降级兜）
        try expectEqual(TurnGraphLayout.Metrics.standard(width: 200).maxColumns, 3)
    }

    t.test("确定性：同输入两次布局逐字节相等") {
        let graph = TurnGraphBuilder.build(acceptedTurn())
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let first = TurnGraphLayout.layout(graph, metrics: metrics)
        let second = TurnGraphLayout.layout(graph, metrics: metrics)
        try expectEqual(first, second, "离屏渲染拿它当基准，必须可复现")
    }

    t.test("纯链式：单列不歪，脊线笔直") {
        var steps: [TurnInput.Step] = []
        for index in 0..<8 {
            steps.append(step(.read, "Read", "/w/f\(index).swift", batch: index + 1, index: index))
        }
        let graph = TurnGraphBuilder.build(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "逐个读",
            steps: steps, answerMessageIds: [1], answerText: "读完"))
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let result = TurnGraphLayout.layout(graph, metrics: metrics)
        try checkInvariants(result, metrics, "链式")
        try expectEqual(result.maxLayerWidth, 1, "纯链式每层只有一个节点")
        try expectEqual(result.crossings, 0)
        // 每层一个节点时中心应对齐（脊线）
        let centers = Set(result.nodes.map { (($0.frame.midX) * 10).rounded() })
        try expectEqual(centers.count, 1, "单列脊线应笔直，实得 \(centers.count) 个不同中心")
    }

    t.test("60 节点最坏例：层宽有上界、画布不超宽、仍不穿节点") {
        var steps: [TurnInput.Step] = []
        var index = 0
        for batchIndex in 0..<12 {
            for column in 0..<5 {
                steps.append(step(
                    .read, "Read", "/w/b\(batchIndex)-c\(column).swift",
                    batch: batchIndex + 1, index: index))
                index += 1
            }
        }
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let graph = TurnGraphBuilder.build(
            TurnInput(
                turnIndex: 0, promptMessageId: 0, promptText: "大批量",
                steps: steps, answerMessageIds: [1], answerText: "完"),
            options: .init(maxColumns: metrics.maxColumns))
        let result = TurnGraphLayout.layout(graph, metrics: metrics)
        try expect(
            result.maxLayerWidth <= metrics.maxColumns + 1,
            "层宽应被折叠压住，实得 \(result.maxLayerWidth) > \(metrics.maxColumns)")
        try checkInvariants(result, metrics, "60 节点")
    }

    t.test("回边分道：数据回读走左、重试返工走右，道用尽降级为角标") {
        let graph = TurnGraphBuilder.build(acceptedTurn())
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let result = TurnGraphLayout.layout(graph, metrics: metrics)
        let backs = result.edges.filter(\.isBack)
        try expect(!backs.isEmpty, "验收形态本来就有回读与重试两个环")

        let nodeMinX = result.nodes.map(\.frame.minX).min() ?? 0
        let nodeMaxX = result.nodes.map(\.frame.maxX).max() ?? 0
        for edge in backs {
            // 至少有一段竖直走在节点区之外的专用边道里
            let inLane = edge.points.contains { $0.x < nodeMinX || $0.x > nodeMaxX }
            try expect(inLane, "\(edge.role.label)回边没有走边道")
            try expect(edge.laneIndex != nil)
        }
        let dataFlow = backs.filter { $0.role == .dataFlow }
        let retry = backs.filter { $0.role == .retry }
        if let left = dataFlow.first, let right = retry.first {
            let leftX = left.points.map(\.x).min() ?? 0
            let rightX = right.points.map(\.x).max() ?? 0
            try expect(
                leftX < nodeMinX && rightX > nodeMaxX,
                "回读应在左道、重试应在右道（两种失效模式左右分开才好认）")
        }
    }

    t.test("层宽超列数时降级，但坐标仍不得溢出画布") {
        // 5 个文件各读→改→构建（构建命令相同 → 去重成一个节点，于是每次编辑都回指它）。
        // 折叠是**按阶段**做的，而分层会把不同阶段的节点并到同一层 ⇒ 层宽仍可能超列数。
        // 这时可以降级，但**绝不能让节点跑到画布外**（横向裁剪就永远看不见了）。
        var steps: [TurnInput.Step] = []
        var cursor = 0
        for index in 0..<5 {
            for (kind, name, detail) in [
                (ToolKind.read, "Read", "/w/A\(index).swift"),
                (ToolKind.edit, "Edit", "/w/A\(index).swift"),
                (ToolKind.command, "Bash", "swift build"),
                (ToolKind.read, "Read", "/w/A\(index).swift"),
            ] {
                steps.append(step(
                    kind, name, detail, batch: cursor + 1, index: cursor,
                    isError: kind == .command && index < 3))
                cursor += 1
            }
        }
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let graph = TurnGraphBuilder.build(
            TurnInput(
                turnIndex: 0, promptMessageId: 0, promptText: "批量改",
                steps: steps, answerMessageIds: [1], answerText: "改完了"),
            options: .init(maxColumns: metrics.maxColumns))
        let result = TurnGraphLayout.layout(graph, metrics: metrics)
        try checkInvariants(result, metrics, "宽层")
    }

    t.test("超上限降级：不排版，交给调用方退回步骤列表") {
        var steps: [TurnInput.Step] = []
        for index in 0..<200 {
            steps.append(step(.command, "Bash", "echo \(index)", batch: index + 1, index: index))
        }
        let graph = TurnGraphBuilder.build(
            TurnInput(turnIndex: 0, promptMessageId: 0, promptText: "很多命令", steps: steps),
            options: .init(maxColumns: 4, maxNodes: 1000))
        let result = TurnGraphLayout.layout(
            graph, metrics: TurnGraphLayout.Metrics.standard(width: 780))
        guard case .tooManyNodes(let count, let limit)? = result.degraded else {
            throw ExpectationError(description: "应降级为 tooManyNodes，实得 \(String(describing: result.degraded))")
        }
        try expect(count > limit)
        try expect(result.nodes.isEmpty, "降级时不该白排一遍版")
    }

    t.test("空图 / 单节点不崩") {
        let metrics = TurnGraphLayout.Metrics.standard(width: 780)
        let empty = TurnGraphLayout.layout(TurnGraph.Graph(turnIndex: 0), metrics: metrics)
        try expect(empty.nodes.isEmpty)

        let single = TurnGraphBuilder.build(
            TurnInput(turnIndex: 0, promptMessageId: 0, promptText: "在吗"))
        let result = TurnGraphLayout.layout(single, metrics: metrics)
        try expectEqual(result.nodes.count, 1)
        try expectEqual(result.layerCount, 1)
        try checkInvariants(result, metrics, "单节点")
    }

    t.test("紧凑档：同一张图更省竖向空间") {
        let graph = TurnGraphBuilder.build(acceptedTurn())
        let standard = TurnGraphLayout.layout(
            graph, metrics: .standard(width: 780))
        let compact = TurnGraphLayout.layout(graph, metrics: .compact(width: 780))
        try expect(
            compact.canvasSize.height < standard.canvasSize.height,
            "紧凑档应更矮：\(compact.canvasSize.height) vs \(standard.canvasSize.height)")
        try checkInvariants(compact, .compact(width: 780), "紧凑")
    }
}
