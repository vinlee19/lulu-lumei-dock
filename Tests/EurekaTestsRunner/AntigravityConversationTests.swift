import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// A fake Antigravity home: `<base>/cli` (agy) and `<base>/ide`, each with `conversations/` and
/// a WAL-mode `conversation_summaries.db`
private struct AgyHome {
    let base: URL
    var cli: URL { base.appendingPathComponent("cli", isDirectory: true) }
    var ide: URL { base.appendingPathComponent("ide", isDirectory: true) }
    var cliConversations: URL { cli.appendingPathComponent("conversations", isDirectory: true) }
    var ideConversations: URL { ide.appendingPathComponent("conversations", isDirectory: true) }

    init() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-agyconv-\(UUID().uuidString)", isDirectory: true)
        for dir in [cliConversations, ideConversations] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func summaryDB(_ app: URL) -> URL { app.appendingPathComponent("conversation_summaries.db") }

    /// Same column names as Antigravity's own tables (only the ones read are created)
    func makeSummaryDB(_ app: URL) throws -> SQLiteDB {
        let db = try SQLiteDB(path: summaryDB(app).path)
        try db.execute("PRAGMA journal_mode=WAL")
        try db.execute("""
        CREATE TABLE conversation_summaries (conversation_id text PRIMARY KEY,
            title text NOT NULL DEFAULT '', preview text NOT NULL DEFAULT '',
            step_count integer NOT NULL DEFAULT 0, last_modified_time datetime NOT NULL,
            workspace_uris text NOT NULL)
        """)
        try db.execute("""
        CREATE VIRTUAL TABLE conversations_fts USING fts5(conversation_id UNINDEXED,
            chunk_index UNINDEXED, user_step_byte_offsets UNINDEXED,
            agent_step_byte_offsets UNINDEXED, title, user_body, agent_body)
        """)
        return db
    }

    func touch(_ url: URL) throws {
        try Data([0x01, 0x02]).write(to: url)
    }

