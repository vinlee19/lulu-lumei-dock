import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

// MARK: - 路径

func zcodePathsTests(_ t: TestRunner) {
    t.suite("ZcodePaths")

    t.test("home 优先级：EUREKA_ZCODE_HOME > 默认；各派生根可独立覆盖") {
        try expectEqual(
            ZcodePaths.root(environment: ["EUREKA_ZCODE_HOME": "/tmp/zc-home"]).path,
            "/tmp/zc-home")
        try expect(ZcodePaths.root(environment: [:]).path.hasSuffix("/.zcode"))
        try expectEqual(
            ZcodePaths.cliRoot(environment: ["EUREKA_ZCODE_HOME": "/tmp/zc-home"]).path,
            "/tmp/zc-home/cli")
        try expectEqual(
            ZcodePaths.cliRoot(environment: ["EUREKA_ZCODE_CLI_ROOT": "/tmp/zc-cli"]).path,
            "/tmp/zc-cli")
        try expectEqual(
            ZcodePaths.db(environment: ["EUREKA_ZCODE_DB": "/tmp/zc.db"]).path,
            "/tmp/zc.db")
        try expectEqual(
            ZcodePaths.db(environment: ["EUREKA_ZCODE_HOME": "/tmp/zc-home"]).path,
            "/tmp/zc-home/cli/db/db.sqlite")
        try expectEqual(
            ZcodePaths.rolloutRoot(environment: ["EUREKA_ZCODE_HOME": "/tmp/zc-home"]).path,
            "/tmp/zc-home/cli/rollout")
        try expectEqual(
            ZcodePaths.agentsRoot(environment: [
                "EUREKA_ZCODE_HOME": "/tmp/zc-home", "EUREKA_ZCODE_ROLLOUT": "/tmp/zc-ro",
            ]).path,
            "/tmp/zc-home/cli/agents")  // agentsRoot 不受 ROLLOUT 覆盖影响
        try expectEqual(
            ZcodePaths.skillsRoot(environment: ["EUREKA_ZCODE_SKILLS": "/tmp/zc-skills"]).path,
            "/tmp/zc-skills")
        try expect(ZcodePaths.skillsRoot(environment: [:]).path.hasSuffix("/.agents/skills"),
                   "zcode 技能在共享 ~/.agents/skills")
    }
}

// MARK: - rollout 解码

