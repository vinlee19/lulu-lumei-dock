import EurekaIngest
import EurekaStore
import Foundation

func transcriptReaderTests(_ t: TestRunner) {
    t.suite("TranscriptReader")

    t.test("Claude：用户串内容/助手 text 块/tool_use 聚合为 turnTrail") {
        let path = try fixtureURL("claude-transcript-running.jsonl").path
        let result = TranscriptReader.loadClaude(path: path, maxMessages: 2000)
        try expect(!result.truncated)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "重构数据管道的增量加载逻辑")
        try expectEqual(result.messages[1].role, .assistant)
        try expectEqual(result.messages[2].role, .turnTrail)
        try expectEqual(result.messages[2].steps.count, 1)
        try expectEqual(result.messages[2].steps[0].kind, .command)
        try expectEqual(result.messages[2].steps[0].detail, "pytest")
        try expect(result.messages[0].timestamp != nil, "时间戳应可解析")
    }

    t.test("Claude：API 错误行标为 error") {
        let path = try fixtureURL("claude-transcript-api-error.jsonl").path
        let result = TranscriptReader.loadClaude(path: path, maxMessages: 2000)
        try expect(result.messages.contains { $0.role == .error }, "应含 error 消息")
    }

    t.test("Codex：event_msg user/agent 消息按序提取") {
        let path = try fixtureURL("codex-rollout-lifecycle.jsonl").path
        let result = TranscriptReader.loadCodex(path: path, maxMessages: 2000)
        try expectEqual(result.messages.count, 2)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "跑一下集成测试并修复失败用例")
        try expectEqual(result.messages[1].role, .assistant)
        try expectEqual(result.messages[1].text, "集成测试全部通过，修复了 2 个失败用例。")
    }

    t.test("Codex：item_completed 的 UserMessage/AgentMessage 才是当前正文") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-cxtr-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let path = base.appendingPathComponent("rollout.jsonl")
        // 当前 Codex 不再写 user_message/agent_message。扩展把标签页说明包在请求外，
        // 导入会话还会把工具协议塞进没有 phase 的 AgentMessage。
        let lines = [
            #"{"timestamp":"2026-10-13T15:34:55.097Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"UserMessage","content":[{"type":"text","text":"\n# Chrome tabs:\n- Current URL: https://example.test\n\n## My request:\n分析怎么回复\n"},{"type":"local_image","path":"/tmp/shot.png"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:35:01.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"AgentMessage","phase":"commentary","content":[{"type":"Text","text":"我先读订单留言。"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:35:05.000Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"rg order","call_id":"c1"}}"#,
            #"{"timestamp":"2026-10-13T15:36:54.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"AgentMessage","phase":"final_answer","content":[{"type":"Text","text":"支付方式为 Google Pay。"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:37:10.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"UserMessage","content":[{"type":"text","text":"还有具体的过程"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:37:20.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"AgentMessage","content":[{"type":"Text","text":"工程骨架已创建完成。"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:37:21.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"AgentMessage","content":[{"type":"Text","text":"[external_agent_tool_call: Read] file: /tmp/a.swift"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:37:22.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"AgentMessage","content":[{"type":"Text","text":"[external_agent_tool_result] ok"}]}}}"#,
            #"{"timestamp":"2026-10-13T15:37:23.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"AgentMessage","content":[{"type":"Text","text":"<EXTERNAL SESSION IMPORTED>"}]}}}"#,
            // 普通消息里出现同样的字样，不能被信封剥离误伤
            #"{"timestamp":"2026-10-13T15:37:30.000Z","type":"event_msg","payload":{"type":"item_completed","turn_id":"t3","item":{"type":"UserMessage","content":[{"type":"text","text":"请保留这行 ## My request: 不要删"}]}}}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)

        let result = TranscriptReader.loadCodex(path: path.path, maxMessages: 2000)
        try expect(!result.truncated)
        let roles = result.messages.map(\.role)
        try expectEqual(roles, [.user, .assistant, .turnTrail, .assistant, .user, .assistant, .user])
        try expectEqual(result.messages[0].text, "分析怎么回复\n\n（附图：shot.png）")
        try expect(!result.messages[0].text.contains("Chrome tabs"))
        try expectEqual(result.messages[1].text, "我先读订单留言。")
        try expectEqual(result.messages[2].steps.count, 1)
        try expectEqual(result.messages[3].text, "支付方式为 Google Pay。")
        try expectEqual(result.messages[4].text, "还有具体的过程")
        try expectEqual(result.messages[5].text, "工程骨架已创建完成。")
        try expectEqual(result.messages[6].text, "请保留这行 ## My request: 不要删")
        try expect(result.messages.allSatisfy {
            !$0.text.contains("external_agent_tool") && !$0.text.contains("EXTERNAL SESSION")
        })
    }

    t.test("maxMessages 截断标记") {
        let path = try fixtureURL("codex-rollout-lifecycle.jsonl").path
        let result = TranscriptReader.loadCodex(path: path, maxMessages: 1)
        try expectEqual(result.messages.count, 1)
        try expect(result.truncated)
    }

    t.test("导出 Markdown：角色标题 + 时间 + 工具行") {
        let session = AgentSessionInfo(
            source: .claude, id: "sess-1", cwd: "/w/proj", name: "重构管道",
            startedAt: nil, lastActiveAt: Date(timeIntervalSince1970: 1000),
            sizeBytes: 0, transcriptPath: "/tmp/x.jsonl")
        let messages = [
            TranscriptMessage(id: 0, role: .user, text: "帮我重构",
                              timestamp: Date(timeIntervalSince1970: 1_780_000_000)),
            TranscriptMessage(id: 1, role: .toolNote, text: "🔧 Edit"),
            TranscriptMessage(id: 2, role: .turnTrail, text: "", steps: [
                ToolStep(kind: .read, name: "Read", detail: "/w/a.swift"),
                ToolStep(kind: .command, name: "Bash", detail: "make test", isError: true),
            ]),
            TranscriptMessage(id: 3, role: .assistant, text: "已完成"),
        ]
        let md = TranscriptMarkdown.render(session: session, messages: messages)
        try expect(md.contains("# 重构管道"))
        try expect(md.contains("- 项目：/w/proj"))
        try expect(md.contains("## 用户"))
        try expect(md.contains("帮我重构"))
        try expect(md.contains("- 🔧 Edit"))
        try expect(md.contains("- 🛠 本轮轨迹（2 步）"))
        try expect(md.contains("  - [读取] Read：/w/a.swift"))
        try expect(md.contains("  - [命令] Bash（失败）：make test"))
        try expect(md.contains("## 助手"))
        try expect(md.contains("已完成"))
        // 文件名安全化
        try expectEqual(TranscriptMarkdown.safeFileName("a/b:c*d"), "a-b-c-d")
    }

    t.test("opencode：message role + part 正文拼接 + tool 小注") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-octr-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("opencode.db")
        do {
            let db = try SQLiteDB(path: dbPath.path)
            try db.execute("""
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT,
                time_created INTEGER, time_updated INTEGER, data TEXT);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
                time_created INTEGER, time_updated INTEGER, data TEXT);
            """)
            // 用户消息（两个 text part 拼接）
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                       [.text("m1"), .text("s1"), .int(1000), .int(1000),
                        .text(#"{"role":"user"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                       [.text("p1"), .text("m1"), .text("s1"), .int(1000), .int(1000),
                        .text(#"{"type":"text","text":"你好"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                       [.text("p2"), .text("m1"), .text("s1"), .int(1001), .int(1001),
                        .text(#"{"type":"text","text":"帮我看个问题"}"#)])
            // 助手消息（reasoning 跳过 + tool 小注 + text）
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                       [.text("m2"), .text("s1"), .int(2000), .int(2000),
                        .text(#"{"role":"assistant"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                       [.text("q1"), .text("m2"), .text("s1"), .int(2000), .int(2000),
                        .text(#"{"type":"reasoning","text":"thinking..."}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                       [.text("q2"), .text("m2"), .text("s1"), .int(2001), .int(2001),
                        .text(#"{"type":"tool","tool":"bash"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                       [.text("q3"), .text("m2"), .text("s1"), .int(2002), .int(2002),
                        .text(#"{"type":"text","text":"看好了"}"#)])
            // 其他会话的消息（应被过滤）
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                       [.text("m9"), .text("s2"), .int(3000), .int(3000),
                        .text(#"{"role":"user"}"#)])
        }
        let result = TranscriptReader.loadOpencode(
            dbPath: dbPath.path, sessionId: "s1", maxMessages: 2000)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "你好\n帮我看个问题")
        try expectEqual(result.messages[1].role, .toolNote)
        try expectEqual(result.messages[1].text, "🔧 bash")
        try expectEqual(result.messages[2].role, .assistant)
        try expectEqual(result.messages[2].text, "看好了")
    }

    t.test("grok：chat_history 无时间戳 → 按 events.jsonl 轮次补；无 events 则不带时间") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-grtr-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let dir = base.appendingPathComponent("enc/uuid-1", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let chatURL = dir.appendingPathComponent("chat_history.jsonl")
        let eventsURL = dir.appendingPathComponent("events.jsonl")

        try ([
            #"{"type":"system","content":"sys"}"#,
            #"{"type":"user","content":[{"type":"text","text":"第一问"}]}"#,
            #"{"type":"assistant","content":"第一答"}"#,
            #"{"type":"user","content":[{"type":"text","text":"第二问"}]}"#,
            #"{"type":"assistant","content":"第二答"}"#,
        ].joined(separator: "\n") + "\n").write(to: chatURL, atomically: true, encoding: .utf8)
        try ([
            #"{"ts":"2026-07-09T09:50:00.000Z","type":"turn_started","session_id":"uuid-1"}"#,
            #"{"ts":"2026-07-09T10:00:00.000Z","type":"turn_started","session_id":"uuid-1"}"#,
        ].joined(separator: "\n") + "\n").write(to: eventsURL, atomically: true, encoding: .utf8)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let t1 = iso.date(from: "2026-07-09T09:50:00.000Z")
        let t2 = iso.date(from: "2026-07-09T10:00:00.000Z")

        let result = TranscriptReader.loadGrok(path: chatURL.path, maxMessages: 2000)
        try expectEqual(result.messages.count, 4)  // system 跳过
        try expectEqual(result.messages[0].text, "第一问")
        try expectEqual(result.messages[0].timestamp, t1)
        try expectEqual(result.messages[1].timestamp, t1)  // 第一答同轮
        try expectEqual(result.messages[2].text, "第二问")
        try expectEqual(result.messages[2].timestamp, t2)
        try expectEqual(result.messages[3].timestamp, t2)

        // 无 events.jsonl → 时间戳为 nil（不崩）
        try fm.removeItem(at: eventsURL)
        let noEvents = TranscriptReader.loadGrok(path: chatURL.path, maxMessages: 2000)
        try expect(noEvents.messages.allSatisfy { $0.timestamp == nil }, "无 events 应无时间")
    }
}
