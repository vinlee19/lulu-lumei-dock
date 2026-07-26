import EurekaIngest
import EurekaKit
import Foundation

/// 三源子 agent 快照测试：qoder（复用 ClaudeSubagentScanner）/ codebuddy / kimi。
/// fixture 按本机真实会话（2026-07 实勘）的行格式伪造，路径/会话 id 全部换成假值；
/// 全程临时目录，不碰真实 ~/。每源覆盖：快照字段、两次扫描的 running→completed、
/// 快照不变不重发、未跟踪会话不发事件（幻影任务不变式）。
func subagentSourceTests(_ t: TestRunner) {
    qoderSubagentTests(t)
    codeBuddySubagentTests(t)
    kimiSubagentTests(t)
}

// MARK: - 共用小工具

private func makeTempRoot(_ prefix: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}

private func appendLines(_ lines: [String], to url: URL) throws {
    let data = Data((lines.joined(separator: "\n") + "\n").utf8)
    if FileManager.default.fileExists(atPath: url.path) {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    } else {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
}

private func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

private func isoMs(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func subagentEvents(_ events: [(TaskEvent, Bool)]) -> [[SubagentInfo]] {
    events.compactMap {
        if case .subagentsUpdated(let list) = $0.0.kind { return list }
        return nil
    }
}

// MARK: - Qoder（复用 ClaudeSubagentScanner + QoderChatTailer）

private func qoderSubagentTests(_ t: TestRunner) {
    t.suite("QoderSubagents")

    let sid = "b3ddabc0-0000-4201-82e1-0000000000q1"
    let agentId = "aExplore-ab12cd34"
    let userLine = #"{"type":"user","uuid":"u1","timestamp":"TS","message":{"role":"user","content":"探索一下这个仓库"},"origin":{"kind":"human"},"cwd":"/work/demo","sessionId":"SID"}"#
    let metaJson = #"{"agentType":"Explore","toolUseId":"call_q1","description":"探索仓库结构","color":"cyan"}"#
    let agentLines = [
        #"{"type":"user","uuid":"s1","timestamp":"TS","message":{"role":"user","content":"探索仓库结构"}}"#,
        #"{"type":"assistant","uuid":"s2","timestamp":"TS","message":{"role":"assistant","content":[{"type":"tool_use","name":"WebFetch","input":{}}]}}"#,
    ]

    func makeSession() throws -> (root: URL, transcript: URL) {
        let root = makeTempRoot("eureka-qoder-sub")
        let projectDir = root.appendingPathComponent("projects/-work-demo", isDirectory: true)
        let transcript = projectDir.appendingPathComponent("\(sid).jsonl")
        try appendLines(
            [userLine
                .replacingOccurrences(of: "TS", with: isoMs(Date().addingTimeInterval(-5)))
                .replacingOccurrences(of: "SID", with: sid)],
            to: transcript)
        let subagentsDir = projectDir.appendingPathComponent("\(sid)/subagents", isDirectory: true)
        try appendLines([metaJson], to: subagentsDir.appendingPathComponent("agent-\(agentId).meta.json"))
        try appendLines(
            agentLines.map { $0.replacingOccurrences(of: "TS", with: isoMs(Date())) },
            to: subagentsDir.appendingPathComponent("agent-\(agentId).jsonl"))
        return (root, transcript)
    }

    t.test("快照：qoder meta 派生 id/类型/描述，running 带当前工具；task-*.json 落定转 completed") {
        let (root, transcript) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = transcript.deletingPathExtension()

        let first = ClaudeSubagentScanner.scan(sessionDir: sessionDir, parentTranscript: transcript)
        try expectEqual(first.count, 1)
        let run = first[0]
        try expectEqual(run.agentId, agentId)  // agent-<type>-<hex>.meta.json 的推导
        try expectEqual(run.agentType, "Explore")
        try expectEqual(run.description, "探索仓库结构")
        try expectEqual(run.status, .running)
        try expectEqual(run.currentActivity, "WebFetch")

        // Qoder 兜底完成信号：subagents/task-<agentId>.json 的 status
        try appendLines(
            [#"{"taskId":"\#(agentId)","status":"completed","summary":"done"}"#],
            to: sessionDir.appendingPathComponent("subagents/task-\(agentId).json"))
        let second = ClaudeSubagentScanner.scan(sessionDir: sessionDir, parentTranscript: transcript)
        try expectEqual(second.count, 1)
        try expectEqual(second[0].status, .completed)
        try expectEqual(second[0].currentActivity, nil)
    }

    t.test("按 turn 起点裁剪：晚于 meta 创建时间 → 空") {
        let (root, transcript) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let subs = ClaudeSubagentScanner.scan(
            sessionDir: transcript.deletingPathExtension(), parentTranscript: transcript,
            turnStartedAt: .distantFuture)
        try expect(subs.isEmpty, "晚于 turn 起点的应被过滤")
    }

    t.test("tailer：运行中发出快照；不变不重发；task 落定后补发 completed；未跟踪会话不发") {
        let (root, _) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        // 未跟踪会话：只有 subagents/ 没有父 transcript，不应产生任何事件
        let ghostDir = root.appendingPathComponent(
            "projects/-work-demo/\("ff000000-0000-0000-0000-00000000gh0")/subagents", isDirectory: true)
        try appendLines([metaJson], to: ghostDir.appendingPathComponent("agent-\(agentId).meta.json"))

        var events: [(TaskEvent, Bool)] = []
        let tailer = QoderChatTailer(projectsRoot: root.appendingPathComponent("projects")) {
            events.append(($0, $1))
        }
        tailer.scanOnce()
        let first = subagentEvents(events)
        try expectEqual(first.count, 1)
        try expectEqual(first.first?.count, 1)
        try expectEqual(first.first?.first?.status, .running)

        // 快照不变：不再发
        events.removeAll()
        tailer.scanOnce()
        try expect(subagentEvents(events).isEmpty, "快照不变不应重发: \(events.map(\.0.kind))")

        // task-*.json 落定 → completed
        let sessionDir = root.appendingPathComponent("projects/-work-demo/\(sid)")
        try appendLines(
            [#"{"taskId":"\#(agentId)","status":"completed"}"#],
            to: sessionDir.appendingPathComponent("subagents/task-\(agentId).json"))
        tailer.scanOnce()
        let second = subagentEvents(events)
        try expectEqual(second.count, 1)
        try expectEqual(second.first?.first?.status, .completed)
        try expect(
            events.allSatisfy { $0.0.sessionId != "ff000000-0000-0000-0000-00000000gh0" },
            "未跟踪会话不应发任何事件")
    }
}

// MARK: - CodeBuddy（CodeBuddySubagentScanner + CodeBuddyChatTailer）

private func codeBuddySubagentTests(_ t: TestRunner) {
    t.suite("CodeBuddySubagents")

    let sid = "a0cd6d00-0000-4d09-bb14-000000000cb1"
    let userLine = #"{"id":"u1","timestamp":TS,"type":"message","role":"user","content":[{"type":"input_text","text":"分析 profile 源码"}],"sessionId":"SID","cwd":"/work/demo"}"#
    let agentCall = #"{"id":"f1","timestamp":TS,"type":"function_call","callId":"call_agent1","name":"Agent","arguments":"{\"description\":\"分析 FE 源码\",\"subagent_type\":\"Explore\",\"prompt\":\"深入分析 FE 源码实现细节\"}","sessionId":"SID","cwd":"/work/demo"}"#
    let taskCall = #"{"id":"f2","timestamp":TS,"type":"function_call","callId":"call_task1","name":"TaskCreate","arguments":"{\"subject\":\"整理分析报告\"}","sessionId":"SID","cwd":"/work/demo"}"#
    let agentTranscriptLines = [
        #"{"id":"m1","timestamp":TS,"type":"message","role":"user","content":[{"type":"input_text","text":"深入分析 FE 源码实现细节"}],"sessionId":"sub","cwd":"/work/demo"}"#,
        #"{"id":"m2","timestamp":TS,"type":"function_call","callId":"call_inner1","name":"Grep","arguments":"{\"pattern\":\"Profile\"}","sessionId":"sub","cwd":"/work/demo"}"#,
    ]

    func makeSession() throws -> (root: URL, transcript: URL) {
        let root = makeTempRoot("eureka-codebuddy-sub")
        let projectDir = root.appendingPathComponent("projects/-work-demo", isDirectory: true)
        let transcript = projectDir.appendingPathComponent("\(sid).jsonl")
        let now = nowMs()
        try appendLines(
            [
                userLine.replacingOccurrences(of: "TS", with: "\(now - 5000)"),
                agentCall.replacingOccurrences(of: "TS", with: "\(now - 4000)"),
                taskCall.replacingOccurrences(of: "TS", with: "\(now - 3000)"),
            ].map { $0.replacingOccurrences(of: "SID", with: sid) },
            to: transcript)
        try appendLines(
            agentTranscriptLines.map { $0.replacingOccurrences(of: "TS", with: "\(now - 3500)") },
            to: projectDir.appendingPathComponent("\(sid)/subagents/agent-a1b2c3d4.jsonl"))
        return (root, transcript)
    }

    t.test("快照：function_call 派生 id/类型/描述，running 按 prompt 定位 transcript 取当前工具") {
        let (root, transcript) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let subs = CodeBuddySubagentScanner.scan(
            sessionDir: transcript.deletingPathExtension(), parentTranscript: transcript)
        try expectEqual(subs.count, 2)
        let agent = subs[0]  // 按 call 时间排序：agentCall 在前
        try expectEqual(agent.agentId, "call_agent1")
        try expectEqual(agent.agentType, "Explore")
        try expectEqual(agent.description, "分析 FE 源码")
        try expectEqual(agent.status, .running)
        try expectEqual(agent.currentActivity, "Grep")
        let task = subs[1]
        try expectEqual(task.agentId, "call_task1")
        try expectEqual(task.agentType, "task")  // TaskCreate 无 subagent_type，按工具名兜底
        try expectEqual(task.description, "整理分析报告")
        try expectEqual(task.status, .running)
        try expectEqual(task.currentActivity, nil)  // 无 prompt，不定位 transcript
    }

    t.test("两次扫描：function_call_result 落定 completed / 非 completed 记 failed") {
        let (root, transcript) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = nowMs()
        try appendLines([
            #"{"id":"r1","timestamp":\#(now),"type":"function_call_result","callId":"call_agent1","name":"Agent","status":"completed","output":{"type":"text","text":"报告"},"sessionId":"\#(sid)","cwd":"/work/demo"}"#,
            #"{"id":"r2","timestamp":\#(now),"type":"function_call_result","callId":"call_task1","name":"TaskCreate","status":"error","sessionId":"\#(sid)","cwd":"/work/demo"}"#,
        ], to: transcript)
        let subs = CodeBuddySubagentScanner.scan(
            sessionDir: transcript.deletingPathExtension(), parentTranscript: transcript)
        try expectEqual(subs.count, 2)
        try expectEqual(subs[0].status, .completed)
        try expectEqual(subs[0].currentActivity, nil)  // 完成后不再读 transcript
        try expectEqual(subs[1].status, .failed)
    }

    t.test("tailer：运行中发出快照；不变不重发；result 落定后补发；未跟踪会话不发") {
        let (root, transcript) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        // 未跟踪会话：只有 subagents/ 没有父 transcript
        let ghostDir = root.appendingPathComponent(
            "projects/-work-demo/\("ee000000-0000-0000-0000-00000000gh2")/subagents", isDirectory: true)
        try appendLines(
            agentTranscriptLines.map { $0.replacingOccurrences(of: "TS", with: "\(nowMs())") },
            to: ghostDir.appendingPathComponent("agent-b2c3d4e5.jsonl"))

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodeBuddyChatTailer(projectsRoot: root.appendingPathComponent("projects")) {
            events.append(($0, $1))
        }
        tailer.scanOnce()
        let first = subagentEvents(events)
        try expectEqual(first.count, 1)
        try expectEqual(first.first?.count, 2)
        try expect(first.first?.allSatisfy { $0.status == .running } == true,
                   "初见两个调用都应 running: \(String(describing: first.first))")

        events.removeAll()
        tailer.scanOnce()
        try expect(subagentEvents(events).isEmpty, "快照不变不应重发: \(events.map(\.0.kind))")

        try appendLines([
            #"{"id":"r1","timestamp":\#(nowMs()),"type":"function_call_result","callId":"call_agent1","name":"Agent","status":"completed","sessionId":"\#(sid)","cwd":"/work/demo"}"#
        ], to: transcript)
        tailer.scanOnce()
        let second = subagentEvents(events)
        try expectEqual(second.count, 1)
        try expectEqual(second.first?.first?.status, .completed)
        try expect(
            events.allSatisfy { $0.0.sessionId != "ee000000-0000-0000-0000-00000000gh2" },
            "未跟踪会话不应发任何事件")
    }
}

// MARK: - Kimi（KimiSubagentScanner + KimiWireTailer）

private func kimiSubagentTests(_ t: TestRunner) {
    t.suite("KimiSubagents")

    let sid = "session_abc"
    let mainPrompt = #"{"type":"turn.prompt","input":[{"type":"text","text":"分析一下这个项目"}],"origin":{"kind":"user"},"time":TS}"#
    let subPrompt = #"{"type":"turn.prompt","input":[{"type":"text","text":"<git-context>\nWorking directory: /work/demo\n</git-context>\n\nThoroughness: thorough.\n\n分析执行层架构"}],"origin":{"kind":"system_trigger","name":"subagent"},"time":TS}"#
    let subToolCall = #"{"type":"context.append_loop_event","event":{"type":"tool.call","name":"Read","args":{"path":"a.swift"}},"time":TS}"#
    let subStepEnd = #"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"end_turn"},"time":TS}"#
    let subUsage = #"{"type":"usage.record","model":"kimi-code/k3","usage":{"inputOther":10,"output":5,"inputCacheRead":0,"inputCacheCreation":0},"time":TS}"#

    func makeSession() throws -> (root: URL, sessionDir: URL, mainWire: URL, subWire: URL) {
        let root = makeTempRoot("eureka-kimi-sub")
        let sessionDir = root
            .appendingPathComponent("wd_demo_ea973e2e828f", isDirectory: true)
            .appendingPathComponent(sid, isDirectory: true)
        let created = isoMs(Date().addingTimeInterval(-3600))
        let updated = isoMs(Date())
        let state = #"""
        {"createdAt":"\#(created)","updatedAt":"\#(updated)","title":"分析项目","isCustomTitle":false,"agents":{"main":{"type":"main","parentAgentId":null},"agent-0":{"type":"sub","parentAgentId":"main"}},"workDir":"/work/demo"}
        """#
        try appendLines([state], to: sessionDir.appendingPathComponent("state.json"))
        let mainWire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
        try appendLines(
            [mainPrompt.replacingOccurrences(of: "TS", with: "\(nowMs() - 5000)")],
            to: mainWire)
        let subWire = sessionDir.appendingPathComponent("agents/agent-0/wire.jsonl")
        try appendLines(
            [
                #"{"type":"metadata","protocol_version":1,"created_at":\#(nowMs() - 4500)}"#,
                subPrompt.replacingOccurrences(of: "TS", with: "\(nowMs() - 4500)"),
                subToolCall.replacingOccurrences(of: "TS", with: "\(nowMs() - 3000)"),
            ],
            to: subWire)
        return (root, sessionDir, mainWire, subWire)
    }

    t.test("快照：state.json 类型 + 首个 prompt 描述（剥 git-context）；running 带当前工具；收尾转 completed") {
        let (root, sessionDir, _, subWire) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = KimiSubagentScanner.scan(sessionDir: sessionDir)
        try expectEqual(first.count, 1)
        let run = first[0]
        try expectEqual(run.agentId, "agent-0")
        try expectEqual(run.agentType, "sub")
        try expectEqual(run.description, "分析执行层架构")
        try expectEqual(run.status, .running)
        try expectEqual(run.currentActivity, "Read")

        // 终轮 step.end + usage.record（usage 不应复活状态）
        try appendLines(
            [
                subStepEnd.replacingOccurrences(of: "TS", with: "\(nowMs() - 1000)"),
                subUsage.replacingOccurrences(of: "TS", with: "\(nowMs() - 900)"),
            ],
            to: subWire)
        let second = KimiSubagentScanner.scan(sessionDir: sessionDir)
        try expectEqual(second.count, 1)
        try expectEqual(second[0].status, .completed)
        try expectEqual(second[0].currentActivity, nil)
    }

    t.test("终轮 error → failed；按 turn 起点裁剪（wire 创建时间）") {
        let (root, sessionDir, _, subWire) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines(
            [#"{"type":"context.append_loop_event","event":{"type":"step.end","finishReason":"error"},"time":\#(nowMs() - 1000)}"#],
            to: subWire)
        let subs = KimiSubagentScanner.scan(sessionDir: sessionDir)
        try expectEqual(subs.first?.status, .failed)

        let future = KimiSubagentScanner.scan(sessionDir: sessionDir, turnStartedAt: .distantFuture)
        try expect(future.isEmpty, "晚于 turn 起点的应被过滤")
    }

    t.test("tailer：运行中发出快照；不变不重发；子 wire 收尾后补发 completed；未跟踪会话不发") {
        let (root, _, _, subWire) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        // 未跟踪会话：agents/ 齐全但没有 main wire（tailer 不跟踪它）
        let ghostDir = root
            .appendingPathComponent("wd_demo_ea973e2e828f", isDirectory: true)
            .appendingPathComponent("session_ghost", isDirectory: true)
        try appendLines(
            [subPrompt.replacingOccurrences(of: "TS", with: "\(nowMs())")],
            to: ghostDir.appendingPathComponent("agents/agent-0/wire.jsonl"))

        var events: [(TaskEvent, Bool)] = []
        let tailer = KimiWireTailer(
            sessionsRoot: root,
            configTomlURL: root.appendingPathComponent("nope.toml")
        ) { events.append(($0, $1)) }
        tailer.scanOnce()
        let first = subagentEvents(events)
        try expectEqual(first.count, 1)
        try expectEqual(first.first?.count, 1)
        try expectEqual(first.first?.first?.agentId, "agent-0")
        try expectEqual(first.first?.first?.status, .running)

        events.removeAll()
        tailer.scanOnce()
        try expect(subagentEvents(events).isEmpty, "快照不变不应重发: \(events.map(\.0.kind))")

        try appendLines(
            [subStepEnd.replacingOccurrences(of: "TS", with: "\(nowMs())")],
            to: subWire)
        tailer.scanOnce()
        let second = subagentEvents(events)
        try expectEqual(second.count, 1)
        try expectEqual(second.first?.first?.status, .completed)
        try expect(
            events.allSatisfy { $0.0.sessionId != "session_ghost" },
            "未跟踪会话不应发任何事件")
    }
}
