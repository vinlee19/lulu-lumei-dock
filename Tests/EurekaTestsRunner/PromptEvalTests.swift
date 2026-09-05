import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func promptEvalTests(_ t: TestRunner) {
    t.suite("PromptStructure · 静态结构检测")

    t.test("验收字样/路径/指代开头/分节各自命中；空串为空集") {
        try expectEqual(PromptStructure.detect(""), [])
        try expect(PromptStructure.detect("改完跑一下测试，全部通过才算完")
            .contains(.acceptance))
        try expect(PromptStructure.detect("run the tests and make sure tests pass")
            .contains(.acceptance))
        try expect(PromptStructure.detect("看下 Sources/EurekaApp/PromptsService.swift 的 refresh")
            .contains(.filePath))
        try expect(!PromptStructure.detect("修一下分页越界的问题").contains(.filePath))
        try expect(PromptStructure.detect("这个不太对，帮我看看").contains(.deicticStart))
        try expect(!PromptStructure.detect("帮我看看这个").contains(.deicticStart))
        let sectioned = PromptStructure.detect("# 目标\n- 需求一\n- 需求二")
        try expect(sectioned.contains(.sectioned))
        try expect(!PromptStructure.detect("- 只有一个列表项").contains(.sectioned))
    }

    t.test("Flags 编解码往返；未知字母容错") {
        let flags: PromptStructure.Flags = [.acceptance, .deicticStart]
        try expectEqual(PromptStructure.Flags.decode(flags.encoded), flags)
        try expectEqual(PromptStructure.Flags.decode("a,x,s"), [.acceptance, .sectioned])
    }

    t.suite("PromptFollowupSignal · 纠偏与重述")

    t.test("纠偏词表：命中与非命中") {
        try expect(PromptFollowupSignal.isCorrective("不对，你理解错了我的意思"))
        try expect(PromptFollowupSignal.isCorrective("still broken after your fix"))
        try expect(PromptFollowupSignal.isCorrective("撤销刚才的改动"))
        try expect(!PromptFollowupSignal.isCorrective("继续"))
        try expect(!PromptFollowupSignal.isCorrective("重新拉取最新的代码"),
            "「重新」单独出现常是正常新指令，词表用复合短语")
    }

    t.test("分词：CJK bigram + 拉丁按词；混排都出 token") {
        let tokens = PromptFollowupSignal.tokens("修复 login 超时 bug")
        try expect(tokens.contains("login"))
        try expect(tokens.contains("bug"))
        try expect(tokens.contains("修复"))
        try expect(tokens.contains("超时"))
    }

    t.test("重述消歧：逐字重发/换词打转=挣扎；加词展开=探索；新话题/超短句=none") {
        // 逐字重发 = 挣扎（removed=added=0，替换主导判据含等号）
        try expectEqual(
            PromptFollowupSignal.reformulation(
                prev: "把分页逻辑改成游标式的实现", next: "把分页逻辑改成游标式的实现"),
            .struggle)
        // 换词绕同一目标 = 挣扎
        try expectEqual(
            PromptFollowupSignal.reformulation(
                prev: "把分页逻辑改成游标式的实现方式", next: "把分页逻辑换成游标式的写法实现"),
            .struggle)
        // 原话上加约束展开 = 探索
        try expectEqual(
            PromptFollowupSignal.reformulation(
                prev: "把分页逻辑改成游标式",
                next: "把分页逻辑改成游标式，注意保持越界回退与空页语义兼容"),
            .explore)
        // 完全新话题 = none
        try expectEqual(
            PromptFollowupSignal.reformulation(
                prev: "把分页逻辑改成游标式", next: "帮我写一份周报的模板"),
            PromptFollowupSignal.Reformulation.none)
        // 超短句不判
        try expectEqual(
            PromptFollowupSignal.reformulation(prev: "继续", next: "继续"),
            PromptFollowupSignal.Reformulation.none)
    }

    t.suite("PromptEvaluator · 能力档与升级规则")

    func turn(
        _ prompt: String, steps: [TurnInput.Step] = [], errors: [String] = [],
        started: Double? = 100, ended: Double? = 160
    ) -> TurnInput {
        TurnInput(
            turnIndex: 0, promptMessageId: 1, promptText: prompt,
            steps: steps, errorTexts: errors,
            startedAt: started.map { Date(timeIntervalSince1970: $0) },
            endedAt: ended.map { Date(timeIntervalSince1970: $0) })
    }

    t.test("能力档：四档划分；excluded 返 nil") {
        try expectEqual(PromptEvalCapability.level(for: .claude), .full)
        try expectEqual(PromptEvalCapability.level(for: .qoder), .full)
        try expectEqual(PromptEvalCapability.level(for: .zcode), .trajectory)
        try expectEqual(PromptEvalCapability.level(for: .gemini), .followupOnly)
        try expectEqual(PromptEvalCapability.level(for: .trae), .excluded)
        try expect(PromptEvaluator.evaluate(
            promptId: "trae:s:1", turn: turn("提问"), diagnostics: nil,
            nextPromptText: "不对", capability: .excluded) == nil)
    }

    t.test("升级规则：纠偏→notice；挣扎→notice；纠偏+挣扎→bad；纠偏+报错→bad；探索不升级") {
        func severity(next: String?, errors: [String] = []) -> TurnDiagnostics.Severity? {
            PromptEvaluator.evaluate(
                promptId: "claude:s:1",
                turn: turn("把分页逻辑改成游标式的完整实现", errors: errors),
                diagnostics: nil, nextPromptText: next, capability: .full)?.severity
        }
        try expectEqual(severity(next: nil), .clean)
        try expectEqual(severity(next: "写一份周报模板"), .clean)
        try expectEqual(severity(next: "不对，你理解错了"), .notice)
        // 挣扎重述（换词重问同一件事）
        try expectEqual(severity(next: "把分页逻辑换成游标式的完整写法"), .notice)
        // 纠偏 + 挣扎同现 → bad
        try expectEqual(severity(next: "不对，把分页逻辑换成游标式的完整写法"), .bad)
        // 纠偏 + 报错结局 → bad
        try expectEqual(severity(next: "不对，你理解错了", errors: ["API error"]), .bad)
        // 探索展开不升级
        try expectEqual(
            severity(next: "把分页逻辑改成游标式的完整实现，另外注意越界回退语义与空页兼容测试"),
            .clean)
    }

    t.test("计量与证据：步数/失败步/时长/结局/规则 id 追加") {
        let steps = [
            TurnInput.Step(kind: .other, name: "Read", detail: ""),
            TurnInput.Step(kind: .other, name: "Bash", detail: "", isError: true),
        ]
        let eval = PromptEvaluator.evaluate(
            promptId: "claude:s:1",
            turn: turn("改完跑一下测试确保全部通过", steps: steps, errors: ["boom"]),
            diagnostics: nil, nextPromptText: "不对，还是有问题",
            capability: .trajectory)
        try expectEqual(eval?.stepCount, 2)
        try expectEqual(eval?.errorSteps, 1)
        try expectEqual(eval?.duration, 60)
        try expectEqual(eval?.outcome, "error")
        try expectEqual(eval?.severity, .bad, "纠偏+报错结局")
        try expect(eval?.ruleIds.contains("corrective") == true)
        try expect(eval?.ruleIds.contains("outcome-error") == true)
        try expect(eval?.structureFlags.contains(.acceptance) == true)
    }

    t.test("轮内诊断基线：反问澄清（AskUserQuestion）给 notice，叠加纠偏保持证据齐全") {
        let clarifyTurn = turn(
            "帮我改一下配置",
            steps: [TurnInput.Step(kind: .other, name: "AskUserQuestion", detail: "")])
        let diagnostics = TurnDiagnostics.evaluate(
            TurnGraphBuilder.build(clarifyTurn), promptChars: 7)
        try expectEqual(diagnostics.severity, .notice, "clarify 规则应命中")
        let eval = PromptEvaluator.evaluate(
            promptId: "claude:s:1", turn: clarifyTurn, diagnostics: diagnostics,
            nextPromptText: nil, capability: .full)
        try expectEqual(eval?.severity, .notice)
        try expect(eval?.ruleIds.contains("clarify") == true)
    }

    t.suite("PromptsRepo · 评价存取与迁移")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-eval-\(UUID()).sqlite")
    }

    t.test("upsertEval / evalMap 往返；全列覆盖") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let eval = PromptEval(
            promptId: "claude:s:1", severity: .bad,
            ruleIds: ["reread", "corrective"],
            stepCount: 12, errorSteps: 2, duration: 61.5,
            reformulated: .struggle, corrective: true, outcome: "error",
            structureFlags: [.acceptance, .filePath])
        try store.prompts.upsertEval([eval])
        try expectEqual(try store.prompts.evalMap()["claude:s:1"], eval)
        // 覆盖更新（纯派生，无用户列要保）
        var updated = eval
        updated.severity = .clean
        updated.ruleIds = []
        updated.corrective = false
        updated.duration = nil
        try store.prompts.upsertEval([updated])
        try expectEqual(try store.prompts.evalMap()["claude:s:1"], updated)
    }

    t.test("v23→v24 迁移：prompt_eval 随 DROP 块重建为空，prompts 用户标注保留") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            let store = try EurekaStore(path: path)
            try store.prompts.upsertExtracted([PromptEntry(
                id: "claude:s:0", source: .claude, sessionId: "s", messageIdx: 0,
                text: "留下来", timestamp: nil, cwd: nil,
                firstSeen: Date(timeIntervalSince1970: 100))])
            try store.prompts.setFavorite("claude:s:0", favorite: true)
            try store.prompts.upsertEval([PromptEval(
                promptId: "claude:s:0", severity: .notice, ruleIds: ["corrective"],
                stepCount: 1, errorSteps: 0, duration: nil,
                reformulated: .none, corrective: true, outcome: "clean",
                structureFlags: [])])
            try store.db.execute("PRAGMA user_version = 23")
        }
        let reopened = try EurekaStore(path: path)
        let rebuiltEvals = try reopened.prompts.evalMap()
        try expect(rebuiltEvals.isEmpty, "派生表升级必须重建为空")
        let kept = try reopened.prompts.all()
        try expectEqual(kept.count, 1)
        try expect(kept[0].favorite, "用户标注绝不能随升级丢失")
    }

    t.suite("PromptExtractor · messages 重载与评价对齐")

    t.test("重载与原入口等价；评价按 messageIdx 对齐且只评入库的 prompt") {
        let messages: [TranscriptMessage] = [
            TranscriptMessage(
                id: 0, role: .user, text: "修复分页越界并补测试",
                timestamp: Date(timeIntervalSince1970: 100)),
            TranscriptMessage(
                id: 1, role: .assistant, text: "好的",
                timestamp: Date(timeIntervalSince1970: 130)),
            TranscriptMessage(
                id: 2, role: .user, text: "不对，你理解错了我的意思",
                timestamp: Date(timeIntervalSince1970: 200)),
        ]
        let session = AgentSessionInfo(
            source: .claude, id: "s-align", cwd: "/w/p", name: nil,
            lastActiveAt: Date(), sizeBytes: 0, transcriptPath: "/dev/null")
        let entries = PromptExtractor.extract(
            messages: messages, session: session, at: Date(timeIntervalSince1970: 500))
        try expectEqual(entries.map(\.messageIdx), [0, 2])

        let turns = TurnSlicer.slice(messages)
        try expectEqual(turns.compactMap(\.promptMessageId), [0, 2])
        // 第一轮的下一条提问是纠偏 → notice
        let first = PromptEvaluator.evaluate(
            promptId: entries[0].id, turn: turns[0], diagnostics: nil,
            nextPromptText: turns[1].promptText, capability: .full)
        try expectEqual(first?.severity, .notice)
        try expect(first?.corrective == true)
    }
}
