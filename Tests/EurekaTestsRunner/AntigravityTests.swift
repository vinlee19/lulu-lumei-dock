import EurekaIngest
import EurekaKit
import Foundation

private func agTemp(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-ag-\(tag)-\(UUID().uuidString)", isDirectory: true)
}

/// 构造一段含 protobuf 短字符串（单字节长度前缀）的 db 字节，内嵌 file:// 工作区 URI
private func makeConversationDB(at url: URL, cwdURI: String, mtime: Date) throws {
    var bytes: [UInt8] = [0xAA, 0x12, 0x34]          // 前导噪声
    bytes.append(UInt8(cwdURI.utf8.count))            // protobuf 单字节长度前缀
    bytes.append(contentsOf: Array(cwdURI.utf8))
    bytes.append(contentsOf: [0x7A, 0x00, 0x01])      // 尾随 tag/噪声
    try Data(bytes).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
}

func antigravityPathsTests(_ t: TestRunner) {
    t.suite("AntigravityPaths")

    t.test("env 覆盖 + 默认路径 + 技能双根") {
        let env = [
            "EUREKA_GEMINI_HOME": "/tmp/gm",
            "EUREKA_ANTIGRAVITY_HOME": "/tmp/agy",
            "EUREKA_ANTIGRAVITY_CONVERSATIONS": "/tmp/agy/conv",
        ]
        try expectEqual(AntigravityPaths.conversationsRoot(environment: env).path, "/tmp/agy/conv")
        // 无覆盖时 home 落在 gemini 下
        let roots = AntigravityPaths.skillsRoots(environment: ["EUREKA_GEMINI_HOME": "/tmp/gm"])
        try expectEqual(roots.count, 2)
        try expect(roots[0].path.hasSuffix("/skills"), "用户技能 = ~/.gemini/skills")
        try expect(roots[1].path.hasSuffix("antigravity-cli/builtin/skills"), "内置技能根")
    }

    t.test("cwd：从 db 字节裸扫 file:// + 百分号解码；缺文件 → nil") {
        let base = agTemp("cwd")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let db1 = base.appendingPathComponent("a.db")
        try makeConversationDB(at: db1, cwdURI: "file:///Users/me/proj", mtime: Date())
        try expectEqual(AntigravityPaths.cwd(dbURL: db1), "/Users/me/proj")

        let db2 = base.appendingPathComponent("b.db")
        try makeConversationDB(at: db2, cwdURI: "file:///Users/me/a%20b", mtime: Date())
        try expectEqual(AntigravityPaths.cwd(dbURL: db2), "/Users/me/a b")

        try expect(AntigravityPaths.cwd(dbURL: base.appendingPathComponent("nope.db")) == nil)

        // 碎片写入：长度前缀超框把后面的 NUL 圈进来 → 必须退可打印段、绝不返回含控制字符的脏串
        // （这正是 live db 触发崩溃的场景：脏 cwd 让 URL.appendingPathComponent 抛 NSException）
        let db3 = base.appendingPathComponent("frag.db")
        var bytes: [UInt8] = [0xAA]
        let uri = "file:///Users/me/frag"
        bytes.append(UInt8(uri.utf8.count + 4))
        bytes.append(contentsOf: Array(uri.utf8))
        bytes.append(contentsOf: [0x00, 0x00, 0x0E, 0x03])
        try Data(bytes).write(to: db3)
        let frag = AntigravityPaths.cwd(dbURL: db3)
        try expectEqual(frag, "/Users/me/frag")
        try expect(frag?.unicodeScalars.allSatisfy { $0.value >= 0x20 } == true, "不得含控制字符")
    }
}

