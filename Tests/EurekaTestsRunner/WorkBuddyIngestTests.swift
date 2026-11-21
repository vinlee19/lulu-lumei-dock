import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

// WorkBuddy data-layer tests. Line shapes follow ~/.workbuddy transcripts written by WorkBuddy
// 5.11.3 (CodeBuddy Code 2.176 engine); ids, paths and text are made up.

/// Builders for WorkBuddy transcript lines, audit-log entries and database rows
enum WorkBuddyFixture {
    static let sessionId = "5d64d398-a4f2-4d34-8206-ade092d163f3"
    static let cwd = "/Users/demo/WorkBuddy/2026-11-02-16-13-17"

    static func nowMs(_ offset: Int64 = 0) -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000) + offset
    }

    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func base(_ type: String, ts: Int64, sid: String = sessionId) -> [String: Any] {
        ["type": type, "id": UUID().uuidString, "timestamp": ts, "sessionId": sid, "cwd": cwd]
    }

    static func usage(input: Int, cached: Int, output: Int) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "totalTokens": input + output,
         "requests": 1, "inputTokensDetails": [["cached_tokens": cached]]]
    }

    /// A real prompt: context blocks around one <user_query>
    static func prompt(
        _ query: String, ts: Int64, automation: Bool = false, sid: String = sessionId
    ) -> String {
        let body = automation
            ? "<automation_system_reminder>run daily<user_query>\(query)</user_query></automation_system_reminder>"
            : "<user_query>\(query)</user_query>"
        var line = base("message", ts: ts, sid: sid)
        line["role"] = "user"
        line["content"] = [["type": "input_text",
                            "text": "<system-reminder data-role=\"user-context\">ctx</system-reminder>" + body]]
        line["providerData"] = ["agent": "cli", "startsNewUserRequest": true,
                                "conversationRequestId": "req-\(ts)"]
        return json(line)
    }

    /// A message typed while the turn runs ("steer")
    static func steer(_ query: String, ts: Int64) -> String {
        var line = base("message", ts: ts)
        line["role"] = "user"
        line["content"] = [["type": "input_text", "text": "<user_query>\(query)</user_query>"]]
        line["providerData"] = ["startsNewUserRequest": false,
                                "clientMeta": ["codebuddy.ai": ["queueOrigin": "steer"]]]
        return json(line)
    }

    /// A compaction summary: a user line quoting earlier queries, with no turn flag
    static func compactionSummary(ts: Int64) -> String {
        var line = base("message", ts: ts)
        line["role"] = "user"
        line["content"] = [["type": "input_text",
                            "text": "<cb_summary><previous_user_message><user_query>old</user_query></previous_user_message></cb_summary>"]]
        line["providerData"] = ["isSummary": true]
        return json(line)
    }

    static func assistant(
        _ text: String, ts: Int64, usage: [String: Any]? = nil, messageId: String? = nil
    ) -> String {
        var line = base("message", ts: ts)
        line["role"] = "assistant"
        line["status"] = "completed"
        line["content"] = [["type": "output_text", "text": text]]
        var providerData: [String: Any] = ["model": "deepseek-v4.1-flash"]
        if let usage { providerData["usage"] = usage }
        if let messageId { providerData["messageId"] = messageId }
        line["providerData"] = providerData
        return json(line)
    }

    static func errorEnd(message: String, code: Int?, ts: Int64) -> String {
        var line = base("message", ts: ts)
        line["role"] = "assistant"
        line["status"] = "incomplete"
        line["content"] = []
        var error: [String: Any] = ["message": message, "isRetryable": false]
        error["code"] = code ?? NSNull()
        line["providerData"] = ["error": error]
        return json(line)
    }

    static func call(
        _ name: String, args: [String: Any] = [:], ts: Int64, callId: String,
        usage: [String: Any]? = nil, messageId: String? = nil
    ) -> String {
        var line = base("function_call", ts: ts)
        line["name"] = name
        line["callId"] = callId
        line["arguments"] = json(args)
        var providerData: [String: Any] = ["model": "deepseek-v4.1-flash"]
        if let usage { providerData["usage"] = usage }
        if let messageId { providerData["messageId"] = messageId }
        line["providerData"] = providerData
        return json(line)
    }

    static func result(_ name: String, callId: String, ts: Int64) -> String {
        var line = base("function_call_result", ts: ts)
        line["name"] = name
        line["callId"] = callId
        line["status"] = "completed"
        line["output"] = ["type": "text", "text": "ok"]
        return json(line)
    }

    static func sessionMeta(title: String, ts: Int64) -> String {
        var line = base("session-meta", ts: ts)
        line["meta"] = ["codebuddy.ai/hostKind": "unopted",
                        "codebuddy.ai/sessionTitle": [["type": "ai-title", "aiTitle": title]]]
        return json(line)
    }

    /// A temp WorkBuddy home: <home>/projects/<slug>/<sessionId>.jsonl
    static func makeHome(sessionId: String = sessionId) throws -> (home: URL, file: URL) {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-workbuddy-\(UUID().uuidString)", isDirectory: true)
        let project = home.appendingPathComponent(
            "projects/Users-demo-WorkBuddy-2026-11-02-16-13-17", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return (home, project.appendingPathComponent("\(sessionId).jsonl"))
    }

    static func append(_ lines: [String], to url: URL) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    /// The subset of `workbuddy.db`'s `sessions` table the catalog reads
    static func makeDatabase(
        at url: URL,
        rows: [(id: String, title: String?, customTitle: String?, automation: Bool, window: Int?)]
    ) throws {
        let db = try SQLiteDB(path: url.path)
        try db.execute("""
            CREATE TABLE sessions (id TEXT PRIMARY KEY, cwd TEXT, title TEXT, custom_title TEXT,
                is_background_automation INTEGER, context_window INTEGER)
            """)
        for row in rows {
            try db.run(
                "INSERT INTO sessions (id, title, custom_title, is_background_automation, context_window) VALUES (?, ?, ?, ?, ?)",
                [.text(row.id), .string(row.title), .string(row.customTitle),
                 .int(row.automation ? 1 : 0), row.window.map { .int(Int64($0)) } ?? .null])
        }
    }
}

