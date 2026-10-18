import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

// MARK: - fixture：opencode 2.x 形状的临时库（OpenChamber 自带的 opencode serve 写的就是这一代）

/// 列取真实库（opencode 2.0.27）`session_v2` / `session_message` 里本项目读到的那几列；
/// `withV1` 时再建 1.x 的 session/message/part/event 表（真实库两代表并存）
private func makeV2DB(at url: URL, withV1: Bool = true, _ build: (SQLiteDB) throws -> Void) throws {
    let db = try SQLiteDB(path: url.path)
    try db.execute("""
    CREATE TABLE session_v2 (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT NOT NULL,
        title TEXT, version TEXT NOT NULL, metadata TEXT,
        time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL);
    CREATE TABLE session_message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL,
        type TEXT NOT NULL, seq INTEGER NOT NULL, time_created INTEGER NOT NULL,
        time_updated INTEGER NOT NULL, data TEXT NOT NULL);
    """)
    if withV1 {
        try db.execute("""
        CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT,
            title TEXT, time_created INTEGER, time_updated INTEGER);
        CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER,
            time_updated INTEGER, data TEXT NOT NULL);
        CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
            time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL);
        CREATE TABLE event (id TEXT PRIMARY KEY, aggregate_id TEXT, seq INTEGER,
            type TEXT NOT NULL, data TEXT NOT NULL);
        """)
    }
    try build(db)
    try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")  // 落盘，读连接可见
}

