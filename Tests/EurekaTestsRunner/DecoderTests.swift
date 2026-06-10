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

    t.test("未知 hook 名 / 缺 session_id 返回 nil") {
        try expect(ClaudeHookDecoder.decode(
            payload: ["hook_event_name": "PreCompact", "session_id": "x"], receivedAt: now) == nil)
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