func zcodeRolloutDecoderTests(_ t: TestRunner) {
    t.suite("ZcodeRolloutDecoder")

    t.test("文件名解会话 id") {
        try expectEqual(
            ZcodeRolloutDecoder.sessionId(fileName: "model-io-sess_abc123.jsonl"),
            "sess_abc123")
        try expect(ZcodeRolloutDecoder.sessionId(fileName: "other.jsonl") == nil)
        try expect(ZcodeRolloutDecoder.sessionId(fileName: "model-io-.jsonl") == nil)
    }

    t.test("usageRecord：response.usage 四段 token + 模型小写化；空对象返回 nil") {
        // OpenAI 口径：inputTokens 100 已含 cacheRead 10；totalTokens = input + output
        let root = try JSONDict(#"""
        {"type":"model_io","model":{"modelId":"GLM-5.3"},"response":{"finishReason":"stop","modelId":"glm-5.3","usage":{"inputTokens":100,"outputTokens":50,"totalTokens":150,"cacheReadTokens":10,"cacheWriteTokens":0}}}
        """#)
        let record = ZcodeRolloutDecoder.usageRecord(root)
        try expectEqual(record?.model, "glm-5.3")
        try expectEqual(record?.usage.input, 100)
        try expectEqual(record?.usage.output, 50)
        try expectEqual(record?.usage.cacheRead, 10)
        try expectEqual(record?.usage.total, 150, "total = input + output（cacheRead 是 input 子集，不叠加）")

        let empty = try JSONDict(
            #"{"type":"model_io","response":{"usage":{}}}"#)
        try expect(ZcodeRolloutDecoder.usageRecord(empty) == nil, "全零 usage 应返回 nil")

        let errorLine = try JSONDict(#"""
        {"type":"model_io","error":{"message":"stopped"},"completedAt":"2026-08-15T04:00:00.000Z","response":{"usage":{}}}
        """#)
        try expect(ZcodeRolloutDecoder.usageRecord(errorLine) == nil, "error 行无用量")
    }

    t.test("decode：stop → success；tool-calls → activity(工具)；error → interrupted；进行中无事件") {
        func decode(_ json: String) -> [TaskEvent] {
            ZcodeRolloutDecoder.decode(
                root: (try? JSONDict(json)) ?? [:], sessionId: "sess_x", cwd: "/w") 
        }
        guard case .taskFinished(outcome: .success, _, _)? = decode(
            #"{"type":"model_io","completedAt":"2026-08-15T04:00:01.000Z","response":{"finishReason":"stop","usage":{}}}"#
        ).first?.kind else {
            throw ExpectationError(description: "stop 应为 success")
        }
        guard case .activity(tool: "Bash")? = decode(
            #"{"type":"model_io","completedAt":"2026-08-15T04:00:01.000Z","response":{"finishReason":"tool-calls","toolCalls":[{"name":"Bash"}],"usage":{}}}"#
        ).first?.kind else {
            throw ExpectationError(description: "tool-calls 应为 activity(Bash)")
        }
        guard case .taskFinished(outcome: .interrupted, _, let detail)? = decode(
            #"{"type":"model_io","completedAt":"2026-08-15T04:00:01.000Z","error":{"message":"v4 session stopped"},"response":{}}"#
        ).first?.kind else {
            throw ExpectationError(description: "error 行应为 interrupted")
        }
        try expectEqual(detail, "v4 session stopped")
        try expect(decode(
            #"{"type":"model_io","startedAt":"2026-08-15T04:00:01.000Z","completedAt":null,"response":{}}"#
        ).isEmpty, "进行中的请求不发事件")
        try expect(decode(
            #"{"type":"other","completedAt":"2026-08-15T04:00:01.000Z"}"#
        ).isEmpty, "非 model_io 类型忽略")
    }

    t.test("userPromptText：messages 里首条 user 文本") {
        let root = try JSONDict(#"""
        {"type":"model_io","request":{"body":{"messages":[{"role":"system","content":"sys"},{"role":"user","content":"帮我修 bug"}]}}}
        """#)
        try expectEqual(ZcodeRolloutDecoder.userPromptText(root), "帮我修 bug")
        let blocks = try JSONDict(#"""
        {"type":"model_io","request":{"body":{"messages":[{"role":"user","content":[{"type":"text","text":"分块文本"}]}]}}}
        """#)
        try expectEqual(ZcodeRolloutDecoder.userPromptText(blocks), "分块文本")
    }
}

private func JSONDict(_ json: String) throws -> [String: Any] {
    guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
          let dict = object as? [String: Any]
    else { throw ExpectationError(description: "测试 JSON 解析失败") }
    return dict
}

// MARK: - 模型目录（v2/config.json 的 per-model limit.context）

func zcodeConfigWindowsTests(_ t: TestRunner) {
    t.suite("ZcodeConfigWindows")

    func makeConfig(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data(json.utf8).write(to: url)
        return url
    }

    t.test("解析 provider→models→limit.context；多 provider 同名取最大；键小写") {
        let url = try makeConfig(#"""
        { "provider": {
            "builtin:zai": { "models": {
                "GLM-5.3": { "limit": { "context": 1000000, "output": 128000 } },
                "GLM-5-Turbo": { "limit": { "context": 200000, "output": 128000 } } } },
            "custom-x": { "models": {
                "GLM-5.3": { "limit": { "context": 512000 } },
                "NoLimit": { "modalities": {} } } } } }
        """#)
        let map = ZcodeConfigWindows.parse(configURL: url)
        try expectEqual(map["glm-5.3"], 1_000_000, "同名模型多 provider 应取最大")
        try expectEqual(map["glm-5-turbo"], 200_000)
        try expect(map["nolimit"] == nil, "无 limit 的模型不入表")
        try expectEqual(
            ZcodeConfigWindows.window(forModel: "GLM-5.3", configURL: url), 1_000_000,
            "模型名大小写不敏感")
        try expect(ZcodeConfigWindows.window(forModel: nil, configURL: url) == nil)
        try expect(ZcodeConfigWindows.window(
            forModel: "glm-5.3",
            configURL: URL(fileURLWithPath: "/tmp/nope-\(UUID()).json")) == nil,
            "文件缺失返回 nil 不抛错")
    }
}

// MARK: - tailer

/// 建 rollout 目录 + 一个主会话 db（session 表只含 directory 列查询所需的行）
private func makeZcodeRolloutDir(
    sessionId: String = "sess_abc", cwd: String? = "/Users/me/work/demo"
) throws -> (root: URL, dbPath: URL, file: URL, configURL: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
    let rollout = root.appendingPathComponent("rollout", isDirectory: true)
    try FileManager.default.createDirectory(at: rollout, withIntermediateDirectories: true)
    let dbPath = root.appendingPathComponent("db.sqlite")
    if let cwd {
        let db = try SQLiteDB(path: dbPath.path)
        try db.run("""
        CREATE TABLE session (
            id text primary key, project_id text not null default '', workspace_id text,
            parent_id text, slug text not null default '', directory text not null default '',
            path text, title text not null default '', version text not null default '',
            share_url text, summary_additions integer, summary_deletions integer,
            summary_files integer, summary_diffs text, revert text, permission text,
            time_created integer not null default 0, time_updated integer not null default 0,
            time_compacting integer, time_archived integer)
        """)
        try db.run("INSERT INTO session (id, directory) VALUES ('\(sessionId)', '\(cwd)')")
    }
    let configURL = root.appendingPathComponent("v2-config.json")
    try Data(#"""
    { "provider": { "builtin:zai": { "models": {
        "GLM-5.3": { "limit": { "context": 1000000 } } } } } }
    """#.utf8).write(to: configURL)
    return (root, dbPath, rollout.appendingPathComponent("model-io-\(sessionId).jsonl"), configURL)
}

private func appendZcodeLines(_ lines: [String], to url: URL) throws {
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

private let zcodeMidStep = #"{"type":"model_io","querySource":"main_turn","startedAt":"2026-08-15T03:59:00.000Z","completedAt":"2026-08-15T03:59:05.000Z","model":{"modelId":"GLM-5.3"},"response":{"finishReason":"tool-calls","toolCalls":[{"name":"Bash"}],"usage":{"inputTokens":10,"outputTokens":5,"cacheReadTokens":0,"cacheWriteTokens":0}}}"#
private let zcodeFinalStep = #"{"type":"model_io","querySource":"main_turn","startedAt":"2026-08-15T03:59:05.000Z","completedAt":"2026-08-15T03:59:10.000Z","model":{"modelId":"GLM-5.3"},"response":{"finishReason":"stop","modelId":"glm-5.3","usage":{"inputTokens":20,"outputTokens":8,"cacheReadTokens":2,"cacheWriteTokens":0}}}"#

func zcodeTailerTests(_ t: TestRunner) {
    t.suite("ZcodeRolloutTailer")

    t.test("初见恢复：中间步未收尾 → running；cwd 从 db 查出") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try appendZcodeLines([zcodeMidStep], to: dir.file)

        var events: [(TaskEvent, Bool)] = []
        let tailer = ZcodeRolloutTailer(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, modelConfigURL: dir.configURL) {
            events.append(($0, $1))
        }
        tailer.scanOnce()
        guard case .activity = events.first?.0.kind else {
            throw ExpectationError(description: "初见中间步应恢复 running: \(events.map(\.0.kind))")
        }
        try expectEqual(events.first?.0.sessionId, "sess_abc")
        try expectEqual(events.first?.0.cwd, "/Users/me/work/demo")
        try expect(events.contains { $0.0.source == .zcode }, "事件 source 应为 zcode")
    }

    t.test("初见已收尾 → sessionStarted 空闲注册") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try appendZcodeLines([zcodeMidStep, zcodeFinalStep], to: dir.file)

        var events: [(TaskEvent, Bool)] = []
        let tailer = ZcodeRolloutTailer(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, modelConfigURL: dir.configURL) {
            events.append(($0, $1))
        }
        tailer.scanOnce()
        try expect(events.contains { $0.0.kind == .sessionStarted },
                   "已收尾应注册为空闲: \(events.map(\.0.kind))")
    }

    t.test("增量：新完成的请求产出事件；usage → contextUpdate；子代理文件跳过") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try appendZcodeLines([zcodeMidStep], to: dir.file)
        // 子代理流水：不应进事件流
        try appendZcodeLines(
            [zcodeFinalStep],
            to: dir.root.appendingPathComponent("rollout/model-io-sess_subagent_agent_x.jsonl"))

        var events: [(TaskEvent, Bool)] = []
        let tailer = ZcodeRolloutTailer(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, modelConfigURL: dir.configURL) {
            events.append(($0, $1))
        }
        tailer.scanOnce()  // 初见
        events.removeAll()

        // 大用量行（input 96k[含 cacheRead 32k] + output 1k = 97,000 ÷ config 的 1M 窗口
        // = 9.7%，超过抑制阈值 0.5%；cacheRead 是 input 子集，不参与相加）
        let bigUsage = #"{"type":"model_io","querySource":"main_turn","startedAt":"2026-08-15T03:59:05.000Z","completedAt":"2026-08-15T03:59:10.000Z","model":{"modelId":"GLM-5.3"},"response":{"finishReason":"stop","usage":{"inputTokens":96000,"outputTokens":1000,"cacheReadTokens":32000,"cacheWriteTokens":0}}}"#
        try appendZcodeLines([bigUsage], to: dir.file)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { if case .taskFinished(outcome: .success, _, _) = $0 { return true } else { return false } },
                   "终轮应产出 success: \(kinds)")
        guard kinds.contains(where: { kind in
            if case .contextUpdate(let percent) = kind { return abs(percent - 9.7) < 0.1 }
            return false
        }) else {
            throw ExpectationError(description: "97k/1M 应发 contextUpdate≈9.7%: \(kinds)")
        }
        try expect(!events.contains { $0.0.sessionId.contains("subagent") },
                   "子代理流水不该进事件流")
    }

    t.test("config 缺该模型的窗口 → 不发 contextUpdate（不猜分母）") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        // 空 provider 表：任何模型都查不到窗口
        try Data(#"{"provider":{}}"#.utf8).write(to: dir.configURL)
        try appendZcodeLines([zcodeMidStep], to: dir.file)
        var events: [(TaskEvent, Bool)] = []
        let tailer = ZcodeRolloutTailer(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, modelConfigURL: dir.configURL) {
            events.append(($0, $1))
        }
        tailer.scanOnce()
        try expect(!events.contains { if case .contextUpdate = $0.0.kind { return true } else { return false } },
                   "无窗口配置不该发 contextUpdate: \(events.map(\.0.kind))")
    }

    t.test("半行不消费，补全后产出") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try appendZcodeLines([zcodeMidStep], to: dir.file)
        var events: [(TaskEvent, Bool)] = []
        let tailer = ZcodeRolloutTailer(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, modelConfigURL: dir.configURL) {
            events.append(($0, $1))
        }
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        let handle = try FileHandle(forWritingTo: dir.file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(
            String(zcodeFinalStep.prefix(zcodeFinalStep.count / 2)).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出: \(events.map(\.0.kind))")

        let handle2 = try FileHandle(forWritingTo: dir.file)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(
            (String(zcodeFinalStep.suffix(zcodeFinalStep.count - zcodeFinalStep.count / 2))
                + "\n").utf8))
        try handle2.close()
        tailer.scanOnce()
        try expect(events.contains { if case .taskFinished = $0.0.kind { return true } else { return false } },
                   "补全后应产出完成")
    }
}

// MARK: - 会话索引

func zcodeSessionIndexerTests(_ t: TestRunner) {
    t.suite("ZcodeSessionIndexer")

    t.test("索引 session 表：顶层会话、epoch 毫秒、parent_id 过滤") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dbPath = dir.appendingPathComponent("db.sqlite")
        let db = try SQLiteDB(path: dbPath.path)
        try db.run("""
        CREATE TABLE session (
            id text primary key, project_id text not null default '', workspace_id text,
            parent_id text, slug text not null default '', directory text not null default '',
            path text, title text not null default '', version text not null default '',
            share_url text, summary_additions integer, summary_deletions integer,
            summary_files integer, summary_diffs text, revert text, permission text,
            time_created integer not null default 0, time_updated integer not null default 0,
            time_compacting integer, time_archived integer)
        """)
        let now = Date().timeIntervalSince1970 * 1000
        try db.run("INSERT INTO session (id, directory, title, time_created, time_updated) "
            + "VALUES ('sess_top', '/w/demo', '适配 ZCode', \(now - 60000), \(now))")
        try db.run("INSERT INTO session (id, parent_id, directory, time_created, time_updated) "
            + "VALUES ('sess_subagent_agent_x', 'sess_top', '/w/demo', \(now), \(now))")
        try db.run("INSERT INTO session (id, directory, title, time_created, time_updated) "
            + "VALUES ('sess_old', '/w/old', '旧会话', 1, 1)")

        let sessions = ZcodeSessionIndexer.index(dbPath: dbPath, now: Date())
        try expectEqual(sessions.count, 1)
        let session = sessions[0]
        try expectEqual(session.source, .zcode)
        try expectEqual(session.id, "sess_top")
        try expectEqual(session.cwd, "/w/demo")
        try expectEqual(session.name, "适配 ZCode")
        try expectEqual(session.transcriptPath, dbPath.path)
        try expect(session.startedAt != nil, "epoch 毫秒应解出时间")
    }

    t.test("db 不存在 → 空结果不抛错") {
        let sessions = ZcodeSessionIndexer.index(
            dbPath: URL(fileURLWithPath: "/tmp/nonexistent-zcode-\(UUID()).sqlite"))
        try expect(sessions.isEmpty)
    }
}

// MARK: - 子代理扫描

func zcodeSubagentScannerTests(_ t: TestRunner) {
    t.suite("ZcodeSubagentScanner")

    t.test("metadata.json 快照：类型/描述/状态/turn 过滤") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nowISO = ISO8601DateFormatter().string(from: Date())
        // 本 turn 的 running 子代理 + 旧 turn 的已完成子代理（应被 turnStartedAt 过滤）
        for (agent, status, offset) in [
            ("agent_run", "running", -60.0),
            ("agent_old", "completed", -7200.0),
        ] {
            let sub = dir.appendingPathComponent(agent, isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            let meta = #"""
            {"agentId":"\#(agent)","childSessionId":"sess_subagent_\#(agent)","createdAt":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(offset)))","description":"探索模块","parentSessionId":"sess_abc","profileSnapshot":{"name":"Explore","description":"read-only"},"status":"\#(status)"}
            """#
            try Data(meta.utf8).write(to: sub.appendingPathComponent("metadata.json"))
        }
        // running 子代理的 transcript 尾部带一个工具调用（raw string 内引号无需转义）
        try appendZcodeLines(
            [#"{ "id":"u1", "type":"tool_call_scheduled", "timestamp":"\#(nowISO)", "payload":{ "toolName":"Bash", "toolCallId":"c1" } }"#],
            to: dir.appendingPathComponent("agent_run/transcript.jsonl"))

        let turnStart = Date().addingTimeInterval(-300)
        let infos = ZcodeSubagentScanner.scan(sessionDir: dir, turnStartedAt: turnStart)
        try expectEqual(infos.count, 1, "旧 turn 的子代理应被过滤: \(infos.map(\.agentId))")
        let info = infos[0]
        try expectEqual(info.agentId, "agent_run")
        try expectEqual(info.agentType, "Explore")
        try expectEqual(info.description, "探索模块")
        try expectEqual(info.status, .running)
        try expectEqual(info.currentActivity, "Bash")
    }
}

// MARK: - 用量扫描

func zcodeUsageScannerTests(_ t: TestRunner) {
    t.suite("ZcodeUsageScanner")

    t.test("扫描 model_io 行：usage 入账 + 工具计数 + 水位幂等") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        // prompt 计数用的 message 表（recordPromptCounts 用）
        let db = try SQLiteDB(path: dir.dbPath.path)
        try db.run("""
        CREATE TABLE message (
            id text primary key, session_id text not null, time_created integer not null,
            time_updated integer not null, data text not null)
        """)
        try db.run("INSERT INTO message (id, session_id, time_created, time_updated, data) "
            + "VALUES ('m1', 'sess_abc', 1, 1, '{\"role\":\"user\"}')")

        try appendZcodeLines([zcodeMidStep, zcodeFinalStep], to: dir.file)
        let store = try EurekaStore(path: dir.root.appendingPathComponent("eureka.sqlite"))
        let scanner = ZcodeUsageScanner(rolloutRoot: dir.root.appendingPathComponent("rollout"), dbPath: dir.dbPath, store: store)

        let first = try scanner.scanOnce()
        try expectEqual(first, 2, "两条已完成请求各一条 usage")
        let second = try scanner.scanOnce()
        try expectEqual(second, 0, "水位推进后重扫应零新增（幂等）")

        try scanner.recordPromptCounts()
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSinceNow: -86400), to: Date())
        let zcodeRows = totals.filter { $0.source == .zcode }
        try expectEqual(zcodeRows.count, 1)
        try expectEqual(zcodeRows[0].model, "glm-5.3")
        // inputTokens 含缓存读（OpenAI 口径）→ 入库前减掉：10 + (20-2) = 28
        try expectEqual(zcodeRows[0].inputTokens, 28)
        try expectEqual(zcodeRows[0].outputTokens, 13)
        try expectEqual(zcodeRows[0].cacheReadTokens, 2)
    }

    t.test("lastZcodeContext：rollout 末条 usage 的 input+output + 模型名") {
        let dir = try makeZcodeRolloutDir()
        defer { try? FileManager.default.removeItem(at: dir.root) }
        try appendZcodeLines([zcodeMidStep, zcodeFinalStep], to: dir.file)
        guard let last = LastTurnUsageReader.lastZcodeContext(rolloutPath: dir.file.path) else {
            throw ExpectationError(description: "末条 usage 应可读出")
        }
        try expectEqual(last.tokens, 28, "input 20（已含 cacheRead 2）+ output 8")
        try expectEqual(last.model, "glm-5.3")
        try expect(LastTurnUsageReader.lastZcodeContext(
            rolloutPath: "/tmp/nonexistent-\(UUID()).jsonl") == nil, "文件缺失返回 nil")
    }

    t.test("目录为空 → 零记录不抛错") {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try EurekaStore(path: dir.appendingPathComponent("eureka.sqlite"))
        let scanner = ZcodeUsageScanner(
            rolloutRoot: dir, dbPath: dir.appendingPathComponent("nope.db"), store: store)
        try expectEqual(try scanner.scanOnce(), 0)
    }
}

// MARK: - 计划索引

func zcodePlanIndexTests(_ t: TestRunner) {
    t.suite("ZcodePlanIndex")

    t.test("<repo>/.zcode/plans：plan- 前缀收窄 + 文件名推导会话 id") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let plansDir = root.appendingPathComponent(".zcode/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        try "# 适配 ZCode\n\n- [x] 步骤一\n- [ ] 步骤二\n".write(
            to: plansDir.appendingPathComponent("plan-sess_abc.md"),
            atomically: true, encoding: .utf8)
        // 无 sess_ 段的 plan- 文件：仍收，但不关联会话
        try "# 附录\n".write(
            to: plansDir.appendingPathComponent("plan-notes.md"),
            atomically: true, encoding: .utf8)
        // 非 plan- 前缀：不收
        try "# 杂记\n".write(
            to: plansDir.appendingPathComponent("readme.md"),
            atomically: true, encoding: .utf8)

        let entries = PlanMaterializer.index(
            claudePlansDir: root.appendingPathComponent("no-claude"),
            stagingRoot: root.appendingPathComponent("no-staging"),
            zcodePlansDirs: [plansDir])
        try expectEqual(entries.count, 2, "只收 plan-*.md: \(entries.map(\.path))")
        try expect(entries.allSatisfy { $0.source == .zcode })
        guard let plan = entries.first(where: { $0.sessionId != nil }) else {
            throw ExpectationError(description: "应有一条带会话 id")
        }
        try expectEqual(plan.sessionId, "sess_abc")
        try expectEqual(plan.title, "适配 ZCode")
        try expectEqual(plan.stepsDone, 1)
        try expectEqual(plan.stepsTotal, 2)
        guard let notes = entries.first(where: { $0.sessionId == nil }) else {
            throw ExpectationError(description: "plan-notes.md 应被收录且无会话 id")
        }
        try expect(notes.path.hasSuffix("plan-notes.md"))
    }

    t.test("目录不存在 → 空结果不抛错") {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-missing-\(UUID().uuidString)")
        let entries = PlanMaterializer.index(
            claudePlansDir: missing.appendingPathComponent("claude"),
            stagingRoot: missing.appendingPathComponent("staging"),
            zcodePlansDirs: [missing.appendingPathComponent("plans")])
        try expect(entries.isEmpty)
    }
}

// MARK: - 子代理 profile 聚合（Agents 标签用）

func zcodeAgentDefinitionTests(_ t: TestRunner) {
    t.suite("ZcodeAgentDefinitions")

    t.test("聚合运行记录 profileSnapshot：按 profileId 去重、取最近快照") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-zcode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func writeMeta(
            session: String, agent: String, profileId: String,
            description: String, createdAt: String, tools: [String] = []
        ) throws {
            let dir = root.appendingPathComponent("\(session)/\(agent)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let toolsJSON = tools.map { "\"\($0)\"" }.joined(separator: ",")
            let meta = """
            {"agentId":"\(agent)","createdAt":"\(createdAt)","description":"任务描述（不该被采用）",
             "profileId":"\(profileId)",
             "profileSnapshot":{"name":"\(profileId)","description":"\(description)",
                                "color":"cyan","tools":[\(toolsJSON)]},
             "status":"completed"}
            """
            try Data(meta.utf8).write(to: dir.appendingPathComponent("metadata.json"))
        }
        try writeMeta(session: "sess_a", agent: "agent_1", profileId: "Explore",
                      description: "旧快照", createdAt: "2026-08-15T01:00:00.000Z")
        try writeMeta(session: "sess_b", agent: "agent_2", profileId: "Explore",
                      description: "新快照", createdAt: "2026-08-15T02:00:00.000Z",
                      tools: ["Bash", "Read"])
        try writeMeta(session: "sess_b", agent: "agent_3", profileId: "Coder",
                      description: "写码", createdAt: "2026-08-15T02:00:00.000Z")

        let agents = AgentDefinitionIndexer.indexZcodeObservedAgents(agentsRoot: root)
        try expectEqual(agents.count, 2, "同 profileId 应去重: \(agents.map(\.name))")
        try expectEqual(agents.map(\.name), ["Coder", "Explore"], "按名字排序")
        let explore = agents[1]
        try expectEqual(explore.source, .zcode)
        try expectEqual(explore.description, "新快照", "同 id 取最近一次快照")
        try expectEqual(explore.tools, ["Bash", "Read"])
        try expectEqual(explore.color, "cyan")
        try expect(explore.builtin, "无磁盘定义文件 → 只读展示")
        try expect(explore.path.isEmpty)
    }

    t.test("根不存在 → 空结果不抛错") {
        let agents = AgentDefinitionIndexer.indexZcodeObservedAgents(
            agentsRoot: URL(fileURLWithPath: "/tmp/nonexistent-zcode-agents-\(UUID())"))
        try expect(agents.isEmpty)
    }
}
