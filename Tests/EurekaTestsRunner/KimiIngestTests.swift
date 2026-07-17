import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func kimiPathsTests(_ t: TestRunner) {
    t.suite("KimiPaths")

    t.test("home 优先级：EUREKA_KIMI_HOME > KIMI_CODE_HOME > 默认；派生根可覆盖") {
        try expectEqual(
            KimiPaths.configHome(environment: [
                "EUREKA_KIMI_HOME": "/tmp/km-home", "KIMI_CODE_HOME": "/tmp/cli-home",
            ]).path,
            "/tmp/km-home")
        try expectEqual(
            KimiPaths.configHome(environment: ["KIMI_CODE_HOME": "/tmp/cli-home"]).path,
            "/tmp/cli-home")
        try expect(KimiPaths.configHome(environment: [:]).path.hasSuffix("/.kimi-code"))
        try expectEqual(
            KimiPaths.sessionsRoot(environment: ["EUREKA_KIMI_HOME": "/tmp/km-home"]).path,
            "/tmp/km-home/sessions")
        try expectEqual(
            KimiPaths.sessionsRoot(environment: ["EUREKA_KIMI_SESSIONS": "/tmp/km-sess"]).path,
            "/tmp/km-sess")
        try expectEqual(
            KimiPaths.skillsRoot(environment: ["EUREKA_KIMI_SKILLS": "/tmp/km-skills"]).path,
            "/tmp/km-skills")
        try expectEqual(
            KimiPaths.configToml(environment: ["EUREKA_KIMI_HOME": "/tmp/km-home"]).path,
            "/tmp/km-home/config.toml")
    }
}

func kimiWireDecoderTests(_ t: TestRunner) {
    t.suite("KimiWireDecoder")

    func decode(_ line: String) -> [TaskEvent] {
        KimiWireDecoder.decode(line: Data(line.utf8), sessionId: "s1", cwd: "/w")
    }

    t.test("turn.prompt(user) → running；非 user 来源 → 心跳") {
        guard case .taskStarted = decode(
            #"{"type":"turn.prompt","input":[{"type":"text","text":"你好"}],"origin":{"kind":"user"},"time":1784260206267}"#
        ).first?.kind else {
            throw ExpectationError(description: "turn.prompt(user) 应为 taskStarted")
        }
        guard case .activity = decode(
            #"{"type":"turn.prompt","input":[],"origin":{"kind":"compact"},"time":1784260206267}"#
        ).first?.kind else {
            throw ExpectationError(description: "turn.prompt(非 user) 应为心跳")
        }
    }

    t.test("step.end：end_turn → success；tool_use → 心跳；error → error") {
        guard case .taskFinished(outcome: .success, _, _) = decode(
            #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"end_turn"},"time":1784260228090}"#
        ).first?.kind else {
            throw ExpectationError(description: "end_turn 应为 success")
        }
        guard case .activity = decode(
            #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"tool_use"},"time":1784260228090}"#
        ).first?.kind else {
            throw ExpectationError(description: "tool_use 应为中间步心跳")
        }
        guard case .taskFinished(outcome: .error, _, _) = decode(
            #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"error"},"time":1784260228090}"#
        ).first?.kind else {
            throw ExpectationError(description: "error 应为出错结束")
        }
    }

    t.test("tool.call → activity(工具名)；approval.requested → 等待权限（防御保留）") {
        guard case .activity(tool: "Bash") = decode(
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Bash","args":{"cmd":"ls"}},"time":1784260244624}"#
        ).first?.kind else {
            throw ExpectationError(description: "tool.call 应为 activity(Bash)")
        }
        guard case .waiting(reason: .permission, let msg) = decode(
            #"{"type":"approval.requested","toolName":"Bash","time":1784260244624}"#
        ).first?.kind else {
            throw ExpectationError(description: "approval.requested 应为 waiting(.permission)")
        }
        try expectEqual(msg, "Bash")
    }

    t.test("usage.record → 忽略（终轮 step.end 之后到达，作心跳会复活已完成任务）") {
        try expect(decode(
            #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":1,"output":1,"inputCacheRead":0,"inputCacheCreation":0},"usageScope":"turn","time":1784260228091}"#
        ).isEmpty, "usage.record 不应产出任务状态事件")
    }

    t.test("防御性：setup 事件 / 未知类型 / 非 JSON → 全部忽略") {
        let setupLines = [
            #"{"type":"metadata","protocol_version":"1.4","created_at":1784258240300}"#,
            #"{"type":"config.update","modelAlias":"kimi-code/k3","time":1784258240300}"#,
            #"{"type":"mcp.tools_discovered","serverName":"idea","time":1784258240301}"#,
            #"{"type":"tools.set_active_tools","names":["Read"],"time":1784258240301}"#,
            #"{"type":"plan_mode.enter","id":"x","time":1784258407924}"#,
            #"{"type":"session.something_new","time":1784258407924}"#,
        ]
        for line in setupLines {
            try expect(decode(line).isEmpty, "应忽略: \(line)")
        }
        try expect(decode("not json").isEmpty)
    }

    t.test("旁路提取：usage.record / toolCall / promptText / assistantText") {
        let usageRoot = try parse(
            #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":100,"output":50,"inputCacheRead":20,"inputCacheCreation":5},"usageScope":"turn","time":1784260228091}"#)
        let record = KimiWireDecoder.usageRecord(usageRoot)
        try expectEqual(record?.model, "kimi-code/k3")
        try expectEqual(record?.usage.input, 100)
        try expectEqual(record?.usage.output, 50)
        try expectEqual(record?.usage.cacheRead, 20)
        try expectEqual(record?.usage.cacheCreation, 5)
        try expectEqual(record?.usage.total, 175)

        let callRoot = try parse(
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Skill","args":{"skill":"tdd"}},"time":1}"#)
        let call = KimiWireDecoder.toolCall(callRoot)
        try expectEqual(call?.name, "Skill")
        try expectEqual(call?.args["skill"] as? String, "tdd")

        let promptRoot = try parse(
            #"{"type":"turn.prompt","input":[{"type":"text","text":"第一段"},{"type":"text","text":"第二段"}],"origin":{"kind":"user"},"time":1}"#)
        try expectEqual(KimiWireDecoder.promptText(promptRoot), "第一段\n第二段")

        let textRoot = try parse(
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"回答"}},"time":1}"#)
        try expectEqual(KimiWireDecoder.assistantText(textRoot), "回答")
        let thinkRoot = try parse(
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"推理"}},"time":1}"#)
        try expect(KimiWireDecoder.assistantText(thinkRoot) == nil, "think 段不当正文")
    }
}

