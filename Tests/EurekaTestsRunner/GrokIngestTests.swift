import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func grokPathsTests(_ t: TestRunner) {
    t.suite("GrokPaths")

    t.test("env 覆盖 sessions / home / skills / memory") {
        let env = [
            "EUREKA_GROK_HOME": "/tmp/gk-home",
            "EUREKA_GROK_SESSIONS": "/tmp/gk-sess",
            "EUREKA_GROK_SKILLS": "/tmp/gk-skills",
            "EUREKA_GROK_MEMORY": "/tmp/gk-mem",
        ]
        try expectEqual(GrokPaths.sessionsRoot(environment: env).path, "/tmp/gk-sess")
        try expectEqual(GrokPaths.skillsRoot(environment: env).path, "/tmp/gk-skills")
        try expectEqual(GrokPaths.memoryRoot(environment: env).path, "/tmp/gk-mem")
        // 无 EUREKA_GROK_SESSIONS 时落在 home 下
        try expectEqual(
            GrokPaths.sessionsRoot(environment: ["EUREKA_GROK_HOME": "/tmp/gk-home"]).path,
            "/tmp/gk-home/sessions")
        // agentsRoots：用户 agents + 内置 bundled/agents
        let agents = GrokPaths.agentsRoots(environment: ["EUREKA_GROK_HOME": "/tmp/gk-home"])
        try expectEqual(agents.count, 2)
        try expect(agents[0].path.hasSuffix("/agents"))
        try expect(agents[1].path.hasSuffix("/bundled/agents"))
    }
}

func grokEventDecoderTests(_ t: TestRunner) {
    t.suite("GrokEventDecoder")

    func decode(_ line: String) -> [TaskEvent] {
        GrokEventDecoder.decode(line: Data(line.utf8), sessionId: "s1", cwd: "/w")
    }

    t.test("turn_started → running；turn_ended(completed) → success") {
        guard case .taskStarted = decode(
            #"{"ts":"2026-07-09T09:50:42.760Z","type":"turn_started","session_id":"s1","model_id":"grok-4.5"}"#
        ).first?.kind else {
            throw ExpectationError(description: "turn_started 应为 taskStarted")
        }
        guard case .taskFinished(outcome: .success, _, _) = decode(
            #"{"ts":"2026-07-09T09:50:47.000Z","type":"turn_ended","outcome":"completed"}"#
        ).first?.kind else {
            throw ExpectationError(description: "turn_ended(completed) 应为 success")
        }
        guard case .taskFinished(outcome: .interrupted, _, _) = decode(
            #"{"ts":"2026-07-09T09:50:47.000Z","type":"turn_ended","outcome":"aborted"}"#
        ).first?.kind else {
            throw ExpectationError(description: "turn_ended(aborted) 应为 interrupted")
        }
    }

    t.test("permission_requested → 等待权限；permission_resolved / tool_started → 心跳") {
        guard case .waiting(reason: .permission, let msg) = decode(
            #"{"ts":"2026-07-09T09:50:44.000Z","type":"permission_requested","tool_name":"run_terminal_command"}"#
        ).first?.kind else {
            throw ExpectationError(description: "permission_requested 应为 waiting(.permission)")
        }
        try expectEqual(msg, "run_terminal_command")

        guard case .activity(tool: "list_dir") = decode(
            #"{"ts":"2026-07-09T09:50:46.000Z","type":"tool_started","tool_name":"list_dir"}"#
        ).first?.kind else {
            throw ExpectationError(description: "tool_started 应为 activity(tool)")
        }
        guard case .activity = decode(
            #"{"ts":"2026-07-09T09:50:45.000Z","type":"permission_resolved","tool_name":"x","decision":"allow"}"#
        ).first?.kind else {
            throw ExpectationError(description: "permission_resolved 应复位为 activity")
        }
        guard case .activity(tool: nil) = decode(
            #"{"ts":"2026-07-09T09:50:43.000Z","type":"phase_changed","phase":"streaming_text"}"#
        ).first?.kind else {
            throw ExpectationError(description: "phase_changed 应为 activity(nil)")
        }
    }

    t.test("mcp_* / 坏行 → 空") {
        try expect(decode(
            #"{"ts":"2026-07-09T09:50:34.182Z","type":"mcp_server_starting","server_name":"x"}"#
        ).isEmpty)
        try expect(decode("not json").isEmpty)
    }
}

