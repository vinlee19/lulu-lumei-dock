import EurekaKit
import Foundation

/// TurnDiagnostics：图的形状 → 提示词问题。每条信号都要能指回一个可执行的改进动作。
func turnDiagnosticsTests(_ t: TestRunner) {
    t.suite("TurnDiagnostics · 逐轮诊断")

    func step(
        _ kind: ToolKind, _ name: String, _ detail: String = "",
        batch: Int, index: Int, isError: Bool = false
    ) -> TurnInput.Step {
        TurnInput.Step(
            kind: kind, name: name, detail: detail, isError: isError,
            batch: batch, messageId: 1, stepIndex: index)
    }

    func evaluate(_ turn: TurnInput) -> TurnDiagnostics {
        TurnDiagnostics.evaluate(
            TurnGraphBuilder.build(turn), promptChars: turn.promptText.count)
    }

    t.test("干净的一轮：不产生任何信号") {
        let clean = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "把 A.swift 里的 foo 改成 bar",
            steps: [
                step(.read, "Read", "/w/A.swift", batch: 1, index: 0),
                step(.edit, "Edit", "/w/A.swift", batch: 2, index: 1),
                step(.command, "Bash", "swift build", batch: 3, index: 2),
            ],
            answerMessageIds: [1], answerText: "改好了"))
        try expect(clean.signals.isEmpty, "实得 \(clean.signals.map(\.rule))")
        try expectEqual(clean.severity, .clean)
    }

    t.test("探索开销比：只在步数够多时才判，短轮不误报") {
        // 短轮：2 步里 2 步检索，比例 100% 但不该报（样本太小）
        let short = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "找找",
            steps: [
                step(.search, "Grep", "a", batch: 1, index: 0),
                step(.read, "Read", "/w/a.swift", batch: 2, index: 1),
            ]))
        try expect(!short.signals.contains { $0.rule == "explore-heavy" })

        // 长轮：8 个节点里 6 个在找 → 报「大半轮在找文件」
        var steps: [TurnInput.Step] = []
        for index in 0..<6 {
            steps.append(step(.search, "Grep", "p\(index)", batch: index + 1, index: index))
        }
        steps.append(step(.edit, "Edit", "/w/a.swift", batch: 7, index: 6))
        steps.append(step(.command, "Bash", "swift build", batch: 8, index: 7))
        let heavy = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改个东西", steps: steps))
        let signal = try expectSome(heavy.signals.first { $0.rule == "explore-heavy" })
        try expectEqual(signal.severity, .bad)
        try expect(signal.advice.contains("点名文件"), "信号必须给出可执行的改法")
        try expect(heavy.exploreRatio > 0.5)
    }

    t.test("回读：同一文件被反复回看 → 上下文没一次给够") {
        // Edit 之后再 Read 同一文件，构成回读回边
        var steps: [TurnInput.Step] = []
        var index = 0
        for round in 0..<4 {
            steps.append(step(.read, "Read", "/w/A.swift", batch: index + 1, index: index))
            index += 1
            steps.append(step(.edit, "Edit", "/w/A.swift", batch: index + 1, index: index))
            index += 1
            _ = round
        }
        let result = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改", steps: steps))
        let signal = try expectSome(result.signals.first { $0.rule == "reread" })
        try expect(result.rereadCount >= 1)
        try expect(signal.advice.contains("一次性给全"))
    }

    t.test("重试：构建反复失败 → 验收标准不清") {
        var steps: [TurnInput.Step] = []
        var index = 0
        for _ in 0..<4 {
            steps.append(step(.edit, "Edit", "/w/A.swift", batch: index + 1, index: index))
            index += 1
            steps.append(step(
                .command, "Bash", "swift build", batch: index + 1, index: index, isError: true))
            index += 1
        }
        let result = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "修构建", steps: steps))
        try expect(result.retryMax >= 1)
        let signal = try expectSome(result.signals.first { $0.rule == "retry" })
        try expect(signal.advice.contains("验证命令") || signal.advice.contains("怎样算成功"))
    }

    t.test("反复改同一文件：不产生回边，但必须报出来") {
        // 真实会话里出现过 `Edit X.java ×8`。连续同文件编辑不产生任何回边，
        // 只看边的规则会完全漏掉这个很强的「没想清就动手」信号。
        var steps: [TurnInput.Step] = []
        for index in 0..<6 {
            steps.append(step(.edit, "Edit", "/w/Parser.java", batch: index + 1, index: index))
        }
        let result = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改一下解析", steps: steps))
        try expectEqual(result.maxEditChurn, 6)
        try expectEqual(result.churnTarget, "Parser.java")
        let signal = try expectSome(result.signals.first { $0.rule == "churn" })
        try expectEqual(signal.severity, .bad)
        try expect(signal.advice.contains("Parser.java"), "建议要指名道姓，否则没法执行")
        try expect(result.rereadCount == 0, "连续同文件编辑本来就没有回边")

        // 改两次不该报（正常的分两步落笔）
        let twice = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改",
            steps: [
                step(.edit, "Edit", "/w/A.swift", batch: 1, index: 0),
                step(.edit, "Edit", "/w/A.swift", batch: 2, index: 1),
            ]))
        try expect(!twice.signals.contains { $0.rule == "churn" })
    }

    t.test("反问：AskUserQuestion 出现即记一次澄清往返") {
        let result = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改一下那个",
            steps: [
                step(.other, "AskUserQuestion", "改哪个？", batch: 1, index: 0),
            ]))
        try expect(result.askedUser)
        try expect(result.signals.contains { $0.rule == "clarify" })
    }

    t.test("聚合：按规则统计命中轮数，探索比只算够长的轮") {
        let good = evaluate(TurnInput(
            turnIndex: 0, promptMessageId: 0, promptText: "改 A",
            steps: [
                step(.read, "Read", "/w/A.swift", batch: 1, index: 0),
                step(.edit, "Edit", "/w/A.swift", batch: 2, index: 1),
            ]))
        var searchSteps: [TurnInput.Step] = []
        for index in 0..<7 {
            searchSteps.append(step(.search, "Grep", "p\(index)", batch: index + 1, index: index))
        }
        searchSteps.append(step(.edit, "Edit", "/w/B.swift", batch: 8, index: 7))
        let bad = evaluate(TurnInput(
            turnIndex: 1, promptMessageId: 0, promptText: "找找改改", steps: searchSteps))

        let summary = TurnDiagnosticsSummary([good, bad])
        try expectEqual(summary.turnCount, 2)
        try expectEqual(summary.cleanTurns, 1)
        try expectEqual(summary.badTurns, 1)
        try expectEqual(summary.ruleHits["explore-heavy"], 1)
        try expect(
            summary.averageExploreRatio > 0.5,
            "只有够长的那一轮参与平均，不该被短轮稀释：实得 \(summary.averageExploreRatio)")
    }

    t.test("空轮聚合不崩、不产生 NaN") {
        let summary = TurnDiagnosticsSummary([])
        try expectEqual(summary.turnCount, 0)
        try expectEqual(summary.averageExploreRatio, 0)
        let emptyTurn = TurnDiagnostics.evaluate(TurnGraph.Graph(turnIndex: 0), promptChars: 0)
        try expectEqual(emptyTurn.exploreRatio, 0, "0 节点不能除出 NaN")
    }
}
