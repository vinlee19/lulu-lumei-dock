import EurekaIngest
import EurekaKit
import Foundation

/// TurnSlicer: flat message stream → per-turn TurnInput. Turn boundary = a real user message.
func turnSlicerTests(_ t: TestRunner) {
    t.suite("TurnSlicer · 切轮")

    func message(
        _ id: Int, _ role: TranscriptMessage.Role, _ text: String = "",
        steps: [ToolStep] = [], at seconds: Double? = nil
    ) -> TranscriptMessage {
        TranscriptMessage(
            id: id, role: role, text: text,
            timestamp: seconds.map { Date(timeIntervalSince1970: $0) }, steps: steps)
    }

    t.test("Claude 形态：user → trail → assistant，两轮各自独立") {
        let turns = TurnSlicer.slice([
            message(0, .user, "修一下分页", at: 100),
            message(1, .turnTrail, steps: [
                ToolStep(kind: .search, name: "Grep", detail: "paginationBar", batch: 1),
                ToolStep(kind: .read, name: "Read", detail: "/w/A.swift", batch: 1),
                ToolStep(kind: .edit, name: "Edit", detail: "/w/A.swift", batch: 2),
            ], at: 110),
            message(2, .assistant, "改好了", at: 160),
            message(3, .user, "再跑下测试", at: 200),
            message(4, .turnTrail, steps: [
                ToolStep(kind: .command, name: "Bash", detail: "swift test", isError: true),
            ], at: 210),
            message(5, .assistant, "失败了", at: 240),
        ])

        try expectEqual(turns.count, 2)
        try expectEqual(turns[0].turnIndex, 0)
        try expectEqual(turns[0].promptMessageId, 0)
        try expectEqual(turns[0].promptText, "修一下分页")
        try expectEqual(turns[0].steps.count, 3)
        try expectEqual(turns[0].answerText, "改好了")
        try expectEqual(turns[0].duration, 60, "轮耗时 = 首末时间戳之差")

        // Batches pass through unchanged (the parallelism criterion); stepIndex is contiguous
        try expectEqual(turns[0].steps.map(\.batch), [1, 1, 2])
        try expectEqual(turns[0].steps.map(\.stepIndex), [0, 1, 2])
        // Every step remembers which message it belongs to (used to jump from a node to its
        // message)
        try expect(turns[0].steps.allSatisfy { $0.messageId == 1 })

        try expectEqual(turns[1].turnIndex, 1)
        try expectEqual(turns[1].steps.count, 1)
        try expect(turns[1].steps[0].isError)
        try expectEqual(turns[1].steps[0].stepIndex, 0, "每轮的 stepIndex 从 0 重新起")
    }

    t.test("思考正文按轮归集（Codex/Kimi/Qwen 有，Claude 恒空）") {
        let turns = TurnSlicer.slice([
            message(0, .user, "为什么慢", at: 10),
            message(1, .thinking, "先看热路径", at: 11),
            message(2, .turnTrail, steps: [
                ToolStep(kind: .read, name: "Read", detail: "/w/A.swift"),
            ], at: 12),
            message(3, .thinking, "再确认一下缓存", at: 13),
            message(4, .assistant, "是缓存没命中", at: 20),
        ])
        try expectEqual(turns.count, 1)
        try expectEqual(turns[0].thinkingTexts, ["先看热路径", "再确认一下缓存"])

        // Claude has no thinking messages → always empty; the engine uses a "fork" instead of
        // faking a thinking node
        let claudeLike = TurnSlicer.slice([
            message(0, .user, "改一下"),
            message(1, .turnTrail, steps: [ToolStep(kind: .edit, name: "Edit", detail: "/w/A")]),
        ])
        try expect(claudeLike[0].thinkingTexts.isEmpty)
    }

    t.test("无 trail 的源：🔧 小注也成步，剥掉 emoji 前缀") {
        let turns = TurnSlicer.slice([
            message(0, .user, "看下这个库"),
            message(1, .toolNote, "🔧 read_file"),
            message(2, .toolNote, "🔧 grep"),
            message(3, .assistant, "看完了"),
        ])
        try expectEqual(turns.count, 1)
        try expectEqual(turns[0].steps.map(\.name), ["read_file", "grep"])
        try expectEqual(
            turns[0].steps.map(\.batch), [0, 1],
            "小注天然串行（每条一次输出），批次各不相同")
    }

    t.test("多段回答拼接、错误单独收、时间戳单调") {
        let turns = TurnSlicer.slice([
            message(0, .user, "问", at: 1),
            message(1, .assistant, "第一段", at: 2),
            message(2, .error, "API Error: 529", at: 3),
            message(3, .assistant, "第二段", at: 4),
        ])
        try expectEqual(turns.count, 1)
        try expectEqual(turns[0].answerText, "第一段\n第二段")
        try expectEqual(turns[0].answerMessageIds, [1, 3])
        try expectEqual(turns[0].errorTexts, ["API Error: 529"])
        try expectEqual(turns[0].duration, 3)
    }

    t.test("首条用户消息之前的内容不丢（会话恢复摘要归第 0 轮）") {
        let turns = TurnSlicer.slice([
            message(0, .assistant, "（恢复的上下文摘要）"),
            message(1, .user, "继续"),
            message(2, .assistant, "好"),
        ])
        try expectEqual(turns.count, 2)
        try expect(turns[0].promptMessageId == nil, "无提问的前置轮")
        try expectEqual(turns[0].answerText, "（恢复的上下文摘要）")
        try expectEqual(turns[1].promptMessageId, 1)
    }

    t.test("空输入 / 只有用户消息 / 无时间戳都不崩") {
        try expect(TurnSlicer.slice([]).isEmpty)

        // A prompt with no response at all still yields a turn (the user asked but the agent didn't
        // act, which is itself information)
        let onlyPrompt = TurnSlicer.slice([message(0, .user, "在吗")])
        try expectEqual(onlyPrompt.count, 1)
        try expectEqual(onlyPrompt[0].promptText, "在吗")
        try expect(onlyPrompt[0].duration == nil, "无时间戳不能拿 0 冒充耗时")
    }

    t.test("斜杠命令回显与任务通知不开新轮，但同条里的真实提问要留下") {
        let turns = TurnSlicer.slice([
            message(0, .user, "<command-name>/effort</command-name>"),
            message(1, .user, "<local-command-stdout>Set effort level to max</local-command-stdout>"),
            message(2, .user, "<task-notification>\n<task-id>abc</task-id>\n</task-notification>"),
            message(3, .user, "真正的提问"),
            message(4, .turnTrail, steps: [ToolStep(kind: .read, name: "Read", detail: "/w/a")]),
            message(5, .assistant, "答"),
        ])
        try expectEqual(turns.count, 1, "三条注入不该各开一轮，实得 \(turns.map(\.promptText))")
        try expectEqual(turns[0].promptText, "真正的提问")

        // A caveat is often followed by a real prompt — dropping the whole thing would drop the
        // prompt too
        let mixed = TurnSlicer.slice([
            message(0, .user, """
            <local-command-caveat>Caveat: 下面是本地命令输出</local-command-caveat>
            <command-name>/plan</command-name>
            <local-command-stdout>Enabled plan mode</local-command-stdout>
            帮我看下分页这块
            """),
            message(1, .assistant, "好"),
        ])
        try expectEqual(mixed.count, 1)
        try expectEqual(mixed[0].promptText, "帮我看下分页这块")

        // An unclosed one (content truncated) must still be treated as an injection, not leak
        // through as a prompt
        let truncated = TurnSlicer.slice([
            message(0, .user, "<system-reminder>提示被截断了没有结尾"),
            message(1, .assistant, "答"),
        ])
        try expect(
            truncated.first?.promptMessageId == nil,
            "未闭合的注入块不该被当成提问")
    }

    t.test("真 fixture：与 loadClaude 的轮数一致") {
        let path = try fixtureURL("claude-transcript-trail.jsonl").path
        let result = TranscriptReader.loadClaude(path: path, maxMessages: 2000)
        let turns = TurnSlicer.slice(result.messages)
        // The fixture has 2 real user prompts → 2 turns
        try expectEqual(turns.count, 2)
        try expectEqual(turns[0].steps.count, 7)
        try expectEqual(turns[1].steps.count, 1)
        // Batches: multiple tool_use blocks in the same assistant message must share a batch
        let batches = Set(turns[0].steps.map(\.batch))
        try expect(!batches.isEmpty)
        try expect(turns[0].steps.contains { $0.isError }, "失败标记应随步骤带过来")
    }

    t.test("Codex 真 turn_id 切轮：同轮内不断开、换 turn_id 才开新轮") {
        // turn_id sits under internal_chat_message_metadata_passthrough (observed across 15 line
        // types). Key point: **there's no user message between the two tool calls**, only turn_id
        // changes — the old logic (looking only at user messages) merged them into one turn; the
        // new logic must split them.
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-codex-turnid-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: path) }
        // Build lines with JSONSerialization to avoid getting hand-written nested escapes wrong
        func line(turn: String, callId: String, cmd: String) throws -> String {
            let payload: [String: Any] = [
                "type": "custom_tool_call", "name": "exec", "call_id": callId,
                "input": "await tools.exec_command({cmd: \"\(cmd)\"})",
                "internal_chat_message_metadata_passthrough": ["turn_id": turn],
            ]
            let root: [String: Any] = [
                "type": "response_item",
                "timestamp": "2026-07-27T10:00:00.000Z",
                "payload": payload,
            ]
            let data = try JSONSerialization.data(withJSONObject: root)
            return String(decoding: data, as: UTF8.self)
        }
        let lines = [
            try line(turn: "t-1", callId: "c1", cmd: "ls"),
            try line(turn: "t-1", callId: "c2", cmd: "pwd"),
            try line(turn: "t-2", callId: "c3", cmd: "whoami"),
        ]
        try lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)

        let result = TranscriptReader.loadCodex(path: path.path, maxMessages: 2000)
        let trails = result.messages.filter { $0.role == .turnTrail }
        try expectEqual(trails.count, 2, "turn_id 变化应开新轨迹，而不是并成一条")
        try expectEqual(trails[0].steps.map(\.detail), ["ls", "pwd"])
        try expectEqual(trails[1].steps.map(\.detail), ["whoami"])
        try expectEqual(trails[0].steps.map(\.callId), ["c1", "c2"])
    }

    t.test("真 fixture：Codex 轮数与 callId 传递") {
        let path = try fixtureURL("codex-rollout-trail.jsonl").path
        let result = TranscriptReader.loadCodex(path: path, maxMessages: 2000)
        let turns = TurnSlicer.slice(result.messages)
        try expectEqual(turns.count, 2)
        try expectEqual(turns[0].steps.count, 3)
        try expect(
            turns[0].steps.contains { $0.callId != nil },
            "function_call 的 call_id 应传到 TurnInput.Step（与结果行配对用）")
    }
}