func antigravitySessionIndexerTests(_ t: TestRunner) {
    t.suite("AntigravitySessionIndexer")

    t.test("索引 conversations/*.db：id/cwd/时间；跳 -wal；窗口过滤") {
        let base = agTemp("idx")
        let conv = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let uuid = "8fc38225-c39e-4c40-821e-c45a62b4fd8d"
        try makeConversationDB(
            at: conv.appendingPathComponent("\(uuid).db"),
            cwdURI: "file:///Users/me/work/demo", mtime: Date())
        // -wal 兄弟文件不应被当成会话
        try Data([0x00]).write(to: conv.appendingPathComponent("\(uuid).db-wal"))
        // 窗口外的老会话
        try makeConversationDB(
            at: conv.appendingPathComponent("11111111-1111-1111-1111-111111111111.db"),
            cwdURI: "file:///old", mtime: Date().addingTimeInterval(-40 * 86400))

        let sessions = AntigravitySessionIndexer.index(conversationsRoot: conv)
        try expectEqual(sessions.count, 1, "只应有 1 个（窗口内、非 -wal）: \(sessions.map(\.id))")
        try expectEqual(sessions[0].source, .antigravity)
        try expectEqual(sessions[0].id, uuid)
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expect(sessions[0].sizeBytes > 0)
    }
}

func antigravityActivityTests(_ t: TestRunner) {
    t.suite("AntigravityActivityTailer")

    t.test("有写入 → running；静默超阈值 → 收尾转空闲") {
        let base = agTemp("act")
        let conv = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = conv.appendingPathComponent("c.db")
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)

        var events: [TaskEvent] = []
        let tailer = AntigravityActivityTailer(
            conversationsRoot: conv, runningWindow: 45, idleThreshold: 45
        ) { event, _ in events.append(event) }

        // 首见（mtime 新）→ taskStarted
        try makeConversationDB(at: db, cwdURI: "file:///Users/me/w", mtime: t0)
        tailer.scanOnce(now: t0.addingTimeInterval(1))
        guard case .taskStarted = events.first?.kind else {
            throw ExpectationError(description: "首见活跃应 taskStarted: \(events.map(\.kind))")
        }
        try expectEqual(events.first?.cwd, "/Users/me/w")

        // 有新写入 → activity
        events.removeAll()
        try FileManager.default.setAttributes(
            [.modificationDate: t0.addingTimeInterval(2)], ofItemAtPath: db.path)
        tailer.scanOnce(now: t0.addingTimeInterval(3))
        guard case .activity = events.first?.kind else {
            throw ExpectationError(description: "新写入应 activity: \(events.map(\.kind))")
        }

        // 静默超 idleThreshold → taskFinished（转空闲）
        events.removeAll()
        tailer.scanOnce(now: t0.addingTimeInterval(100))
        guard case .taskFinished(outcome: .success, _, _) = events.first?.kind else {
            throw ExpectationError(description: "静默应收尾: \(events.map(\.kind))")
        }
    }

    t.test("首见静默会话 → 登记空闲 sessionStarted") {
        let base = agTemp("idle")
        let conv = base.appendingPathComponent("conversations", isDirectory: true)
        try FileManager.default.createDirectory(at: conv, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let db = conv.appendingPathComponent("c.db")
        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        try makeConversationDB(at: db, cwdURI: "file:///w", mtime: t0)

        var events: [TaskEvent] = []
        let tailer = AntigravityActivityTailer(conversationsRoot: conv) { e, _ in events.append(e) }
        // now 远晚于 mtime（>runningWindow）→ 空闲登记
        tailer.scanOnce(now: t0.addingTimeInterval(600))
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "旧会话应登记空闲: \(events.map(\.kind))")
        }
    }
}

func antigravitySkillsTests(_ t: TestRunner) {
    t.suite("Antigravity Skills")

    t.test("indexSkills 收 antigravity 根为 .antigravity") {
        let base = agTemp("skills")
        let agRoot = base.appendingPathComponent("skills", isDirectory: true)
        let skillDir = agRoot.appendingPathComponent("my-skill", isDirectory: true)
        try FileManager.default.createDirectory(at: skillDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        try "---\nname: my-skill\ndescription: hi\n---\n".write(
            to: skillDir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: base.appendingPathComponent("none-c"),
            codexSkillsRoot: base.appendingPathComponent("none-x"),
            antigravitySkillsRoots: [agRoot])
        try expect(skills.contains { $0.source == .antigravity && $0.name == "my-skill" },
                   "应含 antigravity 技能: \(skills.map { "\($0.source):\($0.name)" })")
    }
}