private func kinds(_ events: [(TaskEvent, Bool)]) -> [TaskEvent.Kind] { events.map(\.0.kind) }

private func finishes(_ events: [(TaskEvent, Bool)]) -> [TaskOutcome] {
    events.compactMap {
        if case .taskFinished(let outcome, _, _) = $0.0.kind { return outcome } else { return nil }
    }
}

func workBuddyDialectTests(_ t: TestRunner) {
    t.suite("CodeBuddyDialect (WorkBuddy)")
    typealias F = WorkBuddyFixture
    func parse(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] ?? [:]
    }

    t.test("只有 startsNewUserRequest 的用户行算一轮开始；插话与压缩摘要不算") {
        try expect(CodeBuddyDialect.workbuddy.startsTurn(parse(F.prompt("看看", ts: 1))))
        try expect(!CodeBuddyDialect.workbuddy.startsTurn(parse(F.steer("顺便", ts: 1))))
        try expect(!CodeBuddyDialect.workbuddy.startsTurn(parse(F.compactionSummary(ts: 1))))
    }

    t.test("提问正文只取 <user_query>；插话也算人话，压缩摘要不算") {
        try expectEqual(CodeBuddyDialect.workbuddy.userText(parse(F.prompt("整理日报", ts: 1))), "整理日报")
        try expectEqual(CodeBuddyDialect.workbuddy.userText(parse(F.steer("再加一条", ts: 1))), "再加一条")
        try expectEqual(CodeBuddyDialect.workbuddy.userText(parse(F.compactionSummary(ts: 1))), nil)
        try expectEqual(
            CodeBuddyDialect.userQuery(in: "<system-reminder data-role=\"x\">ctx</system-reminder>  hi "),
            "hi")
    }

    t.test("一轮结束 = 带 usage 的助手消息或出错；中途的 completed 助手消息不算") {
        let usage = F.usage(input: 100, cached: 60, output: 5)
        try expect(CodeBuddyDialect.workbuddy.turnEnd(parse(F.assistant("思考中", ts: 1))) == nil)
        try expect(CodeBuddyDialect.workbuddy.turnEnd(
            parse(F.assistant("完成", ts: 1, usage: usage)))?.outcome == .success)
        let quota = CodeBuddyDialect.workbuddy.turnEnd(
            parse(F.errorEnd(message: "429 quota exceeded", code: 14018, ts: 1)))
        try expect(quota?.outcome == .error)
        try expectEqual(quota?.detail, "14018 429 quota exceeded")
        try expect(CodeBuddyDialect.workbuddy.turnEnd(
            parse(F.errorEnd(message: "Interrupted by user", code: nil, ts: 1)))?.outcome
            == .interrupted)
        // CodeBuddy keeps its 2026-07 rule
        try expect(CodeBuddyDialect.codebuddyCode.turnEnd(
            parse(F.assistant("思考中", ts: 1)))?.outcome == .success)
    }

    t.test("用量：末条助手消息上的 usage 也算（CodeBuddy 仍只认 function_call）") {
        let line = parse(F.assistant("完成", ts: 1,
                                     usage: F.usage(input: 100, cached: 60, output: 5),
                                     messageId: "m1"))
        let step = CodeBuddyDialect.workbuddy.usage(line)
        try expectEqual(step?.input, 40)
        try expectEqual(step?.cacheRead, 60)
        try expectEqual(step?.output, 5)
        try expectEqual(step?.messageId, "m1")
        try expect(CodeBuddyDialect.codebuddyCode.usage(line) == nil)
        // WorkBuddy's snake_case mirror includes cache reads too
        let mirror = parse(#"{"type":"message","role":"assistant","message":{"usage":{"input_tokens":100,"output_tokens":5,"cache_read_input_tokens":60}}}"#)
        try expectEqual(CodeBuddyDialect.workbuddy.usage(mirror)?.input, 40)
        try expectEqual(CodeBuddyDialect.codebuddyCode.usage(mirror)?.input, nil)
    }

    t.test("TaskCreate 是待办不是子代理；DeferExecuteTool 拆出真实工具名") {
        try expect(!CodeBuddyDialect.workbuddy.subagentTools.contains("TaskCreate"))
        try expect(CodeBuddyDialect.codebuddyCode.subagentTools.contains("TaskCreate"))
        try expectEqual(CodeBuddyDialect.workbuddy.effectiveToolName(
            name: "DeferExecuteTool", args: ["toolName": "ImageGen"]), "ImageGen")
        try expectEqual(CodeBuddyDialect.codebuddyCode.effectiveToolName(
            name: "DeferExecuteTool", args: ["toolName": "ImageGen"]), "DeferExecuteTool")
    }
}

