import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

// MARK: - fixture 工具：造一个 opencode 形状的临时 SQLite 库

private func makeOpencodeDB(at url: URL, _ build: (SQLiteDB) throws -> Void) throws {
    let db = try SQLiteDB(path: url.path)
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
    try build(db)
    try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")  // 落盘，读连接可见
}

private func tempDir(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

func opencodeSessionIndexerTests(_ t: TestRunner) {
    t.suite("OpencodeSessionIndexer")

    t.test("只返回顶层会话；directory→cwd、ms→Date 映射") {
        let fm = FileManager.default
        let dir = tempDir("ocsess")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        try makeOpencodeDB(at: dbURL) { db in
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_top"), .null, .text("/Users/me/proj"), .text("顶层会话"),
                 .int(nowMs - 60000), .int(nowMs)])
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_child"), .text("ses_top"), .text("/Users/me/proj"),
                 .text("子 agent"), .int(nowMs - 30000), .int(nowMs - 20000)])
        }

        let sessions = OpencodeSessionIndexer.index(dbPath: dbURL, now: now)
        try expectEqual(sessions.count, 1)
        let s = sessions[0]
        try expectEqual(s.id, "ses_top")
        try expect(s.source == .opencode)
        try expectEqual(s.cwd, "/Users/me/proj")
        try expectEqual(s.name, "顶层会话")
        try expectEqual(s.startedAt, Date(timeIntervalSince1970: Double(nowMs - 60000) / 1000))
        try expectEqual(s.lastActiveAt, Date(timeIntervalSince1970: Double(nowMs) / 1000))
    }

    t.test("db 不存在 → 空") {
        let missing = tempDir("ocmiss").appendingPathComponent("nope.db")
        try expect(OpencodeSessionIndexer.index(dbPath: missing).isEmpty)
    }
}

