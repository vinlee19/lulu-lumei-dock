import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func geminiIngestTests(_ t: TestRunner) {
    t.suite("Gemini · 会话/对话/用量采集")

    /// 造一个最小 ~/.gemini 布局：tmp/<slug>/chats/session-*.jsonl + projects.json
    func makeHome() throws -> (home: URL, chat: URL) {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("eureka-gemini-\(UUID())", isDirectory: true)
        let chats = home.appendingPathComponent("tmp/my-proj/chats", isDirectory: true)
        try fm.createDirectory(at: chats, withIntermediateDirectories: true)
        try #"{"projects": {"/work/my-proj": "my-proj"}}"#
            .write(to: home.appendingPathComponent("projects.json"),
                   atomically: true, encoding: .utf8)
        let chat = chats.appendingPathComponent("session-2026-07-21T11-22-ffb694fd.jsonl")
        let lines = [
            #"{"sessionId":"ffb694fd-a055","projectHash":"h","startTime":"2026-07-21T11:22:46.553Z","lastUpdated":"2026-07-21T11:22:46.553Z","kind":"main"}"#,
            #"{"$set":{"messages":[]}}"#,
            #"{"id":"m0","timestamp":"2026-07-21T11:22:46.553Z","type":"user","content":[{"text":"<session_context>\n环境注入,不是用户输入\n</session_context>"}]}"#,
            #"{"id":"m1","timestamp":"2026-07-21T11:23:00.000Z","type":"info","content":[{"text":"提示信息"}]}"#,
            #"{"id":"m2","timestamp":"2026-07-21T11:24:00.000Z","type":"user","content":[{"text":"帮我分析这个语义层项目"}]}"#,
            #"{"$set":{"lastUpdated":"2026-07-21T11:24:01.000Z"}}"#,
            #"{"id":"m3","timestamp":"2026-07-21T11:24:27.787Z","type":"gemini","content":"好的,我来分析。","thoughts":[],"tokens":{"input":17628,"output":36,"cached":8146,"thoughts":383,"tool":0,"total":18047},"model":"gemini-3.5-flash"}"#,
            // CLI 流式写入会把同一 gemini 消息行重复写一次（真实观测）→ 同批次去重
            #"{"id":"m3","timestamp":"2026-07-21T11:24:27.787Z","type":"gemini","content":"好的,我来分析。","thoughts":[],"tokens":{"input":17628,"output":36,"cached":8146,"thoughts":383,"tool":0,"total":18047},"model":"gemini-3.5-flash"}"#,
            #"{"id":"m4","timestamp":"2026-07-21T11:25:00.000Z","type":"error","content":[{"text":"quota exceeded"}]}"#,
        ]
        try lines.joined(separator: "\n").appending("\n")
            .write(to: chat, atomically: true, encoding: .utf8)
        return (home, chat)
    }

    t.test("索引：id/名字摘要/cwd 反查/开始时间；纯注入会话不进列表") {
        let (home, chat) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let sessions = GeminiSessionIndexer.index(
            tmpRoot: home.appendingPathComponent("tmp"),
            projectsFile: home.appendingPathComponent("projects.json"))
        try expectEqual(sessions.count, 1)
        let session = sessions[0]
        try expectEqual(session.source, .gemini)
        try expectEqual(session.id, "ffb694fd-a055")
        try expectEqual(session.name, "帮我分析这个语义层项目")
        try expectEqual(session.cwd, "/work/my-proj")
        try expect(session.startedAt != nil)
        // /var 与 /private/var 是同一位置的符号链接，解析后比较
        try expectEqual(
            URL(fileURLWithPath: session.transcriptPath).resolvingSymlinksInPath().path,
            chat.resolvingSymlinksInPath().path)

        // 只有 session_context、无真实用户输入 → 不进列表
        let emptyChat = chat.deletingLastPathComponent()
            .appendingPathComponent("session-2026-07-21T12-00-empty.jsonl")
        try [
            #"{"sessionId":"empty-1","startTime":"2026-07-21T12:00:00.000Z","kind":"main"}"#,
            #"{"id":"e0","timestamp":"2026-07-21T12:00:00.000Z","type":"user","content":[{"text":"<session_context>\nx\n</session_context>"}]}"#,
        ].joined(separator: "\n").write(to: emptyChat, atomically: true, encoding: .utf8)
        let again = GeminiSessionIndexer.index(
            tmpRoot: home.appendingPathComponent("tmp"),
            projectsFile: home.appendingPathComponent("projects.json"))
        try expectEqual(again.count, 1, "空会话不应进列表")
    }

    t.test("对话渲染：过滤注入与 info/$set，user/gemini/error 序列正确") {
        let (home, chat) = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }

        let result = TranscriptReader.loadGemini(path: chat.path, maxMessages: 2000)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "帮我分析这个语义层项目")
        try expectEqual(result.messages[1].role, .assistant)
        try expectEqual(result.messages[1].text, "好的,我来分析。")
        try expectEqual(result.messages[2].role, .error)
        try expect(result.messages[0].timestamp != nil)
    }

    t.test("用量：token 口径（input-cached / output+thoughts / cacheRead）与重扫幂等") {
        let (home, chat) = try makeHome()
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-gemini-usage-\(UUID()).sqlite")
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: dbPath)
        }
        let store = try EurekaStore(path: dbPath)
        let scanner = GeminiUsageScanner(
            tmpRoot: home.appendingPathComponent("tmp"),
            projectsFile: home.appendingPathComponent("projects.json"),
            store: store)

        try expectEqual(try scanner.scanOnce(), 1)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: now)
        try expectEqual(totals.count, 1)
        try expectEqual(totals[0].source, .gemini)
        try expectEqual(totals[0].model, "gemini-3.5-flash")
        try expectEqual(totals[0].inputTokens, 17628 - 8146)
        try expectEqual(totals[0].outputTokens, 36 + 383)
        try expectEqual(totals[0].cacheReadTokens, 8146)

        // 重扫（水位不动）幂等
        try expectEqual(try scanner.scanOnce(), 0)

        // 模拟会话恢复整写文件（同内容重写 → 水位失效回 0 重读）→ dedup 兜底不重复
        let content = try String(contentsOf: chat, encoding: .utf8)
        try (content + #"{"$set":{"lastUpdated":"2026-07-21T11:26:00.000Z"}}"# + "\n")
            .write(to: chat, atomically: true, encoding: .utf8)
        try expectEqual(try scanner.scanOnce(), 0, "atomic 重写换 inode 全量重读，dedup 应挡住重复")

        // 提问数入 session_stats
        let prompts = try store.sessionStats.promptCounts(for: ["ffb694fd-a055"])
        try expectEqual(prompts["ffb694fd-a055"], 1, "session_context 注入不计提问")
    }

    t.test("技能/记忆：~/.gemini/skills 与 GEMINI.md 归 gemini 源") {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("eureka-gemini-sm-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        let skillDir = home.appendingPathComponent("skills/my-skill", isDirectory: true)
        try fm.createDirectory(at: skillDir, withIntermediateDirectories: true)
        try "---\nname: my-skill\ndescription: 测试\n---\n正文"
            .write(to: skillDir.appendingPathComponent("SKILL.md"),
                   atomically: true, encoding: .utf8)
        try "# GEMINI.md\n全局记忆".write(
            to: home.appendingPathComponent("GEMINI.md"), atomically: true, encoding: .utf8)

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: home.appendingPathComponent("no-claude"),
            codexSkillsRoot: home.appendingPathComponent("no-codex"),
            geminiSkillsRoot: home.appendingPathComponent("skills"))
        try expectEqual(skills.filter { $0.source == .gemini }.count, 1)
        try expectEqual(skills.first { $0.source == .gemini }?.name, "my-skill")

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: home.appendingPathComponent("no-claude"),
            codexHome: home.appendingPathComponent("no-codex"),
            opencodeHome: home.appendingPathComponent("no-opencode"),
            claudeProjectsRoot: home.appendingPathComponent("no-projects"),
            geminiHome: home)
        let geminiMemories = memories.filter { $0.source == .gemini }
        try expectEqual(geminiMemories.count, 1)
        try expect(geminiMemories[0].path.hasSuffix("GEMINI.md"))
    }
}