private func parse(_ json: String) throws -> [String: Any] {
    guard let root = (try? JSONSerialization.jsonObject(
        with: Data(json.utf8))) as? [String: Any] else {
        throw ExpectationError(description: "fixture 非法 JSON: \(json)")
    }
    return root
}

/// 在临时目录搭一个 kimi 会话树：
/// <root>/wd_demo_ea973e2e828f/session_abc/{state.json, agents/<id>/wire.jsonl}
private func makeKimiSession(
    title: String = "补全语义层缓存",
    agents: [String] = ["main"],
    updatedOffset: TimeInterval = -60
) throws -> (root: URL, sessionDir: URL, mainWire: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-kimi-\(UUID().uuidString)", isDirectory: true)
    let sessionDir = root
        .appendingPathComponent("wd_demo_ea973e2e828f", isDirectory: true)
        .appendingPathComponent("session_abc", isDirectory: true)
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let created = iso.string(from: Date().addingTimeInterval(-3600))
    let updated = iso.string(from: Date().addingTimeInterval(updatedOffset))
    let state = #"""
    {"createdAt":"\#(created)","updatedAt":"\#(updated)","title":"\#(title)","isCustomTitle":false,"agents":{"main":{"type":"main","parentAgentId":null}},"workDir":"/Users/me/work/demo"}
    """#
    for agent in agents {
        try FileManager.default.createDirectory(
            at: sessionDir.appendingPathComponent("agents/\(agent)", isDirectory: true),
            withIntermediateDirectories: true)
    }
    try Data(state.utf8).write(to: sessionDir.appendingPathComponent("state.json"))
    return (root, sessionDir, sessionDir.appendingPathComponent("agents/main/wire.jsonl"))
}

private func appendKimiLines(_ lines: [String], to url: URL) throws {
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

func kimiTailerTests(_ t: TestRunner) {
    t.suite("KimiWireTailer")

    let turnPrompt = #"{"type":"turn.prompt","input":[{"type":"text","text":"你好"}],"origin":{"kind":"user"},"time":1784260206267}"#
    let stepEndFinal = #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"end_turn"},"time":1784260228090}"#
    let stepEndTool = #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"tool_use"},"time":1784260227000}"#

    t.test("初见恢复运行 + 标题（从 state.json）；增量产出中间步心跳/完成") {
        let session = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = KimiWireTailer(
            sessionsRoot: session.root,
            configTomlURL: session.root.appendingPathComponent("nope.toml")
        ) { events.append(($0, $1)) }

        try appendKimiLines([turnPrompt], to: session.mainWire)
        tailer.scanOnce()
        guard case .taskStarted = events.first?.0.kind else {
            throw ExpectationError(description: "初见应恢复 running: \(events.map(\.0.kind))")
        }
        try expectEqual(events.first?.0.sessionId, "session_abc")
        try expectEqual(events.first?.0.cwd, "/Users/me/work/demo")
        try expect(events.contains { $0.0.kind == .titleUpdate(title: "补全语义层缓存") },
                   "应从 state.json 补标题")

        events.removeAll()
        try appendKimiLines([stepEndTool, stepEndFinal], to: session.mainWire)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { if case .activity = $0 { return true } else { return false } },
                   "中间步应为心跳: \(kinds)")
        try expect(kinds.contains { if case .taskFinished(outcome: .success, _, _) = $0 { return true } else { return false } },
                   "end_turn 应为成功完成: \(kinds)")
    }

    t.test("state.json 标题刷新 → titleUpdate；usage.record → contextUpdate（config.toml 窗口）") {
        let session = try makeKimiSession(title: "New Session")
        defer { try? FileManager.default.removeItem(at: session.root) }
        // config.toml：k3 窗口 1000 → usage total 175 → 17.5%
        let configToml = session.root.appendingPathComponent("config.toml")
        try Data("""
        [models."kimi-code/k3"]
        max_context_size = 1000
        """.utf8).write(to: configToml)

        var events: [(TaskEvent, Bool)] = []
        let tailer = KimiWireTailer(
            sessionsRoot: session.root, configTomlURL: configToml
        ) { events.append(($0, $1)) }

        try appendKimiLines([turnPrompt], to: session.mainWire)
        tailer.scanOnce()  // 初见（默认标题不发 titleUpdate）
        try expect(!events.contains { if case .titleUpdate = $0.0.kind { return true } else { return false } },
                   "默认标题 New Session 不应发 titleUpdate")

        // 标题在首轮后生成 → 改写 state.json，增量轮询发 titleUpdate
        events.removeAll()
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = iso.string(from: Date())
        try Data(#"""
        {"createdAt":"\#(now)","updatedAt":"\#(now)","title":"梳理配额文档","isCustomTitle":false,"workDir":"/Users/me/work/demo"}
        """#.utf8).write(to: session.sessionDir.appendingPathComponent("state.json"))
        try appendKimiLines([
            #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":100,"output":50,"inputCacheRead":20,"inputCacheCreation":5},"time":1784260228091}"#,
        ], to: session.mainWire)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { $0 == .titleUpdate(title: "梳理配额文档") },
                   "标题变化应发 titleUpdate: \(kinds)")
        try expect(kinds.contains { kind in
            if case .contextUpdate(let percent) = kind { return abs(percent - 17.5) < 0.01 }
            return false
        }, "usage 175/1000 应发 contextUpdate 17.5%: \(kinds)")
    }

    t.test("半行不消费，补全后产出") {
        let session = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = KimiWireTailer(
            sessionsRoot: session.root,
            configTomlURL: session.root.appendingPathComponent("nope.toml")
        ) { events.append(($0, $1)) }

        try appendKimiLines([turnPrompt], to: session.mainWire)
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        let handle = try FileHandle(forWritingTo: session.mainWire)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(stepEndFinal.prefix(stepEndFinal.count / 2)).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出: \(events.map(\.0.kind))")

        let handle2 = try FileHandle(forWritingTo: session.mainWire)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(
            (String(stepEndFinal.suffix(stepEndFinal.count - stepEndFinal.count / 2)) + "\n").utf8))
        try handle2.close()
        tailer.scanOnce()
        try expect(events.contains { if case .taskFinished = $0.0.kind { return true } else { return false } },
                   "补全后应产出完成")
    }
}

func kimiSessionIndexerTests(_ t: TestRunner) {
    t.suite("KimiSessionIndexer")

    t.test("索引 state.json：id/cwd/标题/size 汇总多 agent/transcriptPath") {
        let session = try makeKimiSession(agents: ["main", "sub1"])
        defer { try? FileManager.default.removeItem(at: session.root) }
        try Data(#"{"type":"metadata"}"#.utf8).write(to: session.mainWire)
        try Data(Data(repeating: UInt8(ascii: "x"), count: 100)).write(
            to: session.sessionDir.appendingPathComponent("agents/sub1/wire.jsonl"))

        let sessions = KimiSessionIndexer.index(sessionsRoot: session.root)
        try expectEqual(sessions.count, 1)  // 子代理不单列
        try expectEqual(sessions[0].source, .kimi)
        try expectEqual(sessions[0].id, "session_abc")
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expectEqual(sessions[0].name, "补全语义层缓存")
        try expect(sessions[0].transcriptPath.hasSuffix("agents/main/wire.jsonl"))
        try expect(sessions[0].sizeBytes > 100, "size 应汇总 main+sub1")
    }

    t.test("0 轮次会话（默认标题 + 创建即无更新）不进列表") {
        let empty = try makeKimiSession(title: "New Session", updatedOffset: -3600 + 5)
        defer { try? FileManager.default.removeItem(at: empty.root) }
        try Data(#"{"type":"metadata"}"#.utf8).write(to: empty.mainWire)
        try expect(KimiSessionIndexer.index(sessionsRoot: empty.root).isEmpty,
                   "空会话应被过滤")

        // 有真实标题的照常展示（即使时间接近）
        let titled = try makeKimiSession(title: "真标题", updatedOffset: -3600 + 5)
        defer { try? FileManager.default.removeItem(at: titled.root) }
        try Data(#"{"type":"metadata"}"#.utf8).write(to: titled.mainWire)
        try expectEqual(KimiSessionIndexer.index(sessionsRoot: titled.root).count, 1)
    }
}

func kimiUsageScannerTests(_ t: TestRunner) {
    t.suite("KimiUsageScanner")

    t.test("usage.record → 用量行；tool.call kind 归类；提问数；重扫幂等") {
        let session = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        try appendKimiLines([
            #"{"type":"config.update","modelAlias":"kimi-code/k3","time":1784258379136}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"你好"}],"origin":{"kind":"user"},"time":1784260206267}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Skill","args":{"skill":"tdd"}},"time":1784260244624}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"mcp__ctx7__query-docs","args":{}},"time":1784260244625}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Agent","args":{"subagent_type":"reviewer"}},"time":1784260244626}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Bash","args":{"cmd":"ls"}},"time":1784260244627}"#,
            #"{"type":"usage.record","model":"kimi-code/kimi-for-coding","usage":{"inputOther":100,"output":50,"inputCacheRead":20,"inputCacheCreation":5},"usageScope":"turn","time":1784260228091}"#,
        ], to: session.mainWire)

        let store = try EurekaStore(path: session.root.appendingPathComponent("eureka.sqlite"))
        let scanner = KimiUsageScanner(sessionsRoot: session.root, store: store)
        let inserted = try scanner.scanOnce()
        try expectEqual(inserted, 1)

        // 用量行：model 原样带前缀、token 四段、会话归属
        let usageRows = try store.usage.totalsForSessions(["session_abc"])
        let rows = usageRows["session_abc"] ?? []
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].model, "kimi-code/kimi-for-coding")
        try expectEqual(rows[0].inputTokens, 100)
        try expectEqual(rows[0].outputTokens, 50)
        try expectEqual(rows[0].cacheReadTokens, 20)
        try expectEqual(rows[0].cacheCreationTokens, 5)

        // tool_calls kind 归类（skill 名取 args.skill；mcp 去前缀；agent 取 subagent_type）
        let totals = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000), source: .kimi)
        func entry(_ kind: String) -> (name: String, count: Int)? {
            totals.first { $0.kind == kind }.map { ($0.name, $0.count) }
        }
        try expectEqual(entry("skill")?.name, "tdd")
        try expectEqual(entry("mcp")?.name, "ctx7.query-docs")
        try expectEqual(entry("agent")?.name, "reviewer")
        try expectEqual(entry("tool")?.name, "Bash")

        // 技能统计有 last_ts（Skills 分析视图数据源）
        let skillStats = try store.toolCalls.skillStats(source: .kimi)
        try expectEqual(skillStats.count, 1)
        try expect(skillStats[0].lastTs != nil, "skill 调用应带 last_ts")

        // 提问数（main agent）
        try expectEqual(
            try store.sessionStats.promptCounts(for: ["session_abc"])["session_abc"] ?? 0, 1)

        // 重扫幂等：水位已过，不翻倍
        _ = try scanner.scanOnce()
        let rows2 = (try store.usage.totalsForSessions(["session_abc"]))["session_abc"] ?? []
        try expectEqual(rows2.count, 1)
        try expectEqual(rows2[0].requestCount, 1)
        try expectEqual(
            try store.sessionStats.promptCounts(for: ["session_abc"])["session_abc"] ?? 0, 1)
    }

    t.test("子代理 wire：token 计入（归父会话），提问不计") {
        let session = try makeKimiSession(agents: ["main", "sub1"])
        defer { try? FileManager.default.removeItem(at: session.root) }
        try Data(#"{"type":"metadata"}"#.utf8).write(to: session.mainWire)
        try appendKimiLines([
            #"{"type":"turn.prompt","input":[{"type":"text","text":"子任务"}],"origin":{"kind":"user"},"time":1784260206267}"#,
            #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":1784260228091}"#,
        ], to: session.sessionDir.appendingPathComponent("agents/sub1/wire.jsonl"))

        let store = try EurekaStore(path: session.root.appendingPathComponent("eureka.sqlite"))
        let scanner = KimiUsageScanner(sessionsRoot: session.root, store: store)
        try expectEqual(try scanner.scanOnce(), 1)
        let rows = (try store.usage.totalsForSessions(["session_abc"]))["session_abc"] ?? []
        try expectEqual(rows.count, 1)  // 子代理 usage 归父会话
        // 子代理的 turn.prompt 不计提问
        try expectEqual(
            try store.sessionStats.promptCounts(for: ["session_abc"])["session_abc"] ?? 0, 0)
    }
}

func kimiTranscriptAndPlansTests(_ t: TestRunner) {
    t.suite("Kimi transcript / plans")

    t.test("loadKimi：user/assistant/🔧 小注；think 跳过；epoch-ms 时间") {
        let session = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        try appendKimiLines([
            #"{"type":"metadata","protocol_version":"1.4","created_at":1784258240300}"#,
            #"{"type":"turn.prompt","input":[{"type":"text","text":"你好"}],"origin":{"kind":"user"},"time":1784260206267}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"think","think":"推理中"}},"time":1784260228000}"#,
            #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"FetchURL","args":{"url":"https://x"}},"time":1784260228050}"#,
            #"{"type":"context.append_loop_event","event":{"type":"content.part","part":{"type":"text","text":"你好！有什么可以帮你？"}},"time":1784260228089}"#,
        ], to: session.mainWire)

        let result = TranscriptReader.loadKimi(path: session.mainWire.path, maxMessages: 100)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "你好")
        try expectEqual(result.messages[1].role, .toolNote)
        try expectEqual(result.messages[1].text, "🔧 FetchURL")
        try expectEqual(result.messages[2].role, .assistant)
        try expectEqual(result.messages[2].text, "你好！有什么可以帮你？")
        // epoch-ms → Date
        try expectEqual(
            result.messages[0].timestamp,
            Date(timeIntervalSince1970: 1784260206.267))
    }

    t.test("materializeKimi：plans/* 拷贝暂存；二次运行 0 变更；空目录 no-op") {
        let session = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let plansDir = session.sessionDir.appendingPathComponent(
            "agents/main/plans", isDirectory: true)
        try FileManager.default.createDirectory(at: plansDir, withIntermediateDirectories: true)
        try Data("# 计划\n步骤".utf8).write(to: plansDir.appendingPathComponent("refactor.md"))

        let staging = session.root.appendingPathComponent("staging", isDirectory: true)
        try expectEqual(
            PlanMaterializer.materializeKimi(sessionsRoot: session.root, into: staging), 1)
        let out = staging.appendingPathComponent("kimi/session_abc-refactor.md")
        try expectEqual(try String(contentsOf: out, encoding: .utf8), "# 计划\n步骤")
        // 幂等
        try expectEqual(
            PlanMaterializer.materializeKimi(
                sessionsRoot: session.root, into: staging), 0)

        // 空 plans 目录 no-op
        let empty = try makeKimiSession()
        defer { try? FileManager.default.removeItem(at: empty.root) }
        try expectEqual(
            PlanMaterializer.materializeKimi(sessionsRoot: empty.root, into: staging), 0)
    }
}