private func v2TempDir(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

private func insertSession(
    _ db: SQLiteDB, _ id: String, parent: String? = nil, directory: String = "/Users/me/proj",
    title: String? = nil, version: String = "2.0.27", createdMs: Int, updatedMs: Int
) throws {
    try db.run("INSERT INTO session_v2 VALUES (?,?,?,?,?,?,?,?)", [
        .text(id), parent.map { .text($0) } ?? .null, .text(directory),
        title.map { .text($0) } ?? .null, .text(version),
        .text(#"{"openchamber":{"work":{"state":"open"}}}"#),
        .int(Int64(createdMs)), .int(Int64(updatedMs)),
    ])
}

private func insertMessage(
    _ db: SQLiteDB, _ id: String, session: String, type: String, seq: Int,
    createdMs: Int, updatedMs: Int? = nil, data: String
) throws {
    try db.run("INSERT INTO session_message VALUES (?,?,?,?,?,?,?)", [
        .text(id), .text(session), .text(type), .int(Int64(seq)),
        .int(Int64(createdMs)), .int(Int64(updatedMs ?? createdMs)), .text(data),
    ])
}

private func userData(_ text: String, ms: Int) -> String {
    #"{"time":{"created":\#(ms)},"text":"\#(text)"}"#
}

private func assistantData(
    ms: Int, completed: Bool = true, finish: String = "stop", tools: [String] = [],
    text: String = "好的", input: Int = 100, output: Int = 20
) -> String {
    let toolItems = tools.map {
        #"{"type":"tool","id":"call_\#($0)","name":"\#($0)","state":{"status":"completed"}}"#
    }
    let content = ([#"{"type":"reasoning","text":"想一想"}"#] + toolItems
        + [#"{"type":"text","text":"\#(text)"}"#]).joined(separator: ",")
    let time = completed
        ? #"{"created":\#(ms),"streamed":\#(ms + 100),"completed":\#(ms + 500)}"#
        : #"{"created":\#(ms)}"#
    return """
    {"time":\(time),"agent":"build","model":{"id":"glm-5.2","providerID":"zhipuai","variant":"high"},\
    "content":[\(content)],"finish":"\(finish)","cost":0.01,\
    "tokens":{"input":\(input),"output":\(output),"reasoning":5,"cache":{"read":30,"write":10}}}
    """
}

private func idleData(ms: Int, outcome: String = "succeeded") -> String {
    if outcome == "failed" {
        return #"{"time":{"created":\#(ms)},"outcome":"failed","error":{"type":"provider.auth","message":"API key 无效","status":401}}"#
    }
    return #"{"time":{"created":\#(ms)},"outcome":"\#(outcome)"}"#
}

private func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

func opencodeV2Tests(_ t: TestRunner) {
    t.suite("opencode 2.x（session_v2 / session_message）")

    func decode(_ type: String, _ json: String) throws -> [TaskEvent] {
        guard let data = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        else { throw ExpectationError(description: "坏 JSON: \(json)") }
        return OpencodeSessionMessageDecoder.decode(
            sessionID: "ses_a", type: type, data: data, cwd: "/w")
    }

    t.test("解码：user → 开始（标题取正文），idle → 按 outcome 收尾，assistant → 心跳带工具名") {
        let start = try decode("user", userData("修复登录页报错", ms: 1_780_000_000_000))
        try expectEqual(start.map(\.kind), [.taskStarted(title: "修复登录页报错")])
        try expectEqual(start.first?.timestamp, Date(timeIntervalSince1970: 1_780_000_000))
        try expectEqual(start.first?.cwd, "/w")
        try expect(start.first?.source == .opencode)

        try expectEqual(
            try decode("idle", idleData(ms: 1)).map(\.kind),
            [.taskFinished(outcome: .success, title: nil, detail: nil)])
        try expectEqual(
            try decode("idle", idleData(ms: 1, outcome: "failed")).map(\.kind),
            [.taskFinished(outcome: .error, title: nil, detail: "API key 无效")])
        try expectEqual(
            try decode("idle", idleData(ms: 1, outcome: "interrupted")).map(\.kind),
            [.taskFinished(outcome: .interrupted, title: nil, detail: "已中断")])

        try expectEqual(
            try decode("assistant", assistantData(ms: 1, finish: "tool-calls", tools: ["read", "bash"]))
                .map(\.kind),
            [.activity(tool: "bash")])
        let injected = try decode("synthetic", userData("<system-reminder>", ms: 1))
        try expect(injected.isEmpty, "注入行不是 turn 边界")
    }

    t.test("tailer：首扫定基线；新 turn → 开始 / 心跳 / 完成；子会话与迁移复制的 1.x 消息不发事件") {
        let fm = FileManager.default
        let dir = v2TempDir("oc2tail")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        let base = nowMs()
        try makeV2DB(at: dbURL) { db in
            try insertSession(db, "ses_top", createdMs: base - 60_000, updatedMs: base)
            try insertSession(db, "ses_child", parent: "ses_top", createdMs: base, updatedMs: base)
            try insertSession(db, "ses_old", version: "1.18.31", createdMs: base, updatedMs: base)
            // 历史 turn：首扫不得重放
            try insertMessage(db, "m0", session: "ses_top", type: "user", seq: 0,
                              createdMs: base - 50_000, data: userData("旧问题", ms: base - 50_000))
            try insertMessage(db, "m1", session: "ses_top", type: "idle", seq: 1,
                              createdMs: base - 40_000, data: idleData(ms: base - 40_000))
        }
        var received: [(TaskEvent, Bool)] = []
        let tailer = OpencodeEventTailer(dbPath: dbURL) { event, stale in received.append((event, stale)) }
        tailer.scanOnce()
        try expect(received.isEmpty, "首扫只定基线：\(received)")

        let writer = try SQLiteDB(path: dbURL.path)
        let t0 = nowMs()
        try insertMessage(writer, "m2", session: "ses_top", type: "user", seq: 2,
                          createdMs: t0, data: userData("新问题", ms: t0))
        try insertMessage(writer, "m3", session: "ses_top", type: "assistant", seq: 3,
                          createdMs: t0 + 10, data: assistantData(ms: t0 + 10, tools: ["grep"]))
        try insertMessage(writer, "c1", session: "ses_child", type: "idle", seq: 0,
                          createdMs: t0 + 20, data: idleData(ms: t0 + 20))
        // app 运行期间发生升级迁移：1.x 消息按原 id 复制进来 → 不发事件
        try writer.run("INSERT INTO message VALUES (?,?,?,?,?)",
                       [.text("o1"), .text("ses_old"), .int(Int64(t0)), .int(Int64(t0)), .text("{}")])
        try insertMessage(writer, "o1", session: "ses_old", type: "user", seq: 0,
                          createdMs: t0 + 20, data: userData("迁移来的", ms: t0 + 20))
        try insertMessage(writer, "m4", session: "ses_top", type: "idle", seq: 4,
                          createdMs: t0 + 30, data: idleData(ms: t0 + 30))
        // 迁移会话里续聊的新消息只在 2.x 表里 → 照常发
        try insertMessage(writer, "o2", session: "ses_old", type: "user", seq: 1,
                          createdMs: t0 + 40, data: userData("接着聊", ms: t0 + 40))
        try? writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        tailer.scanOnce()

        try expectEqual(received.map(\.0.kind), [
            .taskStarted(title: "新问题"),
            .activity(tool: "grep"),
            .taskFinished(outcome: .success, title: nil, detail: nil),
            .taskStarted(title: "接着聊"),
        ])
        try expectEqual(received.map(\.0.sessionId), ["ses_top", "ses_top", "ses_top", "ses_old"])
        try expect(received.allSatisfy { $0.0.cwd == "/Users/me/proj" }, "cwd 取 session_v2.directory")
        try expect(received.allSatisfy { !$0.1 }, "新事件不 stale")

        // 端到端：TaskStore 出恰好一张完成卡
        let store = TaskStore()
        let effects = received.flatMap { store.apply($0.0) }
        try expectEqual(effects.filter {
            if case .taskFinished = $0 { return true } else { return false }
        }.count, 1)
    }

    t.test("tailer：没有 1.x event 表也照常读 2.x；stale 按事件自身时间戳") {
        let fm = FileManager.default
        let dir = v2TempDir("oc2only")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        let base = nowMs()
        try makeV2DB(at: dbURL, withV1: false) { db in
            try insertSession(db, "ses_a", createdMs: base, updatedMs: base)
        }
        var received: [(TaskEvent, Bool)] = []
        let tailer = OpencodeEventTailer(dbPath: dbURL) { event, stale in received.append((event, stale)) }
        tailer.scanOnce()
        let writer = try SQLiteDB(path: dbURL.path)
        try insertMessage(writer, "m1", session: "ses_a", type: "idle", seq: 0,
                          createdMs: base - 3_600_000, data: idleData(ms: base - 3_600_000))
        try insertMessage(writer, "m2", session: "ses_a", type: "idle", seq: 1,
                          createdMs: base, data: idleData(ms: base))
        try? writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        tailer.scanOnce()
        try expectEqual(received.map(\.1), [true, false], "一小时前的 stale、刚写入的不 stale")
    }

    t.test("用量：已完成 assistant 行入账（模型取 model.id、provider 取 providerID），进行中停水位，迁移复制的消息不重复计") {
        let fm = FileManager.default
        let dir = v2TempDir("oc2usage")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ocURL = dir.appendingPathComponent("opencode.db")
        let storeURL = dir.appendingPathComponent("eureka.sqlite")
        let base = nowMs()
        try makeV2DB(at: ocURL) { db in
            try insertSession(db, "ses_new", createdMs: base, updatedMs: base)
            try insertSession(db, "ses_old", version: "1.18.31", createdMs: base, updatedMs: base)
            try insertMessage(db, "u1", session: "ses_new", type: "user", seq: 0,
                              createdMs: base, data: userData("问", ms: base))
            try insertMessage(db, "a1", session: "ses_new", type: "assistant", seq: 1,
                              createdMs: base + 10,
                              data: assistantData(ms: base + 10, finish: "tool-calls",
                                                  tools: ["read", "read", "bash"]))
            // 迁移复制的消息：同 id 也在 1.x message 表里，用量已由那条路径计过
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                       [.text("a_old"), .text("ses_old"), .int(Int64(base)), .int(Int64(base)),
                        .text(#"{"role":"assistant"}"#)])
            try insertMessage(db, "a_old", session: "ses_old", type: "assistant", seq: 0,
                              createdMs: base, data: assistantData(ms: base, input: 9999))
            // 迁移会话里续聊的新消息：只在 2.x 表里 → 要计
            try insertMessage(db, "a_resumed", session: "ses_old", type: "assistant", seq: 1,
                              createdMs: base + 5, data: assistantData(ms: base + 5, input: 40))
            // 进行中（未 completed、刚更新）：停在水位前
            try insertMessage(db, "a2", session: "ses_new", type: "assistant", seq: 2,
                              createdMs: base + 20,
                              data: assistantData(ms: base + 20, completed: false, input: 7))
        }

        let store = try EurekaStore(path: storeURL)
        let scanner = OpencodeUsageScanner(dbPath: ocURL, store: store)
        try expectEqual(try scanner.scanOnce(), 2)
        let totals = try store.usage.totalsForSessions(["ses_new", "ses_old"])
        try expectEqual(totals["ses_old"]?.map(\.inputTokens), [40], "复制来的消息不重复计，续聊的照常计")
        guard let row = totals["ses_new"]?.first else {
            throw ExpectationError(description: "缺 ses_new 用量：\(totals)")
        }
        try expectEqual(row.model, "glm-5.2")
        try expectEqual(row.inputTokens, 100)
        try expectEqual(row.outputTokens, 25)   // output 20 + reasoning 5
        try expectEqual(row.cacheReadTokens, 30)
        try expectEqual(row.cacheCreationTokens, 10)

        func toolCount(_ name: String) throws -> Int {
            try store.toolCalls.totals(
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 4_000_000_000), source: .opencode)
                .first { $0.name == name }?.count ?? 0
        }
        try expectEqual(try toolCount("read"), 2)
        try expectEqual(try toolCount("bash"), 1)

        // 进行中那行完成后：只补这一行，已计的不翻倍
        let writer = try SQLiteDB(path: ocURL.path)
        try writer.run("UPDATE session_message SET data = ?, time_updated = ? WHERE id = 'a2'",
                       [.text(assistantData(ms: base + 20, input: 7)), .int(Int64(base + 600))])
        try? writer.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        try expectEqual(try scanner.scanOnce(), 1)
        try expectEqual(try scanner.scanOnce(), 0)
        try expectEqual(try toolCount("read"), 2)
    }

    t.test("会话索引：两代会话合并，迁移会话同 id 只留 2.x 一条，子会话排除") {
        let fm = FileManager.default
        let dir = v2TempDir("oc2index")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let ms = Int(now.timeIntervalSince1970 * 1000)
        try makeV2DB(at: dbURL) { db in
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_v1only"), .null, .text("/a"), .text("老会话"),
                 .int(Int64(ms - 90_000)), .int(Int64(ms - 80_000))])
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_migrated"), .null, .text("/b"), .text("迁移前标题"),
                 .int(Int64(ms - 70_000)), .int(Int64(ms - 60_000))])
            try insertSession(db, "ses_migrated", directory: "/b", title: "迁移会话",
                              version: "1.18.31", createdMs: ms - 70_000, updatedMs: ms - 50_000)
            try insertSession(db, "ses_chamber", directory: "/c", title: "OpenChamber 会话",
                              createdMs: ms - 10_000, updatedMs: ms)
            try insertSession(db, "ses_sub", parent: "ses_chamber", createdMs: ms, updatedMs: ms)
        }
        let sessions = OpencodeSessionIndexer.index(dbPath: dbURL, now: now)
        try expectEqual(sessions.map(\.id), ["ses_chamber", "ses_migrated", "ses_v1only"])
        try expectEqual(sessions.map(\.name), ["OpenChamber 会话", "迁移会话", "老会话"])
        try expectEqual(sessions.first?.cwd, "/c")
    }

    t.test("会话正文：2.x 按 seq 读，text 与工具小注按出现顺序，reasoning / 注入行跳过") {
        let fm = FileManager.default
        let dir = v2TempDir("oc2read")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        let ms = 1_780_000_000_000
        try makeV2DB(at: dbURL) { db in
            try insertSession(db, "ses_a", createdMs: ms, updatedMs: ms)
            try insertMessage(db, "m1", session: "ses_a", type: "synthetic", seq: 0,
                              createdMs: ms, data: userData("<system-reminder>", ms: ms))
            try insertMessage(db, "m2", session: "ses_a", type: "user", seq: 1,
                              createdMs: ms, data: userData("看下测试", ms: ms))
            try insertMessage(db, "m3", session: "ses_a", type: "assistant", seq: 2,
                              createdMs: ms + 10,
                              data: assistantData(ms: ms + 10, tools: ["bash"], text: "测试全过了"))
            try insertMessage(db, "m4", session: "ses_a", type: "idle", seq: 3,
                              createdMs: ms + 20, data: idleData(ms: ms + 20))
        }
        let result = TranscriptReader.loadOpencode(
            dbPath: dbURL.path, sessionId: "ses_a", maxMessages: 100)
        try expectEqual(result.messages.map(\.role), [.user, .toolNote, .assistant])
        try expectEqual(result.messages.map(\.text), ["看下测试", "🔧 bash", "测试全过了"])
        try expectEqual(result.messages.first?.timestamp, Date(timeIntervalSince1970: 1_780_000_000))
    }
}