func workBuddyLiveChannelTests(_ t: TestRunner) {
    t.suite("WorkBuddyLiveChannel")
    typealias F = WorkBuddyFixture

    func channel(
        home: URL, database: URL? = nil, onEvent: @escaping (TaskEvent, Bool) -> Void
    ) -> WorkBuddyLiveChannel {
        WorkBuddyLiveChannel(
            projectsRoot: home.appendingPathComponent("projects"),
            auditLogRoot: home.appendingPathComponent("audit-log"),
            catalog: WorkBuddySessionCatalog(
                databaseURL: database ?? home.appendingPathComponent("workbuddy.db")),
            handler: onEvent)
    }

    t.test("一轮里多条 completed 助手消息只结束一次；提问工具等待输入，回答后恢复") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([F.sessionMeta(title: "旧会话", ts: F.nowMs(-60_000))], to: session.file)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home) { events.append(($0, $1)) }
        live.scanOnce()
        events.removeAll()

        try F.append([
            F.prompt("整理本周日报", ts: F.nowMs(-5000)),
            F.assistant("先看看文件", ts: F.nowMs(-4900)),
            F.call("Read", args: ["file_path": "/tmp/a.md"], ts: F.nowMs(-4800), callId: "c1",
                   usage: F.usage(input: 1000, cached: 800, output: 10), messageId: "m1"),
            F.result("Read", callId: "c1", ts: F.nowMs(-4700)),
            F.assistant("再问一下", ts: F.nowMs(-4600)),
            F.call("AskUserQuestion",
                   args: ["questions": [["question": "发给谁？", "options": []]]],
                   ts: F.nowMs(-4500), callId: "c2",
                   usage: F.usage(input: 1200, cached: 900, output: 12), messageId: "m2"),
        ], to: session.file)
        live.scanOnce()
        try expect(finishes(events).isEmpty, "中途的 completed 消息不该结束一轮: \(kinds(events))")
        try expect(kinds(events).contains(.waiting(reason: .idle, message: "发给谁？")),
                   "AskUserQuestion 应进入等待输入: \(kinds(events))")

        events.removeAll()
        try F.append([
            F.result("AskUserQuestion", callId: "c2", ts: F.nowMs(-3000)),
            F.assistant("已整理完", ts: F.nowMs(-2000),
                        usage: F.usage(input: 1300, cached: 1000, output: 30), messageId: "m3"),
        ], to: session.file)
        live.scanOnce()
        try expect(kinds(events).first == .activity(tool: nil), "回答后应恢复运行: \(kinds(events))")
        try expectEqual(finishes(events), [.success])
        try expect(events.allSatisfy { $0.0.source == .workbuddy })
    }

    t.test("出错或被用户中断的一轮按对应结果结束") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([F.sessionMeta(title: "x", ts: F.nowMs(-60_000))], to: session.file)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home) { events.append(($0, $1)) }
        live.scanOnce()
        events.removeAll()
        try F.append([
            F.prompt("a", ts: F.nowMs(-3000)),
            F.errorEnd(message: "429 credits exhausted", code: 14018, ts: F.nowMs(-2900)),
            F.prompt("b", ts: F.nowMs(-2000)),
            F.errorEnd(message: "Interrupted by user", code: nil, ts: F.nowMs(-1900)),
        ], to: session.file)
        live.scanOnce()
        try expectEqual(finishes(events), [.error, .interrupted])
    }

    t.test("定时任务：首条提问带 automation 标记时整段不发任何事件") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([F.sessionMeta(title: "x", ts: F.nowMs(-60_000))], to: session.file)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home) { events.append(($0, $1)) }
        live.scanOnce()
        try F.append([
            F.prompt("每日简报", ts: F.nowMs(-3000), automation: true),
            F.call("Bash", args: ["command": "ls"], ts: F.nowMs(-2900), callId: "c1",
                   usage: F.usage(input: 10, cached: 0, output: 1), messageId: "m1"),
            F.assistant("完成", ts: F.nowMs(-2000),
                        usage: F.usage(input: 20, cached: 0, output: 2), messageId: "m2"),
        ], to: session.file)
        live.scanOnce()
        try expect(events.isEmpty, "定时任务不该有任何事件: \(kinds(events))")
    }

    t.test("数据库标记为定时任务的会话不发事件；交互会话用数据库标题和上下文窗口") {
        let automationId = "0b7d1c9e-3f5a-4c2e-9d8b-1a2b3c4d5e6f"
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let database = session.home.appendingPathComponent("workbuddy.db")
        try F.makeDatabase(at: database, rows: [
            (F.sessionId, "数据库标题", nil, false, 100_000),
            (automationId, "定时", nil, true, nil),
        ])
        let automationFile = session.file.deletingLastPathComponent()
            .appendingPathComponent("\(automationId).jsonl")
        // The DB flag decides even without the transcript marker
        try F.append([F.prompt("普通提问", ts: F.nowMs(-3000), sid: automationId)], to: automationFile)
        try F.append([
            F.prompt("整理", ts: F.nowMs(-3000)),
            F.call("Read", ts: F.nowMs(-2900), callId: "c1",
                   usage: F.usage(input: 50_000, cached: 40_000, output: 10), messageId: "m1"),
        ], to: session.file)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home, database: database) { events.append(($0, $1)) }
        live.scanOnce()
        try expect(events.allSatisfy { $0.0.sessionId == F.sessionId },
                   "定时任务会话不该出现: \(events.map(\.0.sessionId))")
        try expect(kinds(events).contains(.titleUpdate(title: "数据库标题")), "\(kinds(events))")
        try expect(kinds(events).contains(.contextUpdate(percent: 50)),
                   "ctx% 应按数据库窗口 100k 计算: \(kinds(events))")
    }

    t.test("审计日志：待授权 → 等待权限，同一工具调用的后续事件 → 恢复；无关条目不发事件") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let auditDir = session.home.appendingPathComponent("audit-log", isDirectory: true)
        try FileManager.default.createDirectory(at: auditDir, withIntermediateDirectories: true)
        let log = auditDir.appendingPathComponent("2026-11-21.jsonl")
        func entry(_ type: String, call: String, ts: Int64, sid: String = F.sessionId) -> String {
            F.json(["eventType": type, "sessionId": sid, "toolCallId": call, "requestId": "r",
                    "timestamp": ts, "messageParams": ["contentPreview": "secret=xyz"]])
        }
        // At launch: one prompt already answered, one still open
        try F.append([
            entry("file-safety.needs-approval", call: "old", ts: F.nowMs(-9000)),
            entry("file-safety.approved", call: "old", ts: F.nowMs(-8000)),
            entry("file-safety.needs-approval", call: "open", ts: F.nowMs(-7000)),
        ], to: log)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home) { events.append(($0, $1)) }
        live.scanOnce()
        try expectEqual(kinds(events), [.waiting(reason: .permission, message: nil)])
        events.removeAll()

        try F.append([
            entry("file-safety.allow-listed", call: "other", ts: F.nowMs(-500)),
            entry("file-safety.approved", call: "open", ts: F.nowMs(-400)),
        ], to: log)
        live.scanOnce()
        try expectEqual(kinds(events), [.activity(tool: nil)])
        try expect(events.allSatisfy { $0.0.source == .workbuddy && $0.0.sessionId == F.sessionId })
    }

    t.test("内部宿主 / 预热会话不发事件") {
        let session = try F.makeHome(sessionId: "wb-warm-1234")
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([F.sessionMeta(title: "x", ts: F.nowMs(-60_000))], to: session.file)
        var events: [(TaskEvent, Bool)] = []
        let live = channel(home: session.home) { events.append(($0, $1)) }
        live.scanOnce()
        try F.append([F.prompt("hi", ts: F.nowMs(-1000), sid: "wb-warm-1234")], to: session.file)
        live.scanOnce()
        try expect(events.isEmpty, "\(kinds(events))")
    }
}

