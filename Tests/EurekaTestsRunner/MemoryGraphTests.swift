import CoreGraphics
import EurekaKit
import Foundation

/// MemoryGraph 构图 + MemoryGraphLayout 的**不变量**测试。
/// 图长什么样会随数据变，肉眼看不出对错 —— 只能靠这几条能被机器验的性质兜住。
func memoryGraphTests(_ t: TestRunner) {
    t.suite("MemoryGraph · 构图")

    func item(
        _ id: String, _ title: String, type: MemoryType = .project,
        links: [String] = [], session: String? = nil, sessionExists: Bool = true,
        minutesAgo: Double = 0, isIndex: Bool = false
    ) -> MemoryGraphInput.Item {
        MemoryGraphInput.Item(
            id: "/memory/\(id).md", title: title, subtitle: "副标 \(title)",
            type: type, aliases: [id, title], links: links,
            originSessionId: session, originSessionExists: sessionExists,
            // 固定基准时刻：排版与次序必须可复现，不能跟运行时钟走
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60),
            isIndex: isIndex)
    }

    /// 索引 + 4 条记忆（含互相引用、一条解析不到的链接）+ 2 个会话（其中一个已删除）
    func library() -> MemoryGraphInput {
        MemoryGraphInput(title: "aftership-semantic-layer", items: [
            item("MEMORY", "MEMORY", isIndex: true),
            item("feedback_push", "feedback-push", type: .feedback,
                 links: ["project_alpha", "根本不存在"], session: "s1", minutesAgo: 1),
            item("project_alpha", "project-alpha", type: .project,
                 links: ["feedback-push"], session: "s1", minutesAgo: 2),
            item("project_beta", "project-beta", type: .project,
                 links: ["project_alpha"], session: "s2", sessionExists: false, minutesAgo: 3),
            item("user_profile", "user-profile", type: .user, minutesAgo: 4),
        ])
    }

    t.test("节点：索引 + 分类泳道头 + 条目 + 会话（会话按 id 去重）") {
        let graph = MemoryGraphBuilder.build(library())
        try expectEqual(graph.entryCount, 4)
        try expectEqual(graph.sessionCount, 2, "s1 被两条记忆共用，只应有一个会话节点")
        let categories = graph.nodes.filter {
            if case .category = $0.kind { return true } else { return false }
        }
        try expectEqual(categories.count, 3)  // feedback / project / user
        try expect(graph.nodes.contains { $0.kind == .index })
        // 索引 → 每个分类一条收录边
        try expectEqual(graph.edges.filter { $0.role == .contains }.count, 3)
    }

    t.test("链接：按文件名/frontmatter name/下划线归一都能匹配，解析不到只计数不造边") {
        let graph = MemoryGraphBuilder.build(library())
        let links = graph.edges.filter { $0.role == .link }
        // push↔alpha 合成一条双向边，beta→alpha 一条 ⇒ 共 2 条
        try expectEqual(links.count, 2)
        try expectEqual(links.filter(\.isBidirectional).count, 1, "互相引用应合成一条双向边")
        try expectEqual(graph.unresolvedLinkCount, 1, "「根本不存在」不该造出假边")
    }

    t.test("来源会话：记录文件不在时标缺失并计数") {
        let graph = MemoryGraphBuilder.build(library())
        try expectEqual(graph.edges.filter { $0.role == .origin }.count, 3)
        try expectEqual(graph.missingSessionCount, 1)
        let missing = graph.nodes.first { $0.kind == .session(exists: false) }
        try expect(missing != nil, "已删除的会话仍要有节点（灰显），不能悄悄消失")
        try expectEqual(missing?.sessionId, "s2")
    }

    t.test("构图确定性：同输入两次结果全等") {
        try expectEqual(MemoryGraphBuilder.build(library()), MemoryGraphBuilder.build(library()))
    }

    t.test("一跳子图：只留焦点与直接邻居，丢掉索引/分类骨架") {
        let graph = MemoryGraphBuilder.build(library())
        let focus = try require(graph.nodeID(forPath: "/memory/project_alpha.md"))
        let sub = graph.subgraph(around: focus)
        // alpha 自己 + push + beta + 会话 s1
        try expectEqual(sub.nodes.count, 4)
        try expect(
            !sub.nodes.contains { $0.kind == .index },
            "一跳视野里索引/分类只是噪声")
        try expect(sub.edges.allSatisfy { $0.from == focus || $0.to == focus })
    }

    t.suite("MemoryGraphLayout · 布局不变量")

    /// 线段是否穿进矩形内部（端点贴边不算）。折线只有水平/竖直段，逐段区间相交即可。
    func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let shrunk = rect.insetBy(dx: 0.5, dy: 0.5)
        guard !shrunk.isEmpty else { return false }
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

    t.test("节点两两不重叠") {
        let result = MemoryGraphLayout.layout(
            MemoryGraphBuilder.build(library()), metrics: .standard(width: 760))
        try expect(result.degraded == nil)
        for (index, lhs) in result.nodes.enumerated() {
            for rhs in result.nodes.dropFirst(index + 1) {
                try expect(
                    !lhs.frame.intersects(rhs.frame),
                    "节点重叠：\(lhs.node.title) 与 \(rhs.node.title)")
            }
        }
    }

    t.test("每条边的每一段严格水平或竖直") {
        let result = MemoryGraphLayout.layout(
            MemoryGraphBuilder.build(library()), metrics: .standard(width: 760))
        for edge in result.edges {
            try expect(edge.points.count >= 2)
            for index in 0..<(edge.points.count - 1) {
                let a = edge.points[index]
                let b = edge.points[index + 1]
                try expect(
                    abs(a.x - b.x) < 0.001 || abs(a.y - b.y) < 0.001,
                    "出现斜线段：\(a) → \(b)（水平段只许走行 gutter、竖直段只许走列 gutter）")
            }
        }
    }

    t.test("边不穿节点（水平段在行 gutter、竖直段在列 gutter，所以可证）") {
        let result = MemoryGraphLayout.layout(
            MemoryGraphBuilder.build(library()), metrics: .standard(width: 760))
        for edge in result.edges {
            for index in 0..<(edge.points.count - 1) {
                let a = edge.points[index]
                let b = edge.points[index + 1]
                for placed in result.nodes {
                    // 自己的起止节点：折线贴着它的边缘起止，不算穿
                    if placed.id == edge.from || placed.id == edge.to { continue }
                    try expect(
                        !crosses(a, b, placed.frame),
                        "边 \(edge.from)→\(edge.to) 穿过节点 \(placed.node.title)")
                }
            }
        }
    }

    t.test("排版确定性：同输入两次结果全等") {
        let graph = MemoryGraphBuilder.build(library())
        try expectEqual(
            MemoryGraphLayout.layout(graph, metrics: .standard(width: 760)),
            MemoryGraphLayout.layout(graph, metrics: .standard(width: 760)))
    }

    t.test("泳道底轨：每个分类一条 + 会话道一条，且包住各自的节点") {
        let result = MemoryGraphLayout.layout(
            MemoryGraphBuilder.build(library()), metrics: .standard(width: 760))
        try expectEqual(result.rails.count, 4)  // feedback / project / user + 会话道
        try expect(result.rails.contains { $0.type == nil }, "会话道要有底轨（它没有 header 节点）")
        for rail in result.rails {
            let members = result.nodes.filter { rail.rect.intersects($0.frame) }
            try expect(!members.isEmpty, "底轨 \(rail.id) 是空的")
            for placed in members {
                try expect(
                    rail.rect.insetBy(dx: -1, dy: -1).contains(placed.frame),
                    "底轨 \(rail.id) 没包住 \(placed.node.title)")
            }
        }
    }

    t.test("视口塞不下泳道 → 画布变宽并置 overflowsViewport，而不是不画图") {
        let graph = MemoryGraphBuilder.build(library())
        let narrow = MemoryGraphLayout.layout(graph, metrics: .standard(width: 300))
        try expect(narrow.degraded == nil, "窄视口不是降级理由 —— 横向滚动就够了")
        try expect(narrow.overflowsViewport)
        try expect(narrow.canvasSize.width > 300)
        try expect(!narrow.nodes.isEmpty)
        let wide = MemoryGraphLayout.layout(graph, metrics: .standard(width: 1200))
        try expect(!wide.overflowsViewport)
        try expectEqual(wide.canvasSize.width, 1200)
    }

    t.test("节点过多 → tooManyNodes 降级（调用方退回列表）") {
        let many = MemoryGraphInput(
            title: "big",
            items: (0..<40).map { item("m\($0)", "记忆 \($0)", minutesAgo: Double($0)) })
        var metrics = MemoryGraphLayout.Metrics.standard(width: 760)
        metrics.maxNodes = 10
        let result = MemoryGraphLayout.layout(MemoryGraphBuilder.build(many), metrics: metrics)
        try expectEqual(result.degraded, .tooManyNodes(count: 41, limit: 10))
        try expect(result.nodes.isEmpty)
    }

    t.test("空图 / 只有一条记忆都不崩") {
        try expect(MemoryGraphBuilder.build(
            MemoryGraphInput(title: "空", items: [])).isEmpty)
        let single = MemoryGraphBuilder.build(
            MemoryGraphInput(title: "单条", items: [item("only", "only")]))
        let result = MemoryGraphLayout.layout(single, metrics: .compact(width: 320))
        try expectEqual(result.nodes.count, 2)  // 分类头 + 条目
        try expect(result.canvasSize.height > 0)
    }
}

private func require<T>(_ value: T?) throws -> T {
    guard let value else { throw ExpectationError(description: "期望非 nil") }
    return value
}
