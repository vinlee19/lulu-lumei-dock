import Foundation
import EurekaKit
import EurekaIngest

func smokeTests(_ t: TestRunner) {
    t.suite("Smoke")

    t.test("模型类型基本不变量") {
        let task = AgentTask(
            source: .claude,
            sessionId: "s1",
            cwd: "/Users/me/work/demo",
            startedAt: Date(timeIntervalSince1970: 1000)
        )
        try expectEqual(task.id, "claude:s1")
        try expectEqual(task.projectName, "demo")
        try expect(IslandState.hidden.isVisible == false, "空状态应隐藏")
    }

    t.test("事件信封解析") {
        let json = """
        {"v":1,"channel":"inject","receivedAtMs":1718000000123,"payload":{"hook_event_name":"Stop","session_id":"abc"}}
        """
        let event = RawEvent(data: Data(json.utf8))
        try expect(event != nil, "信封应可解析")
        try expectEqual(event!.channel, "inject")
        try expectEqual(event!.payload["session_id"] as? String, "abc")
    }

    t.test("坏信封返回 nil 不抛错") {
        try expect(RawEvent(data: Data("not json".utf8)) == nil)
        try expect(RawEvent(data: Data("{}".utf8)) == nil)
    }

    t.test("fixtures 就位") {
        for path in [
            "claude-transcript-usage-dups.jsonl",
            "claude-transcript-api-error.jsonl",
            "codex-rollout-lifecycle.jsonl",
            "codex-rollout-compaction.jsonl",
            "hook-payloads/user-prompt-submit.json",
            "hook-payloads/stop.json",
            "hook-payloads/notification-permission.json",
            "configs/settings-with-env.json",
            "configs/config-with-tables.toml",
        ] {
            _ = try fixtureURL(path)
        }
    }
}