func workBuddySessionIndexTests(_ t: TestRunner) {
    t.suite("WorkBuddy session index / catalog / todos / audit")
    typealias F = WorkBuddyFixture

    t.test("会话列表：排除定时任务，数据库标题优先，session-meta 标题次之") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let projectDir = session.file.deletingLastPathComponent()
        try F.append([F.prompt("交互提问", ts: F.nowMs(-5000)),
                      F.sessionMeta(title: "会话元数据标题", ts: F.nowMs(-4000))], to: session.file)
        let automation = projectDir.appendingPathComponent("1f0e2d3c-4b5a-4968-8776-655443322110.jsonl")
        try F.append([F.prompt("日报", ts: F.nowMs(-5000), automation: true,
                               sid: "1f0e2d3c-4b5a-4968-8776-655443322110")], to: automation)
        let projects = session.home.appendingPathComponent("projects")

        let plain = CodeBuddySessionIndexer.index(projectsRoot: projects, dialect: .workbuddy)
        try expectEqual(plain.map(\.id), [F.sessionId])
        try expectEqual(plain.first?.name, "会话元数据标题")
        try expectEqual(plain.first?.source, .workbuddy)

        let titled = CodeBuddySessionIndexer.index(
            projectsRoot: projects, dialect: .workbuddy,
            lookup: { $0 == F.sessionId ? CodeBuddySessionHints(isAutomation: false, title: "库里标题") : nil })
        try expectEqual(titled.first?.name, "库里标题")
    }

    t.test("数据库目录：读失败保留上一次结果，不当成没有会话") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-wb-db-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let database = dir.appendingPathComponent("workbuddy.db")
        try F.makeDatabase(at: database, rows: [(F.sessionId, "标题", "自定义标题", true, 128_000)])
        let catalog = WorkBuddySessionCatalog(
            databaseURL: database, refreshInterval: 0, missRetryInterval: 0)
        let hints = catalog.hints(for: F.sessionId)
        try expectEqual(hints?.isAutomation, true)
        try expectEqual(hints?.title, "自定义标题")
        try expectEqual(hints?.contextWindow, 128_000)
        try FileManager.default.removeItem(at: database)
        try expectEqual(catalog.hints(for: F.sessionId)?.isAutomation, true)
    }

    t.test("待办清单物化成计划；定时任务的待办跳过") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-wb-tasks-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let tasks = dir.appendingPathComponent("tasks/\(F.sessionId)", isDirectory: true)
        let skipped = dir.appendingPathComponent("tasks/auto-session", isDirectory: true)
        try FileManager.default.createDirectory(at: tasks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skipped, withIntermediateDirectories: true)
        for (index, (subject, status)) in [("写初稿", "completed"), ("配图", "in_progress"),
                                           ("发布", "pending")].enumerated() {
            try Data(F.json(["id": "\(index + 1)", "subject": subject, "status": status])
                .utf8).write(to: tasks.appendingPathComponent("\(index + 1).json"))
        }
        try Data(F.json(["id": "1", "subject": "定时", "status": "pending"]).utf8)
            .write(to: skipped.appendingPathComponent("1.json"))
        let staging = dir.appendingPathComponent("staging", isDirectory: true)
        let written = PlanMaterializer.materializeWorkBuddy(
            tasksRoot: dir.appendingPathComponent("tasks"), into: staging,
            lookup: { $0 == "auto-session" ? CodeBuddySessionHints(isAutomation: true) : nil })
        try expectEqual(written, 1)
        let content = try String(contentsOf: staging.appendingPathComponent(
            "workbuddy/\(F.sessionId).md"), encoding: .utf8)
        try expect(content.contains("- [x] 写初稿") && content.contains("- [~] 配图")
                   && content.contains("- [ ] 发布"), content)
    }

    t.test("审计：定时任务不入审计，DeferExecuteTool 记为真实工具") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let automation = session.file.deletingLastPathComponent()
            .appendingPathComponent("2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d.jsonl")
        try F.append([F.prompt("日报", ts: F.nowMs(-5000), automation: true,
                               sid: "2a3b4c5d-6e7f-4a8b-9c0d-1e2f3a4b5c6d"),
                      F.call("Bash", args: ["command": "ls"], ts: F.nowMs(-4000), callId: "a1")],
                     to: automation)
        try F.append([F.prompt("画图", ts: F.nowMs(-5000)),
                      F.call("DeferExecuteTool",
                             args: ["toolName": "Bash", "params": ["command": "echo hi"]],
                             ts: F.nowMs(-4000), callId: "c1")], to: session.file)
        let store = try EurekaStore(path: session.home.appendingPathComponent("eureka.sqlite"))
        let scanner = CodeBuddyAuditScanner(
            projectsRoot: session.home.appendingPathComponent("projects"), store: store,
            pipeline: AuditPipeline(store: store), dialect: .workbuddy)
        try expectEqual(try scanner.scanOnce(), 1)
        let rows = try store.audit.recent(limit: 10)
        try expectEqual(rows.first?.source, .workbuddy)
        try expectEqual(rows.first?.tool, "Bash")
        try expectEqual(rows.first?.detail, "echo hi")
        try expectEqual(rows.first?.sessionId, F.sessionId)
    }

    t.test("深链接只接受 UUID；会话页恢复命令用它打开 WorkBuddy") {
        try expectEqual(SessionAppLink.workBuddy(sessionId: F.sessionId).url?.absoluteString,
                        "workbuddy://chat/\(F.sessionId)")
        try expect(SessionAppLink.workBuddy(sessionId: "x'; rm -rf ~").url == nil)
        try expectEqual(SessionAppLinkResolver.resolve(source: .workbuddy, sessionId: F.sessionId),
                        .workBuddy(sessionId: F.sessionId))
        try expect(!AgentSource.workbuddy.supportsSessionDeletion)
        try expect(!AgentSource.workbuddy.usesSharedSessionDatabase)
    }
}
