import EurekaIngest
import EurekaKit
import Foundation

/// Qoder ingest 测试：fixture 按本机真实会话（~/.qoder-cn，v1.1.5）的行格式伪造，
/// 路径/会话 id 全部换成假值；全程临时目录，不碰真实 ~/。
func qoderIngestTests(_ t: TestRunner) {
    qoderPathsTests(t)
    qoderTranscriptDecoderTests(t)
    qoderChatTailerTests(t)
    qoderSessionIndexerTests(t)
}

// MARK: - QoderPaths

private func qoderPathsTests(_ t: TestRunner) {
    t.suite("QoderPaths")

    t.test("home 优先级：EUREKA_QODER_HOME > QODER_CONFIG_DIR > ~/.qoder-cn；派生根") {
        try expectEqual(
            QoderPaths.configHome(environment: [
                "EUREKA_QODER_HOME": "/tmp/qd-home", "QODER_CONFIG_DIR": "/tmp/cli-home",
            ]).path,
            "/tmp/qd-home")
        try expectEqual(
            QoderPaths.configHome(environment: ["QODER_CONFIG_DIR": "/tmp/cli-home"]).path,
            "/tmp/cli-home")
        try expect(QoderPaths.configHome(environment: [:]).path.hasSuffix("/.qoder-cn"))
        try expectEqual(
            QoderPaths.projectsRoot(environment: ["EUREKA_QODER_HOME": "/tmp/qd-home"]).path,
            "/tmp/qd-home/projects")
        try expectEqual(
            QoderPaths.plansRoot(environment: ["EUREKA_QODER_HOME": "/tmp/qd-home"]).path,
            "/tmp/qd-home/plans")
        try expectEqual(
            QoderPaths.memoriesRoot(environment: ["EUREKA_QODER_HOME": "/tmp/qd-home"]).path,
            "/tmp/qd-home/memories")
    }

    t.test("cliBinary：glob qoderclicn-* 取最高语义版本；缺失返回 nil") {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-qoder-bin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let binDir = home.appendingPathComponent("bin/qoderclicn", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        for name in ["qoderclicn-0.9.9", "qoderclicn-1.1.5", "qoderclicn-1.10.0", "unrelated"] {
            try Data().write(to: binDir.appendingPathComponent(name))
        }
        // macOS 临时目录 /var → /private/var 符号链接：比后缀不比全路径
        let binary = QoderPaths.cliBinary(environment: ["EUREKA_QODER_HOME": home.path])
        try expect(
            binary?.path.hasSuffix("bin/qoderclicn/qoderclicn-1.10.0") == true,
            "应选最高版本 1.10.0: \(String(describing: binary))")

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-qoder-bin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        try expect(
            QoderPaths.cliBinary(environment: ["EUREKA_QODER_HOME": empty.path]) == nil,
            "无 bin 目录应返回 nil")
    }
}

// MARK: - QoderTranscriptDecoder

private func qoderTranscriptDecoderTests(_ t: TestRunner) {
    t.suite("QoderTranscriptDecoder")

    func decode(_ line: String) -> TaskEvent? {
        QoderTranscriptDecoder.decode(line: Data(line.utf8), sessionId: "s-abc", cwd: "/w")
    }

    t.test("human user 正文 → taskStarted（带标题摘要与 ISO 时间戳）") {
        let event = decode(
            #"{"type":"user","uuid":"u2","timestamp":"2026-07-25T05:47:30.143Z","message":{"role":"user","content":"分析一下当前项目"},"origin":{"kind":"human"},"cwd":"/Users/me/work/demo","sessionId":"s-abc"}"#)
        guard case .taskStarted(title: let title) = event?.kind else {
            throw ExpectationError(description: "human user 应为 taskStarted: \(String(describing: event))")
        }
        try expectEqual(title, "分析一下当前项目")
        try expectEqual(event?.source, .qoder)
        try expectEqual(event?.sessionId, "s-abc")
        // ISO-8601 带小数秒 → Date
        try expect(
            abs((event?.timestamp.timeIntervalSince1970 ?? 0) - 1_784_958_450.143) < 0.001,
            "时间戳应解析 ISO 小数秒: \(String(describing: event?.timestamp))")
    }

    t.test("user 防御：isMeta / 命令行（无 origin）/ tool_result 回灌 → 全部忽略") {
        let lines = [
            #"{"type":"user","uuid":"u1","timestamp":"2026-07-25T05:45:19.102Z","message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"},"isMeta":true,"sessionId":"s-abc"}"#,
            #"{"type":"user","uuid":"u3","timestamp":"2026-07-25T05:45:19.413Z","message":{"role":"user","content":"<command-message>plan</command-message>"},"sessionId":"s-abc"}"#,
            #"{"type":"user","uuid":"u4","timestamp":"2026-07-25T05:47:46.000Z","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]},"origin":{"kind":"human"},"sessionId":"s-abc"}"#,
            #"{"type":"user","uuid":"u5","timestamp":"2026-07-25T05:47:46.000Z","message":{"role":"user","content":"   "},"origin":{"kind":"human"},"sessionId":"s-abc"}"#,
        ]
        for line in lines {
            try expect(decode(line) == nil, "应忽略: \(line)")
        }
    }

    t.test("assistant：tool_use → activity(工具名)；text → taskFinished(success)；纯 thinking → 心跳") {
        guard case .activity(tool: "Agent") = decode(
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:46.643Z","message":{"role":"assistant","model":"qmodel_preview","content":[{"type":"thinking","thinking":"..."},{"type":"tool_use","id":"call_1","name":"Agent","input":{}}]},"sessionId":"s-abc"}"#
        )?.kind else {
            throw ExpectationError(description: "tool_use 应为 activity(Agent)")
        }
        guard case .taskFinished(outcome: .success, _, _) = decode(
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-07-25T05:48:10.000Z","message":{"role":"assistant","model":"qmodel_preview","stop_reason":"end_turn","content":[{"type":"text","text":"回答如下"}]},"sessionId":"s-abc"}"#
        )?.kind else {
            throw ExpectationError(description: "text 收尾应为 taskFinished(success)")
        }
        guard case .activity(tool: nil) = decode(
            #"{"type":"assistant","uuid":"a3","timestamp":"2026-07-25T05:47:40.000Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"推理"}]},"sessionId":"s-abc"}"#
        )?.kind else {
            throw ExpectationError(description: "纯 thinking 应为心跳")
        }
    }

    t.test("custom-title / ai-title → titleUpdate") {
        guard case .titleUpdate(title: "自定义标题") = decode(
            #"{"type":"custom-title","sessionId":"s-abc","customTitle":"自定义标题"}"#
        )?.kind else {
            throw ExpectationError(description: "custom-title 应为 titleUpdate")
        }
        guard case .titleUpdate(title: "自动标题") = decode(
            #"{"type":"ai-title","sessionId":"s-abc","aiTitle":"自动标题"}"#
        )?.kind else {
            throw ExpectationError(description: "ai-title 应为 titleUpdate")
        }
    }

    t.test("防御性：setup/meta 行 / 未知类型 / 非 JSON → 全部忽略") {
        let lines = [
            #"{"type":"workspace-directories","sessionId":"s-abc","directories":["/Users/me/work/demo"]}"#,
            #"{"type":"runtime-config","sessionId":"s-abc","model":"qmodel_preview","timestamp":1784958316222}"#,
            #"{"type":"last-prompt","sessionId":"s-abc","lastPrompt":"你好"}"#,
            #"{"type":"system","uuid":"s1","timestamp":"2026-07-25T05:45:19.309Z","subtype":"informational","content":"Switched to Plan Mode.","level":"info","sessionId":"s-abc"}"#,
            #"{"type":"file-history-snapshot","sessionId":"s-abc","messageId":"m1","snapshot":{}}"#,
            #"{"type":"some-future-type","sessionId":"s-abc"}"#,
        ]
        for line in lines {
            try expect(decode(line) == nil, "应忽略: \(line)")
        }
        try expect(decode("not json") == nil)
        try expect(decode(#"{"no_type":true}"#) == nil)
    }
}

// MARK: - QoderChatTailer

/// 在临时目录搭一个 qoder 会话树：<root>/<cwd-slug>/<sessionId>.jsonl
private func makeQoderSession(
    sessionId: String = "b3ddabc0-0000-4201-82e1-4e0f65e78212"
) throws -> (root: URL, file: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-qoder-\(UUID().uuidString)", isDirectory: true)
    let projectDir = root.appendingPathComponent(
        "-Users-me-work-demo", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    return (root, projectDir.appendingPathComponent("\(sessionId).jsonl"))
}

private func appendQoderLines(_ lines: [String], to url: URL) throws {
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

private let qoderWorkspaceLine =
    #"{"type":"workspace-directories","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","directories":["/Users/me/work/demo"]}"#
private let qoderHumanPrompt =
    #"{"type":"user","uuid":"u2","timestamp":"2026-07-25T05:47:30.143Z","message":{"role":"user","content":"分析项目结构"},"origin":{"kind":"human"},"cwd":"/Users/me/work/demo","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212"}"#
private let qoderToolUse =
    #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:46.643Z","message":{"role":"assistant","model":"qmodel_preview","content":[{"type":"tool_use","id":"call_1","name":"Bash","input":{}}]},"sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212"}"#
private let qoderFinalText =
    #"{"type":"assistant","uuid":"a2","timestamp":"2026-07-25T05:48:10.000Z","message":{"role":"assistant","model":"qmodel_preview","stop_reason":"end_turn","content":[{"type":"text","text":"分析完成"}]},"sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212"}"#

private func qoderChatTailerTests(_ t: TestRunner) {
    t.suite("QoderChatTailer")

    t.test("初见恢复运行 + ai-title 标题；增量产出 tool_use 心跳 / text 收尾") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = QoderChatTailer(projectsRoot: session.root) { events.append(($0, $1)) }

        try appendQoderLines([
            qoderWorkspaceLine,
            qoderHumanPrompt,
            #"{"type":"ai-title","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","aiTitle":"项目结构分析"}"#,
        ], to: session.file)
        tailer.scanOnce()
        guard case .taskStarted = events.first?.0.kind else {
            throw ExpectationError(description: "初见应恢复 running: \(events.map(\.0.kind))")
        }
        try expectEqual(events.first?.0.sessionId, "b3ddabc0-0000-4201-82e1-4e0f65e78212")
        try expectEqual(events.first?.0.cwd, "/Users/me/work/demo")
        try expect(events.contains { $0.0.kind == .titleUpdate(title: "项目结构分析") },
                   "应补 ai-title 标题")
        try expect(events.allSatisfy { !$0.1 }, "初见恢复的事件不应标 stale")

        events.removeAll()
        try appendQoderLines([qoderToolUse, qoderFinalText], to: session.file)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { $0 == .activity(tool: "Bash") },
                   "tool_use 应为 activity(Bash): \(kinds)")
        try expect(kinds.contains {
            if case .taskFinished(outcome: .success, title: "项目结构分析", _) = $0 { return true }
            return false
        }, "text 应为带标题的成功收尾: \(kinds)")
    }

    t.test("已完成会话初见 → sessionStarted（不重放历史）；增量旧时间戳标 stale") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = QoderChatTailer(projectsRoot: session.root) { events.append(($0, $1)) }

        try appendQoderLines([qoderWorkspaceLine, qoderHumanPrompt, qoderFinalText], to: session.file)
        tailer.scanOnce()
        // 只恢复最后状态（sessionStarted + 附带的 titleUpdate），不重放历史
        try expectEqual(events.count, 2, "不重放: \(events.map(\.0.kind))")
        guard case .sessionStarted = events[0].0.kind else {
            throw ExpectationError(description: "已完成会话初见应为 sessionStarted: \(events[0].0.kind)")
        }
        try expectEqual(events[1].0.kind, .titleUpdate(title: "分析项目结构"))

        // 增量：fixture 时间戳远旧于 300s 阈值 → stale
        events.removeAll()
        try appendQoderLines([qoderHumanPrompt], to: session.file)
        tailer.scanOnce()
        guard case .taskStarted = events.first?.0.kind else {
            throw ExpectationError(description: "增量 human user 应为 taskStarted")
        }
        try expectEqual(events.first?.1, true, "旧时间戳应标 stale")
    }

    t.test("custom-title 优先：其后的 ai-title 不再降级") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = QoderChatTailer(projectsRoot: session.root) { events.append(($0, $1)) }

        try appendQoderLines([qoderWorkspaceLine, qoderHumanPrompt], to: session.file)
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        try appendQoderLines([
            #"{"type":"custom-title","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","customTitle":"我的自定义标题"}"#,
            #"{"type":"ai-title","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","aiTitle":"自动标题"}"#,
        ], to: session.file)
        tailer.scanOnce()
        let titles = events.compactMap { event -> String? in
            if case .titleUpdate(let title) = event.0.kind { return title }
            return nil
        }
        try expectEqual(titles, ["我的自定义标题"], "ai-title 不应覆盖 custom-title")
    }

    t.test("半行不消费，补全后产出；meta/命令行不触发 taskStarted") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        var events: [(TaskEvent, Bool)] = []
        let tailer = QoderChatTailer(projectsRoot: session.root) { events.append(($0, $1)) }

        try appendQoderLines([qoderWorkspaceLine, qoderHumanPrompt], to: session.file)
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        let handle = try FileHandle(forWritingTo: session.file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(qoderFinalText.prefix(qoderFinalText.count / 2)).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出: \(events.map(\.0.kind))")

        let handle2 = try FileHandle(forWritingTo: session.file)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(
            (String(qoderFinalText.suffix(qoderFinalText.count - qoderFinalText.count / 2)) + "\n").utf8))
        try handle2.close()
        // isMeta + 命令行夹杂在同一批：都不该产出事件
        try appendQoderLines([
            #"{"type":"user","uuid":"u1","timestamp":"2026-07-25T05:45:19.102Z","message":{"role":"user","content":"<local-command-caveat>Caveat</local-command-caveat>"},"isMeta":true,"sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212"}"#,
            #"{"type":"user","uuid":"u3","timestamp":"2026-07-25T05:45:19.413Z","message":{"role":"user","content":"<command-message>plan</command-message>"},"sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212"}"#,
        ], to: session.file)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expectEqual(kinds.count, 1, "只有补全的 text 行应产出: \(kinds)")
        guard case .taskFinished(outcome: .success, _, _) = kinds[0] else {
            throw ExpectationError(description: "补全后应产出成功收尾: \(kinds)")
        }
    }
}

// MARK: - QoderSessionIndexer

private func qoderSessionIndexerTests(_ t: TestRunner) {
    t.suite("QoderSessionIndexer")

    t.test("索引：标题优先级 custom > ai > last-prompt > 首条 user；cwd/时间戳/来源") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        try appendQoderLines([
            qoderWorkspaceLine,
            #"{"type":"runtime-config","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","model":"qmodel_preview","timestamp":1784958316222}"#,
            qoderHumanPrompt,
            #"{"type":"last-prompt","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","lastPrompt":"最后的提问"}"#,
            #"{"type":"ai-title","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","aiTitle":"自动标题"}"#,
            qoderFinalText,
        ], to: session.file)

        // 无 custom-title：ai-title 胜出
        var sessions = QoderSessionIndexer.index(projectsRoot: session.root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].source, .qoder)
        try expectEqual(sessions[0].id, "b3ddabc0-0000-4201-82e1-4e0f65e78212")
        try expectEqual(sessions[0].name, "自动标题")
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expect(
            abs((sessions[0].startedAt?.timeIntervalSince1970 ?? 0) - 1_784_958_316.222) < 0.001,
            "startedAt 应取首个时间戳（runtime-config 的 epoch-ms）")
        try expectEqual(sessions[0].lastActiveAt, Date(timeIntervalSince1970: 1_784_958_490))
        try expect(sessions[0].sizeBytes > 0)
        try expect(sessions[0].transcriptPath.hasSuffix(".jsonl"))

        // 追加 custom-title：优先级最高
        try appendQoderLines([
            #"{"type":"custom-title","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","customTitle":"自定义标题"}"#,
        ], to: session.file)
        sessions = QoderSessionIndexer.index(projectsRoot: session.root)
        try expectEqual(sessions.first?.name, "自定义标题")
    }

    t.test("last-prompt / 首条 user 兜底；窗口过滤；subagents 子目录不索引") {
        let session = try makeQoderSession()
        defer { try? FileManager.default.removeItem(at: session.root) }
        // 只有 last-prompt
        try appendQoderLines([
            qoderWorkspaceLine,
            #"{"type":"last-prompt","sessionId":"b3ddabc0-0000-4201-82e1-4e0f65e78212","lastPrompt":"只剩末轮提问"}"#,
        ], to: session.file)
        // 只有首条 user 正文
        let other = session.root.appendingPathComponent(
            "-Users-me-work-demo/b5cc0000-0000-4201-82e1-4e0f65e78212.jsonl")
        try appendQoderLines([qoderWorkspaceLine, qoderHumanPrompt], to: other)
        // subagents 子目录：不该进索引
        let subagentsDir = session.root.appendingPathComponent(
            "-Users-me-work-demo/b3ddabc0-0000-4201-82e1-4e0f65e78212/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try appendQoderLines([qoderHumanPrompt], to: subagentsDir.appendingPathComponent("agent-1.jsonl"))

        let sessions = QoderSessionIndexer.index(projectsRoot: session.root)
        try expectEqual(sessions.count, 2, "subagents/ 不应单列: \(sessions.map(\.id))")
        try expectEqual(
            sessions.first { $0.id == "b3ddabc0-0000-4201-82e1-4e0f65e78212" }?.name,
            "只剩末轮提问")
        try expectEqual(
            sessions.first { $0.id == "b5cc0000-0000-4201-82e1-4e0f65e78212" }?.name,
            "分析项目结构")

        // 窗口过滤：now 拉到 31 天后 → 全部超窗
        let future = Date().addingTimeInterval(31 * 86400)
        try expect(QoderSessionIndexer.index(projectsRoot: session.root, now: future).isEmpty,
                   "超窗会话应被过滤")
    }
}