func opencodeUsageScannerTests(_ t: TestRunner) {
    t.suite("OpencodeUsageScanner")

    t.test("assistant 消息 token 落库；rowid 水位增量幂等") {
        let fm = FileManager.default
        let dir = tempDir("ocusage")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ocURL = dir.appendingPathComponent("opencode.db")
        let storeURL = dir.appendingPathComponent("eureka.sqlite")

        let created = 1_780_000_100_000
        try makeOpencodeDB(at: ocURL) { db in
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_x"), .null, .text("/Users/me/proj"), .text("t"),
                 .int(Int64(created) - 1000), .int(Int64(created))])
            // 已完成的 assistant 消息
            let done = """
            {"role":"assistant","tokens":{"input":100,"output":20,"reasoning":5,\
            "cache":{"read":30,"write":10}},"time":{"created":\(created),"completed":\(created + 500)},\
            "modelID":"glm-5.2","providerID":"volc"}
            """
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                [.text("msg_done"), .text("ses_x"), .int(Int64(created)),
                 .int(Int64(created + 500)), .text(done)])
        }

        let store = try EurekaStore(path: storeURL)
        let scanner = OpencodeUsageScanner(dbPath: ocURL, store: store)
        let first = try scanner.scanOnce()
        try expectEqual(first, 1)

        let totals = try store.usage.totalsForSessions(["ses_x"])
        guard let rows = totals["ses_x"], let row = rows.first else {
            throw ExpectationError(description: "缺 ses_x 用量")
        }
        try expect(row.source == .opencode)
        try expectEqual(row.inputTokens, 100)
        try expectEqual(row.outputTokens, 25)   // output 20 + reasoning 5
        try expectEqual(row.cacheReadTokens, 30)
        try expectEqual(row.cacheCreationTokens, 10)

        // 再扫一次：水位已过，无新增
        let second = try scanner.scanOnce()
        try expectEqual(second, 0)
    }

    t.test("part 表 tool 分片 → 工具计数；rowid 水位增量幂等") {
        let fm = FileManager.default
        let dir = tempDir("octool")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let ocURL = dir.appendingPathComponent("opencode.db")
        let storeURL = dir.appendingPathComponent("eureka.sqlite")

        let created = 1_780_000_100_000
        try makeOpencodeDB(at: ocURL) { db in
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("ses_x"), .null, .text("/w"), .text("t"),
                 .int(Int64(created) - 1000), .int(Int64(created))])
            // 3 个 tool 分片（read×2, bash×1）+ 1 个 text/reasoning（不计）
            func part(_ id: String, _ json: String) throws {
                try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                    [.text(id), .text("m1"), .text("ses_x"),
                     .int(Int64(created)), .int(Int64(created)), .text(json)])
            }
            try part("p1", #"{"type":"tool","tool":"read"}"#)
            try part("p2", #"{"type":"tool","tool":"read"}"#)
            try part("p3", #"{"type":"tool","tool":"bash"}"#)
            try part("p4", #"{"type":"text","text":"hi"}"#)
            try part("p5", #"{"type":"reasoning","text":"..."}"#)
        }

        let store = try EurekaStore(path: storeURL)
        let scanner = OpencodeUsageScanner(dbPath: ocURL, store: store)
        _ = try scanner.scanOnce()

        func count(_ name: String) throws -> Int {
            try store.toolCalls.totals(
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 4_000_000_000), source: .opencode)
                .first { $0.name == name }?.count ?? 0
        }
        try expectEqual(try count("read"), 2)
        try expectEqual(try count("bash"), 1)

        // 再扫一次：part 水位已过，计数不翻倍
        _ = try scanner.scanOnce()
        try expectEqual(try count("read"), 2)
    }
}

func opencodeEventDecoderTests(_ t: TestRunner) {
    t.suite("OpencodeEventDecoder")

    func decode(_ type: String, _ data: [String: Any]) -> [TaskEvent] {
        OpencodeEventDecoder.decode(type: type, data: data)
    }

    t.test("session.created 顶层 → sessionStarted（带 cwd），子会话 → 空") {
        let top = decode("session.created.1", [
            "sessionID": "ses_a",
            "info": ["id": "ses_a", "directory": "/w", "time": ["created": 1_780_000_000_000]],
        ])
        try expectEqual(top.count, 1)
        try expect(top[0].kind == .sessionStarted)
        try expectEqual(top[0].cwd, "/w")
        try expect(top[0].source == .opencode)

        let child = decode("session.created.1", [
            "sessionID": "ses_b",
            "info": ["id": "ses_b", "parentID": "ses_a", "directory": "/w"],
        ])
        try expect(child.isEmpty, "子会话不建独立任务")
    }

    t.test("message.updated user→taskStarted，assistant 完成→taskFinished，未完成→空") {
        let user = decode("message.updated.1", [
            "sessionID": "ses_a", "info": ["role": "user", "time": ["created": 1_780_000_000_000]],
        ])
        try expect(user.count == 1 && user[0].kind == .taskStarted(title: nil))

        let done = decode("message.updated.1", [
            "sessionID": "ses_a",
            "info": ["role": "assistant", "time": ["created": 1, "completed": 2]],
        ])
        try expect(done.count == 1 && done[0].kind == .taskFinished(outcome: .success, title: nil, detail: nil))

        let running = decode("message.updated.1", [
            "sessionID": "ses_a", "info": ["role": "assistant", "time": ["created": 1]],
        ])
        try expect(running.isEmpty, "未完成的 assistant 不出完成事件")
    }

    t.test("assistant 中间工具轮 finish=tool-calls → 空；stop → taskFinished") {
        func assistant(finish: String?) -> [TaskEvent] {
            var info: [String: Any] = ["role": "assistant", "time": ["created": 1, "completed": 2]]
            if let finish { info["finish"] = finish }
            return decode("message.updated.1", ["sessionID": "ses_a", "info": info])
        }
        try expect(assistant(finish: "tool-calls").isEmpty, "中间工具轮不算任务完成")
        try expect(assistant(finish: "tool_use").isEmpty, "中间工具轮不算任务完成（旧命名）")

        let stop = assistant(finish: "stop")
        try expect(stop.count == 1 && stop[0].kind == .taskFinished(outcome: .success, title: nil, detail: nil),
                   "stop 才是任务完成")
        let length = assistant(finish: "length")
        try expect(length.count == 1, "length（截断）也是 turn 结束")
        let missing = assistant(finish: nil)
        try expect(missing.count == 1, "缺 finish 保守当作完成，避免漏报")
    }

    t.test("message.part.updated tool → activity(tool)") {
        let events = decode("message.part.updated.1", [
            "sessionID": "ses_a", "part": ["type": "tool", "tool": "glob"],
        ])
        try expect(events.count == 1 && events[0].kind == .activity(tool: "glob"))
    }
}

// MARK: - 事件 tailer：水位与 stale 判定

/// 2026-09-05 实测事故：某一轮 `MAX(rowid)` 查询失败被当成"rowid 回退"，水位归零，
/// 25,571 条历史事件全部当实时事件重放 —— 灵动岛排进上百张完成卡收不回去，
/// 22 个 7、8 月的旧会话被重新建成运行中、一分钟后又被判"中断"写进历史。
func opencodeEventTailerTests(_ t: TestRunner) {
    t.suite("OpencodeEventTailer · 水位与 stale")

    func userMessage(_ session: String, createdMs: Int) -> String {
        #"{"sessionID":"\#(session)","info":{"role":"user","time":{"created":\#(createdMs)}}}"#
    }
    func assistantDone(_ session: String, completedMs: Int) -> String {
        #"{"sessionID":"\#(session)","info":{"role":"assistant","finish":"stop","time":{"created":\#(completedMs - 1000),"completed":\#(completedMs)}}}"#
    }
    func insert(_ db: SQLiteDB, _ id: String, _ type: String, _ json: String) throws {
        try db.run(
            "INSERT INTO event (id, aggregate_id, seq, type, data) VALUES (?,?,?,?,?)",
            [.text(id), .text("ses_a"), .int(0), .text(type), .text(json)])
    }
    func checkpoint(_ db: SQLiteDB) { try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)") }
    func nowMs() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    t.test("水位：MAX(rowid) 查询失败（库暂不可读）不得当成 rowid 回退去重放历史") {
        let fm = FileManager.default
        let dir = tempDir("octail-fail")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        try makeOpencodeDB(at: dbURL) { db in
            try insert(db, "e1", "message.updated.1", userMessage("ses_a", createdMs: nowMs()))
            try insert(db, "e2", "message.updated.1", assistantDone("ses_a", completedMs: nowMs()))
        }
        var received: [(TaskEvent, Bool)] = []
        let tailer = OpencodeEventTailer(dbPath: dbURL) { event, stale in received.append((event, stale)) }
        tailer.scanOnce()
        try expect(received.isEmpty, "首扫只定基线")

        // 连接能打开、但 MAX(rowid) 这一句查询失败（IO 抖动 / 锁超时 / 表暂不可用）：
        // 用"把表临时改名"精确模拟这一层失败，再改回来
        let writer = try SQLiteDB(path: dbURL.path)
        try writer.execute("ALTER TABLE event RENAME TO event_hidden")
        checkpoint(writer)
        tailer.scanOnce()
        try writer.execute("ALTER TABLE event_hidden RENAME TO event")
        checkpoint(writer)
        tailer.scanOnce()
        try expect(
            received.isEmpty,
            "查询失败必须保住水位，历史不得重放；实得 \(received.count) 条")
    }

    t.test("水位：事件表被重建变小（rowid 真回退）→ 重定基线，不把重建后的历史当实时事件") {
        let fm = FileManager.default
        let dir = tempDir("octail-shrink")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        try makeOpencodeDB(at: dbURL) { db in
            for i in 1...3 {
                try insert(db, "e\(i)", "message.updated.1", assistantDone("ses_a", completedMs: nowMs()))
            }
        }
        var received: [(TaskEvent, Bool)] = []
        let tailer = OpencodeEventTailer(dbPath: dbURL) { event, stale in received.append((event, stale)) }
        tailer.scanOnce()  // 基线 = 3
        // 模拟 opencode 重建库：清表后写入 1 条历史事件（rowid 从 1 重新计）
        let writer = try SQLiteDB(path: dbURL.path)
        try writer.run("DELETE FROM event")
        try insert(writer, "e9", "message.updated.1", assistantDone("ses_a", completedMs: nowMs()))
        checkpoint(writer)
        tailer.scanOnce()
        try expect(received.isEmpty, "回退后只重定基线；实得 \(received.count) 条")
        // 之后的新事件照常实时送达
        try insert(writer, "e10", "message.updated.1", userMessage("ses_a", createdMs: nowMs()))
        checkpoint(writer)
        tailer.scanOnce()
        try expectEqual(received.count, 1, "重定基线之后的新事件要能收到")
    }

    t.test("stale：事件按自身时间戳判定（>5 分钟 = 积压），与其它源同一条规则") {
        let fm = FileManager.default
        let dir = tempDir("octail-stale")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("opencode.db")
        try makeOpencodeDB(at: dbURL) { db in
            try insert(db, "e1", "message.updated.1", userMessage("ses_a", createdMs: nowMs()))
        }
        var received: [(TaskEvent, Bool)] = []
        let tailer = OpencodeEventTailer(dbPath: dbURL) { event, stale in received.append((event, stale)) }
        tailer.scanOnce()
        let writer = try SQLiteDB(path: dbURL.path)
        try insert(writer, "e2", "message.updated.1",
                   assistantDone("ses_a", completedMs: nowMs() - 3600 * 1000))  // 一小时前完成
        try insert(writer, "e3", "message.updated.1", assistantDone("ses_a", completedMs: nowMs()))
        checkpoint(writer)
        tailer.scanOnce()
        try expectEqual(received.map(\.1), [true, false], "旧事件 stale、新事件不 stale")
    }
}