    func brainLogs(app: URL, id: String) throws -> URL {
        let logs = app.appendingPathComponent("brain/\(id)/.system_generated/logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }
}

private func insertSummary(
    _ db: SQLiteDB, id: String, title: String, preview: String, steps: Int, cwd: String
) throws {
    try db.run("""
    INSERT INTO conversation_summaries
        (conversation_id, title, preview, step_count, last_modified_time, workspace_uris)
    VALUES (?, ?, ?, ?, '2026-11-20 02:00:00.123456+00:00', ?)
    """, [.text(id), .text(title), .text(preview), .int(Int64(steps)),
          .text("[\"file://\(cwd)\"]")])
}

func antigravityConversationTests(_ t: TestRunner) {
    t.suite("Antigravity 会话正文与标题")

    let ideId = "aaaaaaaa-0000-4000-8000-000000000001"
    let cliId = "bbbbbbbb-0000-4000-8000-000000000002"
    let emptyId = "cccccccc-0000-4000-8000-000000000003"

    t.test("transcript_full.jsonl：提问拆包、回复、工具轨迹与失败标记、错误、时间戳") {
        let result = TranscriptReader.loadAntigravityTranscript(
            path: try fixtureURL("antigravity-transcript_full.jsonl").path, maxMessages: 2000)
        try expect(!result.truncated)
        try expectEqual(
            result.messages.map(\.role),
            [.user, .assistant, .turnTrail, .error, .assistant, .user, .assistant])
        try expectEqual(result.messages[0].text, "把 README 里的拼写错误修掉")
        try expectEqual(
            result.messages[0].timestamp, ISO8601DateFormatter().date(from: "2026-11-20T02:00:00Z"))
        let steps = result.messages[2].steps
        try expectEqual(steps.map(\.kind), [.read, .search, .command, .mcp])
        try expectEqual(steps.map(\.name), ["view_file", "grep_search", "run_command", "notion.search"])
        try expectEqual(steps.map(\.isError), [false, true, false, false])
        try expectEqual(steps[0].detail, "/repo/README.md")
        try expectEqual(steps[2].detail, "sed -i '' 's/teh/the/' README.md …")
        try expectEqual(steps.map(\.batch), [1, 1, 2, 2])
        try expect(result.messages[2].text.contains("本轮轨迹（4 步）"))
        try expectEqual(result.messages[3].text, "API error (attempt 1): stream reading error")
        try expectEqual(result.messages[5].text, "谢谢")
    }

    t.test("只贴了图片的提问留一条占位，不丢这一轮") {
        try expectEqual(
            TranscriptReader.antigravityPrompt(
                "<USER_REQUEST>\n\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nThe user has uploaded 2 image(s):\n- /x.png\n</ADDITIONAL_METADATA>"),
            "🖼 上传了 2 张图片")
        try expect(TranscriptReader.antigravityPrompt("<USER_REQUEST>\n \n</USER_REQUEST>") == nil)
    }

    t.test("transcript.jsonl 的参数多一层引号也能还原；超预算截断") {
        let home = try AgyHome()
        defer { try? FileManager.default.removeItem(at: home.base) }
        let logs = try home.brainLogs(app: home.cli, id: cliId)
        let lines = [
            #"{"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","created_at":"2026-11-20T02:00:00Z","content":"<USER_REQUEST>\nhi\n</USER_REQUEST>"}"#,
            #"{"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-11-20T02:00:01Z","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"\"/repo/a.md\"","toolSummary":"\"Read a\""}}]}"#,
            #"{"step_index":2,"source":"MODEL","type":"PLANNER_RESPONSE","created_at":"2026-11-20T02:00:02Z","content":"done"}"#,
        ]
        try (lines.joined(separator: "\n") + "\n")
            .write(to: logs.appendingPathComponent("transcript.jsonl"), atomically: true, encoding: .utf8)
        let file = home.cliConversations.appendingPathComponent("\(cliId).db")
        try home.touch(file)
        try expectEqual(
            AntigravityPaths.transcriptURL(conversationFile: file)?.lastPathComponent,
            "transcript.jsonl")

        let empty = AntigravityConversationCatalog(databases: { [] })
        let full = TranscriptReader.loadAntigravity(
            conversationFile: file.path, conversationId: cliId, maxMessages: 2000, catalog: empty)
        try expectEqual(full.messages.map(\.role), [.user, .turnTrail, .assistant])
        try expectEqual(full.messages[1].steps.first?.detail, "/repo/a.md")

        let clipped = TranscriptReader.loadAntigravity(
            conversationFile: file.path, conversationId: cliId, maxMessages: 1, catalog: empty)
        try expect(clipped.truncated)
        try expectEqual(clipped.messages.count, 1)
    }

    t.test("summary 库：两库标题互补、FTS 按 UTF-8 字节偏移切段、WAL 里的数据也能读且不动原库") {
        let home = try AgyHome()
        defer { try? FileManager.default.removeItem(at: home.base) }
        let cliDB = try home.makeSummaryDB(home.cli)
        let ideDB = try home.makeSummaryDB(home.ide)
        // The CLI copy has titles; the IDE copy has the IDE conversation's text
        try insertSummary(cliDB, id: ideId, title: "README 拼写", preview: "", steps: 4, cwd: "/repo")
        try insertSummary(ideDB, id: ideId, title: "", preview: "你好", steps: 4, cwd: "/repo")
        try insertSummary(cliDB, id: emptyId, title: "", preview: "", steps: 0, cwd: "/tmp/x")
        try ideDB.run("""
        INSERT INTO conversations_fts (conversation_id, chunk_index, user_step_byte_offsets,
            agent_step_byte_offsets, title, user_body, agent_body)
        VALUES (?, -1, '', '', '', '', ''),
               (?, 0, '[[0,0],[2,7]]', '[[1,0],[3,10]]', '', ?, ?)
        """, [.text(ideId), .text(ideId), .text("你好\n第二问\n"), .text("回答一\n回答二")])
        // Both connections stay open, so the rows are still only in the -wal files
        let walPath = home.summaryDB(home.ide).path + "-wal"
        try expect(FileManager.default.fileExists(atPath: walPath), "rows should sit in the wal")
        let before = SQLiteWALSnapshot.fingerprint(home.summaryDB(home.ide))

        let catalog = AntigravityConversationCatalog(
            databases: { [home.summaryDB(home.cli), home.summaryDB(home.ide)] })
        let summaries = catalog.summaries()
        try expectEqual(summaries.count, 2)
        try expectEqual(summaries[ideId]?.title, "README 拼写")
        try expectEqual(summaries[ideId]?.preview, "你好")
        try expectEqual(summaries[ideId]?.cwd, "/repo")
        try expectEqual(summaries[emptyId]?.stepCount, 0)
        try expect(summaries[ideId]?.lastModified != nil)

        let segments = catalog.segments(conversationId: ideId) ?? []
        try expectEqual(segments.map(\.text), ["你好", "回答一", "第二问", "回答二"])
        try expectEqual(segments.map(\.isUser), [true, false, true, false])
        try expectEqual(SQLiteWALSnapshot.fingerprint(home.summaryDB(home.ide)), before)
        _ = cliDB
    }

    t.test("索引 CLI .db + IDE .pb：标题来自 summary、cwd、FTS 兜底正文、都没有时给说明") {
        let home = try AgyHome()
        defer { try? FileManager.default.removeItem(at: home.base) }
        let cliDB = try home.makeSummaryDB(home.cli)
        try insertSummary(cliDB, id: ideId, title: "IDE 会话", preview: "", steps: 2, cwd: "/ide")
        try insertSummary(cliDB, id: cliId, title: "", preview: "第一行提问\n第二行", steps: 12, cwd: "/cli")
        try insertSummary(cliDB, id: emptyId, title: "", preview: "", steps: 0, cwd: "/cli")
        try cliDB.run("""
        INSERT INTO conversations_fts (conversation_id, chunk_index, user_step_byte_offsets,
            agent_step_byte_offsets, title, user_body, agent_body)
        VALUES (?, 0, '[[0,0]]', '[[1,0]]', '', 'question', 'answer')
        """, [.text(ideId)])
        try home.touch(home.ideConversations.appendingPathComponent("\(ideId).pb"))
        try home.touch(home.cliConversations.appendingPathComponent("\(cliId).db"))
        try home.touch(home.cliConversations.appendingPathComponent("\(emptyId).db"))
        try home.touch(home.cliConversations.appendingPathComponent("\(cliId).db-wal"))
        try FileManager.default.copyItem(
            at: fixtureURL("antigravity-transcript_full.jsonl"),
            to: try home.brainLogs(app: home.cli, id: cliId)
                .appendingPathComponent("transcript_full.jsonl"))
        let catalog = AntigravityConversationCatalog(databases: { [home.summaryDB(home.cli)] })

        let sessions = AntigravitySessionIndexer.index(
            conversationsRoot: home.cliConversations,
            ideConversationsRoot: home.ideConversations, catalog: catalog)
        let byId = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        try expectEqual(Set(byId.keys), [ideId, cliId, emptyId])
        try expectEqual(byId[ideId]?.name, "IDE 会话")
        try expectEqual(byId[ideId]?.cwd, "/ide")
        try expectEqual(byId[cliId]?.name, "第一行提问")
        try expectEqual(byId[cliId]?.cwd, "/cli")
        try expect(byId[emptyId]?.name == nil)

        // Without a catalog (project discovery) only the CLI root is read, as before
        let bare = AntigravitySessionIndexer.index(conversationsRoot: home.cliConversations)
        try expectEqual(Set(bare.map(\.id)), [cliId, emptyId])

        func load(_ id: String) -> TranscriptReader.Result {
            TranscriptReader.loadAntigravity(
                conversationFile: byId[id]!.transcriptPath, conversationId: id,
                maxMessages: 2000, catalog: catalog)
        }
        try expectEqual(load(cliId).messages.count, 7, "jsonl wins")
        try expectEqual(load(ideId).messages.map(\.text), ["question", "answer"])
        try expectEqual(load(ideId).messages.map(\.role), [.user, .assistant])
        try expectEqual(load(emptyId).messages.map(\.role), [.toolNote])
    }
}
