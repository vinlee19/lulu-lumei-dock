import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func sessionContentProbeTests(_ t: TestRunner) {
    t.suite("SessionContentProbe（隐藏空会话）")

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-emptyprobe-\(UUID().uuidString)", isDirectory: true)
    let noCatalog = AntigravityConversationCatalog(databases: { [] })

    func session(_ source: AgentSource, _ name: String, lines: [String]) throws -> AgentSessionInfo {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let body = lines.joined(separator: "\n") + "\n"
        try body.write(to: url, atomically: true, encoding: .utf8)
        return AgentSessionInfo(
            source: source, id: name, cwd: nil, name: nil, lastActiveAt: Date(),
            sizeBytes: UInt64(body.utf8.count), transcriptPath: url.path)
    }

    t.test("Codex 只有 session_meta 的 rollout 是空会话") {
        let s = try session(.codex, "rollout-empty.jsonl", lines: [
            #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"session_meta","payload":{"id":"e1","cwd":"/w"}}"#,
            #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"turn_context","payload":{"cwd":"/w"}}"#,
        ])
        try expectEqual(SessionContentProbe.hasConversation(s, catalog: noCatalog), false)
    }

    t.test("只有模型回复的子代理 rollout 不算空") {
        let s = try session(.codex, "rollout-subagent.jsonl", lines: [
            #"{"timestamp":"2026-11-20T02:00:00.000Z","type":"session_meta","payload":{"id":"s1","cwd":"/w"}}"#,
            #"{"timestamp":"2026-11-20T02:00:01.000Z","type":"event_msg","payload":{"type":"agent_message","message":"Checked the tests; all pass."}}"#,
        ])
        try expectEqual(SessionContentProbe.hasConversation(s, catalog: noCatalog), true)
    }

    t.test("Claude 只有提问没有回复（被打断）不算空") {
        let s = try session(.claude, "prompt-only.jsonl", lines: [
            #"{"type":"user","uuid":"u1","timestamp":"2026-11-20T02:00:00.000Z","message":{"role":"user","content":"fix the build"}}"#,
        ])
        try expectEqual(SessionContentProbe.hasConversation(s, catalog: noCatalog), true)
    }

    t.test("超过 64 KB 的文件不读，直接当有内容；trae 无从判断") {
        let small = try session(.codex, "rollout-big.jsonl", lines: ["{}"])
        let big = AgentSessionInfo(
            source: .codex, id: small.id, cwd: nil, name: nil, lastActiveAt: Date(),
            sizeBytes: SessionContentProbe.fileSizeLimit + 1, transcriptPath: small.transcriptPath)
        try expectEqual(SessionContentProbe.hasConversation(small, catalog: noCatalog), false)
        try expectEqual(SessionContentProbe.hasConversation(big, catalog: noCatalog), true)
        let trae = AgentSessionInfo(
            source: .trae, id: "t", cwd: nil, name: nil, lastActiveAt: Date(),
            sizeBytes: 0, transcriptPath: "/nonexistent")
        try expect(SessionContentProbe.hasConversation(trae, catalog: noCatalog) == nil)
    }
}
