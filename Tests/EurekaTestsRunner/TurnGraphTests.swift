import EurekaKit
import Foundation

/// TurnGraphBuilder：TurnInput → 血缘图。构图规则是一张可断言的规则表，不是「看情况」。
func turnGraphTests(_ t: TestRunner) {
    t.suite("TurnGraph · 构图")

    func step(
        _ kind: ToolKind, _ name: String, _ detail: String = "",
        batch: Int, index: Int, isError: Bool = false
    ) -> TurnInput.Step {
        TurnInput.Step(
            kind: kind, name: name, detail: detail, isError: isError,
            batch: batch, messageId: 1, stepIndex: index)
    }

    /// 验收形态：提问 → 思考 → {Grep, 子代理} → Read → Edit → build✗ → Edit → build✓ → 回答，
    /// 其中「回读同一文件」与「改→构建失败→再改」各构成一个环。
    func acceptedTurn() -> TurnInput {
        TurnInput(
            turnIndex: 6,
            promptMessageId: 0,
            promptText: "修一下审计页的分页",
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

    t.test("验收形态：思考分叉、回读环、重试环、汇聚到回答") {
        let graph = TurnGraphBuilder.build(acceptedTurn())

        // 去重：同一文件读两次 / 改两次 / 同一命令跑两次 各只有一个节点
        let titles = graph.nodes.map(\.title)
        try expectEqual(titles.filter { $0 == "Read" }.count, 1, "同文件重复读只有一个节点")
        try expectEqual(titles.filter { $0 == "Edit" }.count, 1)
        try expectEqual(titles.filter { $0 == "Bash" }.count, 1)

        let read = try expectSome(graph.nodes.first { $0.title == "Read" })
        try expectEqual(read.occurrences, 2, "回读次数体现在角标上")
        let build = try expectSome(graph.nodes.first { $0.title == "Bash" })
        try expectEqual(build.occurrences, 2)
        try expect(build.isError, "任一次失败该节点即标失败")

        // 思考节点存在且是分叉点（有明文 → 不插 fork）
        try expect(graph.hasThinking)
        let thinking = try expectSome(graph.nodes.first { $0.kind == .thinking })
        let fanOut = graph.edges.filter { $0.from == thinking.id && !$0.isBack }
        try expectEqual(fanOut.count, 2, "思考直接分叉出检索与子代理，不额外插 fork")
        try expect(!graph.nodes.contains { $0.kind == .fork })

        // 子代理是 spawn 边
        try expect(graph.edges.contains { $0.role == .spawn }, "派生子代理应是 spawn 边")

        // 两个环：回读（Edit→Read）与重试（Bash→Edit）
        try expect(
            graph.backEdges.contains { $0.role == .dataFlow && $0.to == read.id },
            "改完又回去读同一文件 → 回读回边")
        let edit = try expectSome(graph.nodes.first { $0.title == "Edit" })
        try expect(
            graph.backEdges.contains { $0.role == .retry && $0.from == build.id
                && $0.to == edit.id },
            "构建失败 → 指回编辑的重试回边")

        // 汇聚到回答
        let answer = try expectSome(graph.nodes.first { $0.kind == .answer })
        try expect(graph.edges.contains { $0.to == answer.id })
    }

    t.test("无思考明文（Claude）：不伪造思考节点，改插分叉点") {
        var turn = acceptedTurn()
        turn.thinkingTexts = []
        let graph = TurnGraphBuilder.build(turn)
        try expect(!graph.hasThinking)
        try expect(
            !graph.nodes.contains { $0.kind == .thinking },
            "拿不到思考正文时绝不能凭空造一个思考节点")
        try expect(
            graph.nodes.contains { $0.kind == .fork },
            "但并行分叉本身是可观测事实，用分叉点标出来")
    }

    t.test("seq 单调即拓扑序：前向边必然 from.seq < to.seq") {
        // ⚠️ 必须把**有分叉点**的形态也覆盖到：分叉是在它的分支之后才决定要不要插的，
        // 如果那时才取 seq，分叉的 seq 会大于分支 → 分层时孩子找不到已定层的父节点，
        // 整层被错排到第 0 层。曾经只测了有思考（不插分叉）的用例，正好漏掉这个。
        var noThinking = acceptedTurn()
        noThinking.thinkingTexts = []
        var parallel = acceptedTurn()
        parallel.thinkingTexts = []
        parallel.steps = [
            step(.read, "Read", "/w/a.swift", batch: 1, index: 0),
            step(.read, "Read", "/w/b.swift", batch: 1, index: 1),
            step(.read, "Read", "/w/c.swift", batch: 1, index: 2),
            step(.edit, "Edit", "/w/a.swift", batch: 2, index: 3),
            step(.edit, "Edit", "/w/b.swift", batch: 2, index: 4),
        ]

        for (label, turn) in [("有思考", acceptedTurn()), ("无思考", noThinking),
                              ("多对多", parallel)] {
            let graph = TurnGraphBuilder.build(turn)
            for edge in graph.forwardEdges {
                let from = try expectSome(graph.node(edge.from))
                let to = try expectSome(graph.node(edge.to))
                try expect(
                    from.seq < to.seq,
                    "\(label)：前向边 \(from.title)->\(to.title) 违反 seq 单调（分层的地基）")
            }
            for edge in graph.backEdges {
                let from = try expectSome(graph.node(edge.from))
                let to = try expectSome(graph.node(edge.to))
                try expect(to.seq <= from.seq, "\(label)：回边必须指向不更晚的节点")
            }
            // nodes 必须按 seq 有序（折叠与分层都依赖这个顺序）
            try expectEqual(
                graph.nodes.map(\.seq), graph.nodes.map(\.seq).sorted(),
                "\(label)：nodes 未按 seq 排序")
        }
    }

    t.test("分叉点必须排在它的分支之前（分层正确性的前提）") {
        var turn = acceptedTurn()
        turn.thinkingTexts = []
        let graph = TurnGraphBuilder.build(turn)
        let fork = try expectSome(graph.nodes.first { $0.kind == .fork })
        let children = graph.forwardEdges.filter { $0.from == fork.id }
            .compactMap { graph.node($0.to) }
        try expect(children.count >= 2, "分叉点至少要有两个分支")
        for child in children {
            try expect(fork.seq < child.seq, "分叉 seq 必须小于分支 \(child.title)")
        }
        let parents = graph.forwardEdges.filter { $0.to == fork.id }
            .compactMap { graph.node($0.from) }
        for parent in parents {
            try expect(parent.seq < fork.seq, "分叉的上游 seq 必须更小")
        }
    }

    t.test("确定性：同输入两次构图完全相等") {
        let turn = acceptedTurn()
        let first = TurnGraphBuilder.build(turn)
        let second = TurnGraphBuilder.build(turn)
        try expectEqual(first, second, "离屏渲染要拿它当基准，必须可复现")
    }

    t.test("折叠：同层同类兄弟超过列数上限就聚合，展开后还原") {
        var steps: [TurnInput.Step] = []
        for index in 0..<9 {
            steps.append(step(.search, "Grep", "pattern-\(index)", batch: 1, index: index))
        }
        let turn = TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "找找看", steps: steps,
            answerMessageIds: [1], answerText: "找到了")

        let folded = TurnGraphBuilder.build(turn, options: .init(maxColumns: 4))
        let foldNode = try expectSome(folded.nodes.first { node in
            if case .folded = node.kind { return true }
            return false
        })
        try expectEqual(foldNode.foldedIDs.count, 9)
        try expect(foldNode.title.contains("×9"))
        try expect(
            !folded.nodes.contains { $0.title == "Grep" },
            "被折叠的成员不应再单独出现（否则层宽还是超）")

        let expanded = TurnGraphBuilder.build(
            turn, options: .init(maxColumns: 4, expandedFolds: [foldNode.id]))
        try expectEqual(expanded.nodes.filter { $0.title == "Grep" }.count, 9)
    }

    t.test("边数有上界：多对多阶段插分叉点，N×M 降成 N+M") {
        var steps: [TurnInput.Step] = []
        for index in 0..<3 {
            steps.append(step(.read, "Read", "/w/a\(index).swift", batch: 1, index: index))
        }
        for index in 0..<3 {
            steps.append(step(.edit, "Edit", "/w/b\(index).swift", batch: 2, index: 3 + index))
        }
        let graph = TurnGraphBuilder.build(
            TurnInput(turnIndex: 0, promptMessageId: 0, promptText: "批量改", steps: steps),
            options: .init(maxColumns: 6))
        let forks = graph.nodes.filter { $0.kind == .fork }
        try expect(!forks.isEmpty, "3→3 必须插分叉点，否则 9 条边")
        // 3→fork(1) + fork→3 = 6 条，而不是 9 条
        let between = graph.forwardEdges.filter { edge in
            graph.node(edge.from)?.kind == .tool(.read) || graph.node(edge.to)?.kind == .tool(.edit)
        }
        try expect(between.count <= 6, "实得 \(between.count) 条，应 ≤ N+M")
    }

    t.test("空轮 / 只有提问 / 无目标的工具都不崩") {
        let empty = TurnGraphBuilder.build(TurnInput(turnIndex: 0))
        try expect(empty.nodes.isEmpty)

        let onlyPrompt = TurnGraphBuilder.build(
            TurnInput(turnIndex: 0, promptMessageId: 0, promptText: "在吗"))
        try expectEqual(onlyPrompt.nodes.count, 1)
        try expectEqual(onlyPrompt.nodes[0].kind, .prompt)

        // TodoWrite 这类没有可比目标的工具：逐步骤独立，不该被错误合并
        let todos = TurnGraphBuilder.build(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "记一下",
            steps: [
                step(.other, "TodoWrite", "", batch: 1, index: 0),
                step(.other, "TodoWrite", "", batch: 2, index: 1),
            ]))
        try expectEqual(
            todos.nodes.filter { $0.title == "TodoWrite" }.count, 2,
            "无目标的工具不能靠名字合并（那会把两次不同的记录并成一次）")
    }

    t.test("子代理：收起显步数；展开后内部步骤并进同一张图并连出跨界回读边") {
        // 主流程先读了 A.swift，子代理内部又读了同一个 A.swift ——
        // 展开后这条「跨越子代理边界的回读」正是把它做成内联而不是独立子图的理由。
        var task = step(.agent, "Explore", "定位分页实现", batch: 2, index: 1)
        task.subSteps = [
            TurnInput.Step(kind: .search, name: "Grep", detail: "paginationBar", batch: 1),
            TurnInput.Step(kind: .read, name: "Read", detail: "/w/A.swift", batch: 2),
        ]
        let turn = TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "找分页",
            steps: [
                step(.read, "Read", "/w/A.swift", batch: 1, index: 0),
                task,
            ],
            answerMessageIds: [1], answerText: "找到了")

        // 收起：子代理是一个节点，副标带内部步数
        let collapsed = TurnGraphBuilder.build(turn)
        let agent = try expectSome(collapsed.nodes.first { $0.kind == .subagent })
        try expect(agent.subtitle.contains("2 步"), "收起态要能看出它干了多少活，实得 \(agent.subtitle)")
        try expect(
            !collapsed.nodes.contains { $0.title == "Grep" },
            "收起时不该把内部步骤铺出来")

        // 展开：内部步骤进图，且对同一文件的读命中去重 → 连出回读回边
        let expanded = TurnGraphBuilder.build(
            turn, options: .init(expandedSubagents: ["Explore|定位分页实现"]))
        try expect(expanded.nodes.contains { $0.title == "Grep" }, "展开后内部检索应进图")
        try expectEqual(
            expanded.nodes.filter { $0.title == "Read" }.count, 1,
            "子代理读的同一个文件必须与主流程合并成一个节点，否则看不出是回读")
        let read = try expectSome(expanded.nodes.first { $0.title == "Read" })
        try expectEqual(read.occurrences, 2)
        try expect(
            expanded.backEdges.contains { $0.role == .dataFlow && $0.to == read.id },
            "跨子代理边界的回读边必须存在 —— 这是内联展开的全部意义")

        // 子代理内部节点只能从子代理节点下来，不能被外层 frontier 再连一次
        // （否则会被错拉到与子代理同层，看上去像「主流程直接读的」）
        let grep = try expectSome(expanded.nodes.first { $0.title == "Grep" })
        let grepParents = expanded.forwardEdges.filter { $0.to == grep.id }
            .compactMap { expanded.node($0.from) }
        try expect(
            grepParents.allSatisfy { $0.kind == .subagent || $0.kind == .fork },
            "子代理内部步骤的上游只能是子代理（或它下面的分叉点），实得 "
                + "\(grepParents.map(\.title))")

        // 展开后 seq 仍是拓扑序（子代理内部也走 reserveSeq 分叉，容易破坏）
        for edge in expanded.forwardEdges {
            let from = try expectSome(expanded.node(edge.from))
            let to = try expectSome(expanded.node(edge.to))
            try expect(from.seq < to.seq, "展开子代理后 \(from.title)->\(to.title) 破坏了 seq 单调")
        }

        // 除了提问，每个节点都得有前向父节点。孤儿 = 被误判成回边后甩到第 0 层，
        // `forwardEdges` 的单调性检查抓不到这种（那条边根本不在 forwardEdges 里）。
        for node in expanded.nodes where node.kind != .prompt {
            let hasParent = expanded.forwardEdges.contains { $0.to == node.id }
            try expect(hasParent, "\(node.title) 没有前向父节点，会被甩到第 0 层")
        }
    }

    t.test("路径归一：尾斜杠不影响去重") {
        let graph = TurnGraphBuilder.build(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "读",
            steps: [
                step(.read, "Read", "/w/dir/", batch: 1, index: 0),
                step(.edit, "Edit", "/w/dir", batch: 2, index: 1),
                step(.read, "Read", "/w/dir", batch: 3, index: 2),
            ]))
        try expectEqual(graph.nodes.filter { $0.title == "Read" }.count, 1)
    }
}
