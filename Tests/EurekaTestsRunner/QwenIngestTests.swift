import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func qwenIngestTests(_ t: TestRunner) {
    t.suite("Qwen · 会话/对话/用量采集")

    /// 造最小 ~/.qwen 布局：projects/<encoded>/chats/<uuid>.jsonl + runtime.json
    func makeHome() throws -> (home: URL, chat: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("eureka-qwen-\(UUID())", isDirectory: true)
        let chats = home.appendingPathComponent(
            "projects/-work-my-proj/chats", isDirectory: true)
        try fm.createDirectory(at: chats, withIntermediateDirectories: true)
        let sessionId = "3dbdf6ce-5c3d-483c-b510-50e3e4ac4a6d"
        let chat = chats.appendingPathComponent("\(sessionId).jsonl")
        try #"{"schema_version":1,"session_id":"\#(sessionId)","work_dir":"/work/my-proj","started_at":1784643274.078}"#
            .write(to: chats.appendingPathComponent("\(sessionId).runtime.json"),
                   atomically: true, encoding: .utf8)
        let lines = [
            #"{"uuid":"u0","sessionId":"\#(sessionId)","timestamp":"2026-07-21T14:14:34.000Z","type":"system","cwd":"/work/my-proj","subtype":"file_history_snapshot","systemPayload":{}}"#,
            #"{"uuid":"u1","sessionId":"\#(sessionId)","timestamp":"2026-07-21T14:14:35.000Z","type":"user","cwd":"/work/my-proj","message":{"role":"user","parts":[{"text":"请分析一下语义层模块"}]}}"#,
            #"{"uuid":"u2","sessionId":"\#(sessionId)","timestamp":"2026-07-21T14:15:28.000Z","type":"assistant","cwd":"/work/my-proj","model":"qwen3.7-max","message":{"role":"assistant","parts":[{"text":"内心思考","thought":true},{"functionCall":{"name":"read_file","args":{}}},{"text":"好的,我来分析。"}]}}"#,
            #"{"uuid":"u3","sessionId":"\#(sessionId)","timestamp":"2026-07-21T14:15:28.100Z","type":"system","cwd":"/work/my-proj","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-07-21T14:15:27.979Z","response_id":"chatcmpl-abc","model":"qwen3.7-max","status_code":200,"input_token_count":27532,"output_token_count":310,"cached_content_token_count":100,"thoughts_token_count":36,"total_token_count":27842}}}"#,
            // 流式重复的 telemetry 行（同 response_id）→ 同批次去重
            #"{"uuid":"u4","sessionId":"\#(sessionId)","timestamp":"2026-07-21T14:15:28.200Z","type":"system","cwd":"/work/my-proj","subtype":"ui_telemetry","systemPayload":{"uiEvent":{"event.name":"qwen-code.api_response","event.timestamp":"2026-07-21T14:15:27.979Z","response_id":"chatcmpl-abc","model":"qwen3.7-max","status_code":200,"input_token_count":27532,"output_token_count":310,"cached_content_token_count":100,"thoughts_token_count":36,"total_token_count":27842}}}"#,
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: chat, atomically: true, encoding: .utf8)
        return (home, chat)
    }

    t.test("索引：id/名字摘要/cwd(runtime.json)/startedAt") {
        let (home, chat) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let sessions = QwenSessionIndexer.index(
            projectsRoot: home.appendingPathComponent("projects"))
        try expectEqual(sessions.count, 1)
        let session = sessions[0]
        try expectEqual(session.source, .qwen)
        try expectEqual(session.id, "3dbdf6ce-5c3d-483c-b510-50e3e4ac4a6d")
        try expectEqual(session.name, "请分析一下语义层模块")
        try expectEqual(session.cwd, "/work/my-proj")
        try expect(session.startedAt != nil)
        try expectEqual(
            URL(fileURLWithPath: session.transcriptPath).resolvingSymlinksInPath().path,
            chat.resolvingSymlinksInPath().path)
    }

    t.test("对话渲染：thought 跳过、functionCall→toolNote、system 不进流") {
        let (home, chat) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let result = TranscriptReader.loadQwen(path: chat.path, maxMessages: 2000)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "请分析一下语义层模块")
        try expectEqual(result.messages[1].role, .toolNote)
        try expectEqual(result.messages[1].text, "🔧 read_file")
        try expectEqual(result.messages[2].role, .assistant)
        try expectEqual(result.messages[2].text, "好的,我来分析。")
        try expect(!result.messages[2].text.contains("内心思考"), "thought parts 不进正文")
    }

    t.test("用量：token 口径与 response_id 去重（同批次 + 重扫幂等）") {
        let (home, _) = try makeHome()
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-qwen-usage-\(UUID()).sqlite")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dbPath)
        }
        let store = try EurekaStore(path: dbPath)
        let scanner = QwenUsageScanner(
            projectsRoot: home.appendingPathComponent("projects"), store: store)

        try expectEqual(try scanner.scanOnce(), 1, "重复 response_id 只入一条")
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 1_800_000_000))
        try expectEqual(totals.count, 1)
        try expectEqual(totals[0].source, .qwen)
        try expectEqual(totals[0].model, "qwen3.7-max")
        try expectEqual(totals[0].inputTokens, 27532 - 100)
        try expectEqual(totals[0].outputTokens, 310)
        try expectEqual(totals[0].cacheReadTokens, 100)

        try expectEqual(try scanner.scanOnce(), 0, "水位不动重扫幂等")

        let prompts = try store.sessionStats.promptCounts(
            for: ["3dbdf6ce-5c3d-483c-b510-50e3e4ac4a6d"])
        try expectEqual(prompts["3dbdf6ce-5c3d-483c-b510-50e3e4ac4a6d"], 1)
    }

    t.test("计划启发式物化：≥3 清单项命中取最后一条，<3 项不产文件") {
        let fm = FileManager.default
        let (home, chat) = try makeHome()
        let staging = fm.temporaryDirectory
            .appendingPathComponent("eureka-qwen-plans-\(UUID())", isDirectory: true)
        defer {
            try? fm.removeItem(at: home)
            try? fm.removeItem(at: staging)
        }
        // <3 项 → 不产文件
        try expectEqual(PlanMaterializer.materializeQwen(
            projectsRoot: home.appendingPathComponent("projects"), into: staging), 0)

        // 追加一条含 3 项清单的助手消息 → 产文件
        let plan = "计划如下:\\n- [x] 分析模块\\n- [~] 写方案\\n- [ ] 实施"
        let line = #"{"uuid":"u9","sessionId":"3dbdf6ce-5c3d-483c-b510-50e3e4ac4a6d","timestamp":"2026-07-21T14:20:00.000Z","type":"assistant","cwd":"/work/my-proj","message":{"role":"assistant","parts":[{"text":"\#(plan)"}]}}"#
        let content = try String(contentsOf: chat, encoding: .utf8)
        try (content + line + "\n").write(to: chat, atomically: true, encoding: .utf8)

        try expectEqual(PlanMaterializer.materializeQwen(
            projectsRoot: home.appendingPathComponent("projects"), into: staging), 1)
        let out = staging.appendingPathComponent("qwen/qwen-3dbdf6ce.md")
        try expect(fm.fileExists(atPath: out.path))
        let md = try String(contentsOf: out, encoding: .utf8)
        try expect(md.contains("- [x] 分析模块"))
        try expect(md.contains("启发式提取"))

        // 重复运行内容未变 → 0 改动
        try expectEqual(PlanMaterializer.materializeQwen(
            projectsRoot: home.appendingPathComponent("projects"), into: staging), 0)
    }

    t.test("空标题兜底：name 空白的会话 displayName 回退短 id") {
        let session = AgentSessionInfo(
            source: .qwen, id: "abcdef1234567890", cwd: nil, name: "  ",
            startedAt: nil, lastActiveAt: Date(), sizeBytes: 0, transcriptPath: "/tmp/x")
        try expectEqual(session.displayName, "会话 abcdef12")
        let named = AgentSessionInfo(
            source: .qwen, id: "abcdef1234567890", cwd: nil, name: "正常标题",
            startedAt: nil, lastActiveAt: Date(), sizeBytes: 0, transcriptPath: "/tmp/x")
        try expectEqual(named.displayName, "正常标题")
    }
}
