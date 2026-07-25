import Foundation
import EurekaIngest
import EurekaKit

private func loadPayload(_ fixturePath: String) throws -> [String: Any] {
    let data = try fixtureData(fixturePath)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ExpectationError(description: "fixture 非 JSON object: \(fixturePath)")
    }
    return object
}

func decoderTests(_ t: TestRunner) {
    t.suite("ClaudeHookDecoder")
    let now = Date(timeIntervalSince1970: 1_780_000_000)

    t.test("UserPromptSubmit → taskStarted 带 prompt 标题") {
        let event = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/user-prompt-submit.json"), receivedAt: now)
        try expect(event != nil)
        try expectEqual(event!.sessionId, "fixture-session-1")
        try expectEqual(event!.cwd, "/Users/me/work/demo")
        guard case .taskStarted(let title) = event!.kind else {
            throw ExpectationError(description: "应为 taskStarted: \(event!.kind)")
        }
        try expectEqual(title, "帮我修复登录页在 Safari 上的报错")
    }

    t.test("Stop → taskFinished(success)") {
        let event = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/stop.json"), receivedAt: now)
        guard case .taskFinished(outcome: .success, _, _) = event!.kind else {
            throw ExpectationError(description: "应为 taskFinished(success)")
        }
        try expect(event!.transcriptPath?.hasSuffix("fixture-session-1.jsonl") == true)
    }

    t.test("Notification permission_prompt → waiting(permission)") {
        let event = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/notification-permission.json"), receivedAt: now)
        guard case .waiting(reason: .permission, _) = event!.kind else {
            throw ExpectationError(description: "应为 waiting(permission)")
        }
    }

    t.test("Notification idle_prompt → waiting(idle)") {
        let event = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/notification-idle.json"), receivedAt: now)
        guard case .waiting(reason: .idle, _) = event!.kind else {
            throw ExpectationError(description: "应为 waiting(idle)")
        }
    }

    t.test("Notification 非等待类型（auth_success）忽略") {
        var payload = try loadPayload("hook-payloads/notification-permission.json")
        payload["notification_type"] = "auth_success"
        payload["message"] = "Authenticated"
        try expect(ClaudeHookDecoder.decode(payload: payload, receivedAt: now) == nil)
    }

    t.test("没有 notification_type 时按 message 启发式分类") {
        var payload = try loadPayload("hook-payloads/notification-permission.json")
        payload.removeValue(forKey: "notification_type")
        let event = ClaudeHookDecoder.decode(payload: payload, receivedAt: now)
        guard case .waiting(reason: .permission, _) = event!.kind else {
            throw ExpectationError(description: "message 含 permission 应归为等待权限")
        }
    }

    t.test("PostToolUse → activity(tool)；SessionEnd → sessionEnded(reason)") {
        let activity = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/post-tool-use.json"), receivedAt: now)
        try expectEqual(activity!.kind, .activity(tool: "Bash"))

        let end = ClaudeHookDecoder.decode(
            payload: try loadPayload("hook-payloads/session-end.json"), receivedAt: now)
        try expectEqual(end!.kind, .sessionEnded(reason: "prompt_input_exit"))
    }

    t.test("PreToolUse：带出工具与具体对象（等待授权卡靠它说清在请求什么）") {
        let bash = ClaudeHookDecoder.decode(payload: [
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "tool_name": "Bash", "tool_input": ["command": "rm -rf build/"],
        ], receivedAt: now)
        try expectEqual(bash?.kind, .toolPending(tool: "Bash", detail: "rm -rf build/"))

        // 文件类取路径
        let edit = ClaudeHookDecoder.decode(payload: [
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "tool_name": "Edit", "tool_input": ["file_path": "/repo/src/main.swift"],
        ], receivedAt: now)
        try expectEqual(edit?.kind, .toolPending(tool: "Edit", detail: "/repo/src/main.swift"))

        // 多行命令只取首行（沿用 ToolStepExtractor 的既有裁剪口径）
        let multi = ClaudeHookDecoder.decode(payload: [
            "hook_event_name": "PreToolUse", "session_id": "s1",
            "tool_name": "Bash", "tool_input": ["command": "echo one\necho two"],
        ], receivedAt: now)
        try expectEqual(multi?.kind, .toolPending(tool: "Bash", detail: "echo one …"))

        // 无参数工具：detail 为 nil 而不是空串（UI 据此不拼多余的空格）
        let bare = ClaudeHookDecoder.decode(payload: [
            "hook_event_name": "PreToolUse", "session_id": "s1", "tool_name": "TodoWrite",
        ], receivedAt: now)
        try expectEqual(bare?.kind, .toolPending(tool: "TodoWrite", detail: nil))

        // 缺 tool_name 不该产出事件
        try expect(ClaudeHookDecoder.decode(payload: [
            "hook_event_name": "PreToolUse", "session_id": "s1",
        ], receivedAt: now) == nil)
    }

    t.test("PreCompact：解为压缩中（压缩期间没别的事件，岛上不标就像卡死）") {
        let event = ClaudeHookDecoder.decode(
            payload: ["hook_event_name": "PreCompact", "session_id": "s1"], receivedAt: now)
        try expectEqual(event?.kind, .compacting)
    }

    t.test("未知 hook 名 / 缺 session_id 返回 nil") {
        try expect(ClaudeHookDecoder.decode(
            payload: ["hook_event_name": "SubagentStop", "session_id": "x"], receivedAt: now) == nil)
        try expect(ClaudeHookDecoder.decode(
            payload: ["hook_event_name": "Stop"], receivedAt: now) == nil)
    }

    t.suite("CodexNotifyDecoder")

    t.test("agent-turn-complete → taskFinished 带标题/详情/turnId") {
        let event = CodexNotifyDecoder.decode(
            payload: try loadPayload("hook-payloads/codex-notify.json"), receivedAt: now)
        try expect(event != nil)
        try expectEqual(event!.source, .codex)
        try expectEqual(event!.sessionId, "fixture-codex-1")
        try expectEqual(event!.turnId, "turn-001")
        guard case .taskFinished(outcome: .success, let title, let detail) = event!.kind else {
            throw ExpectationError(description: "应为 taskFinished")
        }
        try expectEqual(title, "跑一下集成测试并修复失败用例")
        try expect(detail?.contains("集成测试全部通过") == true)
    }

    t.test("snake_case 字段名兼容") {
        let payload: [String: Any] = [
            "type": "agent-turn-complete",
            "thread_id": "t-snake",
            "turn_id": "turn-9",
            "input_messages": ["跑任务"],
            "last_assistant_message": "好了",
        ]
        let event = CodexNotifyDecoder.decode(payload: payload, receivedAt: now)
        try expectEqual(event!.sessionId, "t-snake")
        try expectEqual(event!.turnId, "turn-9")
    }

    t.test("非 agent-turn-complete 忽略") {
        try expect(CodexNotifyDecoder.decode(
            payload: ["type": "something-else"], receivedAt: now) == nil)
    }
}
