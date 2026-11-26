import EurekaIngest
import EurekaKit
import Foundation

func codexTitleTests(_ t: TestRunner) {
    t.suite("Codex 会话标题（新格式 UserMessage / 子代理）")

    func index(_ lines: [String]) throws -> AgentSessionInfo? {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cxtitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let day = root.appendingPathComponent(
            String(format: "%04d/%02d/%02d", parts.year!, parts.month!, parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try (lines.joined(separator: "\n") + "\n").write(
            to: day.appendingPathComponent(
                "rollout-2026-11-20T10-00-00-01a1aaaa-bbbb-7ccc-8ddd-eeeeffff0001.jsonl"),
            atomically: true, encoding: .utf8)
        return CodexSessionIndexer.index(sessionsRoot: root, threadNameIndexURL: root
            .appendingPathComponent("missing-session_index.jsonl")).first
    }

    let meta = #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"session_meta","payload":{"id":"t1","cwd":"/w"}}"#
    func userItem(_ contentJSON: String) -> String {
        #"{"timestamp":"2026-11-20T02:00:01.000Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","id":"u1","content":"#
            + contentJSON + "}}}"
    }

    t.test("新格式：取第一条 UserMessage，拆掉附件包装") {
        let session = try index([
            meta,
            // Injected context arrives as a response_item, never as a UserMessage item
            ##"{"timestamp":"2026-11-20T02:00:00.500Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions"}]}}"##,
            userItem(##"[{"type":"text","text":"\n# Files mentioned by the user:\n\n## a.png: /tmp/a.png\n\n## My request:\n制作一张点赞的图片\n"}]"##),
            userItem(#"[{"type":"text","text":"第二个问题"}]"#),
        ])
        try expectEqual(session?.id, "t1")
        try expectEqual(session?.name, "制作一张点赞的图片")
    }

    t.test("新格式：提问在 64 KB 之后也能取到") {
        let padding = #"{"timestamp":"2026-11-20T02:00:00.600Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":""#
            + String(repeating: "x", count: 80_000) + #""}]}}"#
        let session = try index([meta, padding, userItem(#"[{"type":"text","text":"深处的提问"}]"#)])
        try expectEqual(session?.name, "深处的提问")
    }

    t.test("子代理用身份命名，不取复制来的父会话提问") {
        let spawned = try index([
            #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/w","thread_source":"subagent","agent_nickname":"Erdos","agent_path":"/root/bind_outcome_audit","source":{"subagent":{"thread_spawn":{"depth":1}}}}}"#,
            userItem(#"[{"type":"text","text":"父会话的提问"}]"#),
        ])
        try expectEqual(spawned?.name, "Erdos · bind_outcome_audit")

        let guardian = try index([
            #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"session_meta","payload":{"id":"g1","cwd":"/w","thread_source":"subagent","source":{"subagent":{"other":"guardian"}}}}"#,
            userItem(#"[{"type":"text","text":"The following is the Codex agent history"}]"#),
        ])
        try expectEqual(guardian?.name, "Guardian 审查")
    }

    t.test("旧格式 user_message 仍然有效") {
        let session = try index([
            meta,
            #"{"timestamp":"2026-11-20T02:00:01.000Z","type":"event_msg","payload":{"type":"user_message","message":"旧格式的提问"}}"#,
        ])
        try expectEqual(session?.name, "旧格式的提问")
    }
}
