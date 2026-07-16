import EurekaIngest
import EurekaKit
import Foundation

func claudeAuditDecoderTests(_ t: TestRunner) {
    t.suite("ClaudeAuditDecoder · Claude 审计解码")

    let now = Date(timeIntervalSince1970: 1_700_000_000)

    t.test("PostToolUse Bash → command 审计事件") {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse",
            "session_id": "s1",
            "cwd": "/w",
            "tool_name": "Bash",
            "tool_input": ["command": "sudo rm -rf /tmp/x"],
        ]
        let event = ClaudeAuditDecoder.decode(payload: payload, receivedAt: now)
        try expect(event != nil)
        try expectEqual(event?.source, .claude)
        try expectEqual(event?.sessionId, "s1")
        try expectEqual(event?.kind, .command)
        try expectEqual(event?.tool, "Bash")
        try expectEqual(event?.detail, "sudo rm -rf /tmp/x")
        try expectEqual(event?.cwd, "/w")
    }

    t.test("非 PostToolUse / 缺字段 → nil") {
        try expect(ClaudeAuditDecoder.decode(
            payload: ["hook_event_name": "Stop", "session_id": "s1"], receivedAt: now) == nil)
        try expect(ClaudeAuditDecoder.decode(
            payload: ["hook_event_name": "PostToolUse", "tool_name": "Bash"], receivedAt: now) == nil,
            "缺 session_id 应返回 nil")
    }

    t.test("tool_response.is_error 嗅探") {
        func decode(_ resp: [String: Any]) -> AuditEvent? {
            ClaudeAuditDecoder.decode(payload: [
                "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
                "tool_input": ["command": "false"], "tool_response": resp,
            ], receivedAt: now)
        }
        try expect(decode(["is_error": true])?.isError == true)
        try expect(decode(["stdout": "ok"])?.isError == false)
    }

    t.test("opId：无 tool_use_id 时合成键——同调用稳定、异毫秒相异") {
        let payload: [String: Any] = [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "ls"],
        ]
        let a = ClaudeAuditDecoder.decode(payload: payload, receivedAt: now)?.opId
        let aSame = ClaudeAuditDecoder.decode(payload: payload, receivedAt: now)?.opId
        let bLater = ClaudeAuditDecoder.decode(
            payload: payload, receivedAt: now.addingTimeInterval(0.5))?.opId
        try expectEqual(a, aSame, "同 payload 同时刻应得同 opId（重放稳定）")
        try expect(a != bLater, "不同毫秒的同命令应得不同 opId")
        try expect(a?.hasPrefix("claude:") == true)
    }

    t.test("显式 tool_use_id 优先") {
        let event = ClaudeAuditDecoder.decode(payload: [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "ls"], "tool_use_id": "toolu_123",
        ], receivedAt: now)
        try expectEqual(event?.opId, "toolu_123")
    }

    // SpoolConsumer rawObserver → ClaudeAuditDecoder 的接线（EventPipeline 用同一逻辑）
    t.test("SpoolConsumer rawObserver 只对 claude-hook 通道产审计事件") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-auditwire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: SpoolPaths.eventsDir(root: root), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: SpoolPaths.processingDir(root: root), withIntermediateDirectories: true)

        func write(_ name: String, channel: String, payload: [String: Any]) throws {
            let envelope: [String: Any] = [
                "v": 1, "channel": channel,
                "receivedAtMs": Int(Date().timeIntervalSince1970 * 1000),
                "payload": payload,
            ]
            try JSONSerialization.data(withJSONObject: envelope)
                .write(to: SpoolPaths.eventsDir(root: root).appendingPathComponent(name))
        }
        try write("001.json", channel: "claude-hook", payload: [
            "hook_event_name": "PostToolUse", "session_id": "s1", "tool_name": "Bash",
            "tool_input": ["command": "git push --force"],
        ])
        try write("002.json", channel: "codex-notify", payload: [
            "type": "agent-turn-complete", "thread-id": "c1",
        ])

        var audited: [AuditEvent] = []
        let rawObserver: SpoolConsumer.RawObserver = { raw, _ in
            guard raw.channel == "claude-hook",
                  let event = ClaudeAuditDecoder.decode(
                    payload: raw.payload, receivedAt: raw.receivedAt)
            else { return }
            audited.append(event)
        }
        let consumer = SpoolConsumer(root: root, rawObserver: rawObserver) { _, _ in }
        consumer.drainOnce()

        try expectEqual(audited.count, 1, "只有 claude-hook 的 PostToolUse 应被审计")
        try expectEqual(audited.first?.detail, "git push --force")
    }
}