/// 在临时目录搭一个 grok 会话树：<root>/<enc-cwd>/<uuid>/{events.jsonl, summary.json}
private func makeGrokSession() throws -> (root: URL, events: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-grok-\(UUID().uuidString)", isDirectory: true)
    let dir = root
        .appendingPathComponent("enc-demo", isDirectory: true)
        .appendingPathComponent("grok-sess-1", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let summary = #"""
    {"info":{"id":"grok-sess-1","cwd":"/Users/me/work/demo"},"generated_title":"补全语义层缓存","created_at":"2026-07-09T09:50:32.000Z","last_active_at":"2026-07-09T09:55:00.000Z","current_model_id":"grok-4.5"}
    """#
    try Data(summary.utf8).write(to: dir.appendingPathComponent("summary.json"))
    return (root, dir.appendingPathComponent("events.jsonl"))
}

private func appendLines(_ lines: [String], to url: URL) throws {
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

func grokRolloutTests(_ t: TestRunner) {
    t.suite("GrokRolloutTailer")

    let turnStart = #"{"ts":"2026-07-09T09:50:42.760Z","type":"turn_started","session_id":"grok-sess-1","model_id":"grok-4.5"}"#
    let permReq = #"{"ts":"2026-07-09T09:50:44.000Z","type":"permission_requested","tool_name":"bash"}"#
    let permResolved = #"{"ts":"2026-07-09T09:50:45.000Z","type":"permission_resolved","tool_name":"bash","decision":"allow"}"#
    let turnEnd = #"{"ts":"2026-07-09T09:50:47.000Z","type":"turn_ended","outcome":"completed"}"#

    t.test("初见恢复运行 + 标题（从 summary.json）；增量产出等待/完成") {
        let session = try makeGrokSession()
        // 无 updates.jsonl → 不发 context；modelsCache 指向不存在路径保持 hermetic
        var events: [(TaskEvent, Bool)] = []
        let tailer = GrokRolloutTailer(
            sessionsRoot: session.root,
            modelsCacheURL: session.root.appendingPathComponent("nope.json")
        ) { events.append(($0, $1)) }

        // 初见：仅 turn_started → 恢复 running + 从 summary 补标题
        try appendLines([turnStart], to: session.events)
        tailer.scanOnce()
        guard case .taskStarted = events.first?.0.kind else {
            throw ExpectationError(description: "初见应恢复 running: \(events.map(\.0.kind))")
        }
        try expectEqual(events.first?.0.sessionId, "grok-sess-1")
        try expectEqual(events.first?.0.cwd, "/Users/me/work/demo")
        try expect(events.contains { $0.0.kind == .titleUpdate(title: "补全语义层缓存") },
                   "应从 summary 补标题")

        // 增量：permission_requested → waiting；turn_ended → finished
        events.removeAll()
        try appendLines([permReq, permResolved, turnEnd], to: session.events)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { if case .waiting(reason: .permission, _) = $0 { return true } else { return false } },
                   "应有等待权限: \(kinds)")
        try expect(kinds.contains { if case .taskFinished(outcome: .success, _, _) = $0 { return true } else { return false } },
                   "应有成功完成: \(kinds)")
    }

    t.test("半行不消费，补全后产出") {
        let session = try makeGrokSession()
        var events: [(TaskEvent, Bool)] = []
        let tailer = GrokRolloutTailer(
            sessionsRoot: session.root,
            modelsCacheURL: session.root.appendingPathComponent("nope.json")
        ) { events.append(($0, $1)) }

        try appendLines([turnStart], to: session.events)
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        // 写半行（无换行）→ 不产出
        let handle = try FileHandle(forWritingTo: session.events)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(turnEnd.prefix(turnEnd.count / 2)).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出: \(events.map(\.0.kind))")

        // 补全后半行 + 换行 → 产出完成
        let handle2 = try FileHandle(forWritingTo: session.events)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data((String(turnEnd.suffix(turnEnd.count - turnEnd.count / 2)) + "\n").utf8))
        try handle2.close()
        tailer.scanOnce()
        try expect(events.contains { if case .taskFinished = $0.0.kind { return true } else { return false } },
                   "补全后应产出完成")
    }
}

func grokUsageScannerTests(_ t: TestRunner) {
    t.suite("GrokUsageScanner")

    t.test("tool_started → 工具计数；turn_started → 提问数；不写费用账；水位幂等") {
        let session = try makeGrokSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        try appendLines([
            #"{"ts":"2026-07-09T09:50:42.000Z","type":"turn_started","session_id":"grok-sess-1","model_id":"grok-4.5"}"#,
            #"{"ts":"2026-07-09T09:50:43.000Z","type":"tool_started","tool_name":"read_file"}"#,
            #"{"ts":"2026-07-09T09:50:44.000Z","type":"tool_started","tool_name":"read_file"}"#,
            #"{"ts":"2026-07-09T09:50:45.000Z","type":"tool_started","tool_name":"bash"}"#,
            #"{"ts":"2026-07-09T09:50:46.000Z","type":"phase_changed","phase":"streaming_text"}"#,
            #"{"ts":"2026-07-09T09:50:47.000Z","type":"turn_started","session_id":"grok-sess-1"}"#,
            #"{"ts":"2026-07-09T09:50:48.000Z","type":"turn_ended","outcome":"completed"}"#,
        ], to: session.events)

        let store = try EurekaStore(path: session.root.appendingPathComponent("eureka.sqlite"))
        let scanner = GrokUsageScanner(sessionsRoot: session.root, store: store)
        let bumped = try scanner.scanOnce()
        try expectEqual(bumped, 3)  // read_file×2 + bash×1

        func count(_ name: String) throws -> Int {
            try store.toolCalls.totals(
                from: Date(timeIntervalSince1970: 0),
                to: Date(timeIntervalSince1970: 4_000_000_000), source: .grok)
                .first { $0.name == name }?.count ?? 0
        }
        try expectEqual(try count("read_file"), 2)
        try expectEqual(try count("bash"), 1)

        // 提问数 = turn_started 数 = 2（按会话 id join）
        try expectEqual(
            try store.sessionStats.promptCounts(for: ["grok-sess-1"])["grok-sess-1"] ?? 0, 2)

        // grok 不写 usage_records（无 token/费用）
        let usageRows = try store.usage.totalsForSessions(["grok-sess-1"])
        try expect(usageRows["grok-sess-1"] == nil, "grok 不应有用量行")

        // 再扫一次：水位已过，计数不翻倍
        _ = try scanner.scanOnce()
        try expectEqual(try count("read_file"), 2)
        try expectEqual(
            try store.sessionStats.promptCounts(for: ["grok-sess-1"])["grok-sess-1"] ?? 0, 2)
    }
}

func grokSessionIndexerTests(_ t: TestRunner) {
    t.suite("GrokSessionIndexer")

    t.test("索引 summary.json：id/cwd/标题/transcriptPath") {
        let session = try makeGrokSession()
        // 索引读 lastActive（summary last_active_at）判窗口；写一个 chat_history 以有 size
        try Data(#"{"type":"assistant","content":"hi"}"#.utf8).write(
            to: session.events.deletingLastPathComponent()
                .appendingPathComponent("chat_history.jsonl"))

        let sessions = GrokSessionIndexer.index(sessionsRoot: session.root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].source, .grok)
        try expectEqual(sessions[0].id, "grok-sess-1")
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expectEqual(sessions[0].name, "补全语义层缓存")
        try expect(sessions[0].transcriptPath.hasSuffix("chat_history.jsonl"))
        try expect(sessions[0].sizeBytes > 0)
    }
}
