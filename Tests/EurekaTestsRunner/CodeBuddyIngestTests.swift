import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

// CodeBuddy 数据层测试。fixture 按本机真实 ~/.codebuddy 行格式内联构造（路径/id 均为假）。
// 不在 main.swift 注册——由集成方统一接线。

func codeBuddyPathsTests(_ t: TestRunner) {
    t.suite("CodeBuddyPaths")

    t.test("home 优先级：EUREKA_CODEBUDDY_HOME > CODEBUDDY_CONFIG_DIR > 默认；派生根") {
        try expectEqual(
            CodeBuddyPaths.configHome(environment: [
                "EUREKA_CODEBUDDY_HOME": "/tmp/cb-home", "CODEBUDDY_CONFIG_DIR": "/tmp/cli-home",
            ]).path,
            "/tmp/cb-home")
        try expectEqual(
            CodeBuddyPaths.configHome(environment: ["CODEBUDDY_CONFIG_DIR": "/tmp/cli-home"]).path,
            "/tmp/cli-home")
        try expect(CodeBuddyPaths.configHome(environment: [:]).path.hasSuffix("/.codebuddy"))
        try expectEqual(
            CodeBuddyPaths.projectsRoot(environment: ["EUREKA_CODEBUDDY_HOME": "/tmp/cb-home"]).path,
            "/tmp/cb-home/projects")
        try expectEqual(
            CodeBuddyPaths.liveSessionsRoot(environment: ["EUREKA_CODEBUDDY_HOME": "/tmp/cb-home"]).path,
            "/tmp/cb-home/sessions")
        // 官方拼写就是 memery
        try expectEqual(
            CodeBuddyPaths.memoryRoot(environment: ["EUREKA_CODEBUDDY_HOME": "/tmp/cb-home"]).path,
            "/tmp/cb-home/memery")
    }
}

func codeBuddyTranscriptDecoderTests(_ t: TestRunner) {
    t.suite("CodeBuddyTranscriptDecoder")

    func decode(_ line: String) -> TaskEvent? {
        CodeBuddyTranscriptDecoder.decode(line: Data(line.utf8), sessionId: "s1", cwd: "/w")
    }

    t.test("user 消息 → taskStarted（标题摘要）；skipRun 元行 → 忽略") {
        guard case .taskStarted(let title) = decode(
            #"{"id":"u1","timestamp":1784956356582,"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下这个仓库"}],"sessionId":"s1","cwd":"/w"}"#
        )?.kind else {
            throw ExpectationError(description: "user 消息应为 taskStarted")
        }
        try expectEqual(title, "分析一下这个仓库")
        try expect(decode(
            #"{"id":"u0","timestamp":1784956356000,"type":"message","role":"user","content":[{"type":"input_text","text":"<system-reminder>本地命令</system-reminder>"}],"providerData":{"skipRun":true},"sessionId":"s1","cwd":"/w"}"#
        ) == nil, "skipRun 元行不应产出事件")
    }

    t.test("function_call → activity(工具名)；assistant completed → taskFinished(success)") {
        guard case .activity(tool: "Read") = decode(
            #"{"id":"f1","timestamp":1784956360000,"type":"function_call","callId":"call_1","name":"Read","arguments":"{\"file_path\":\"/a\"}","providerData":{"model":"glm-5.2"},"sessionId":"s1","cwd":"/w"}"#
        )?.kind else {
            throw ExpectationError(description: "function_call 应为 activity(Read)")
        }
        guard case .taskFinished(outcome: .success, _, _) = decode(
            #"{"id":"a1","timestamp":1784956365000,"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"好的"}],"providerData":{"model":"glm-5.2","requestModelName":"GLM-5.2"},"sessionId":"s1","cwd":"/w"}"#
        )?.kind else {
            throw ExpectationError(description: "assistant completed 应为 taskFinished(success)")
        }
        // 非 completed 状态（流式中间态）不收尾
        try expect(decode(
            #"{"id":"a2","timestamp":1784956365000,"type":"message","role":"assistant","status":"streaming","content":[],"sessionId":"s1","cwd":"/w"}"#
        ) == nil)
    }

    t.test("ai-title / summary → titleUpdate（只改已有任务标题，不造幻影任务）") {
        guard case .titleUpdate(title: "分析仓库结构") = decode(
            #"{"timestamp":1784975915818,"type":"ai-title","aiTitle":"分析仓库结构","sessionId":"s1","cwd":"/w"}"#
        )?.kind else {
            throw ExpectationError(description: "ai-title 应为 titleUpdate")
        }
        guard case .titleUpdate = decode(
            #"{"timestamp":1784976293013,"type":"summary","summary":"首条用户 prompt","sessionId":"s1","cwd":"/w"}"#
        )?.kind else {
            throw ExpectationError(description: "summary 应为 titleUpdate")
        }
    }

    t.test("防御性：reasoning / function_call_result / file-history-snapshot / 未知 / 非 JSON → 忽略") {
        let ignored = [
            #"{"id":"r1","timestamp":1784956359000,"type":"reasoning","rawContent":"思考中","sessionId":"s1","cwd":"/w"}"#,
            #"{"id":"fr1","timestamp":1784956361000,"type":"function_call_result","name":"Read","callId":"call_1","status":"completed","output":{"type":"text","text":"内容"},"sessionId":"s1","cwd":"/w"}"#,
            #"{"id":"fh1","timestamp":1784956350000,"type":"file-history-snapshot","sessionId":"s1","cwd":"/w"}"#,
            #"{"id":"x1","timestamp":1784956350000,"type":"some-future-type","sessionId":"s1","cwd":"/w"}"#,
        ]
        for line in ignored {
            try expect(decode(line) == nil, "应忽略: \(line)")
        }
        try expect(decode("not json") == nil)
    }

    t.test("旁路提取：usage（camelCase 主格式 + snake_case 兜底）/ toolCall / userText / 时间戳") {
        let camel = try parseCodeBuddyLine(
            #"{"type":"function_call","name":"Bash","arguments":"{}","timestamp":1784975923248,"providerData":{"model":"glm-5.2","usage":{"requests":1,"inputTokens":25709,"outputTokens":422,"totalTokens":26131,"inputTokensDetails":[{"cached_tokens":12800}]}}}"#)
        let usage = CodeBuddyTranscriptDecoder.usage(camel)
        try expectEqual(usage?.model, "glm-5.2")
        try expectEqual(usage?.usage.input, 25709 - 12800)  // camelCase 含缓存读 → 减掉
        try expectEqual(usage?.usage.output, 422)
        try expectEqual(usage?.usage.cacheRead, 12800)

        let snake = try parseCodeBuddyLine(
            #"{"type":"function_call","name":"Bash","arguments":"{}","timestamp":1784975923248,"providerData":{"model":"glm-5.2","usage":{"input_tokens":1000,"output_tokens":50,"total_tokens":1050,"cache_read_input_tokens":200}}}"#)
        let snakeUsage = CodeBuddyTranscriptDecoder.usage(snake)
        try expectEqual(snakeUsage?.usage.input, 1000)  // snake_case 不含缓存 → 原样
        try expectEqual(snakeUsage?.usage.cacheRead, 200)

        let call = try parseCodeBuddyLine(
            #"{"type":"function_call","name":"Skill","arguments":"{\"skill\":\"tdd\"}","timestamp":1}"#)
        let toolCall = CodeBuddyTranscriptDecoder.toolCall(call)
        try expectEqual(toolCall?.name, "Skill")
        try expectEqual(toolCall?.args["skill"] as? String, "tdd")

        let user = try parseCodeBuddyLine(
            #"{"type":"message","role":"user","content":[{"type":"input_text","text":"第一段"},{"type":"input_text","text":"第二段"}],"timestamp":1784956356582}"#)
        try expectEqual(CodeBuddyTranscriptDecoder.userText(user), "第一段\n第二段")
        try expectEqual(
            CodeBuddyTranscriptDecoder.timestamp(user),
            Date(timeIntervalSince1970: 1784956356.582))
    }
}

private func parseCodeBuddyLine(_ json: String) throws -> [String: Any] {
    guard let root = (try? JSONSerialization.jsonObject(
        with: Data(json.utf8))) as? [String: Any] else {
        throw ExpectationError(description: "fixture 非法 JSON: \(json)")
    }
    return root
}

/// 在临时目录搭一个 codebuddy 会话树：<home>/projects/<slug>/<sessionId>.jsonl
private func makeCodeBuddySession(
    slug: String = "-work-demo",
    sessionId: String = "a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"
) throws -> (home: URL, sessionFile: URL) {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-codebuddy-\(UUID().uuidString)", isDirectory: true)
    let projectDir = home.appendingPathComponent("projects/\(slug)", isDirectory: true)
    try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
    return (home, projectDir.appendingPathComponent("\(sessionId).jsonl"))
}

private func appendCodeBuddyLines(_ lines: [String], to url: URL) throws {
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

/// 以"现在"为基准的 codebuddy 行（epoch ms），避免 stale 误判
private func codeBuddyNowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

func codeBuddyChatTailerTests(_ t: TestRunner) {
    t.suite("CodeBuddyChatTailer")

    t.test("初见只恢复尾部状态（不重放）；增量产出 started/activity/finished/titleUpdate") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let now = codeBuddyNowMs()
        let userLine = #"{"id":"u1","timestamp":\#(now - 4000),"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下这个仓库"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#
        let assistantLine = #"{"id":"a1","timestamp":\#(now - 3000),"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"好的"}],"providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#
        try appendCodeBuddyLines([userLine, assistantLine], to: session.sessionFile)

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodeBuddyChatTailer(
            projectsRoot: session.home.appendingPathComponent("projects")
        ) { events.append(($0, $1)) }
        tailer.scanOnce()  // 初见：已完成的会话只恢复 sessionStarted + 标题
        let initialKinds = events.map(\.0.kind)
        try expect(initialKinds.contains(.sessionStarted),
                   "已完成会话初见应恢复 sessionStarted: \(initialKinds)")
        try expect(!initialKinds.contains { if case .taskFinished = $0 { return true } else { return false } },
                   "初见不应重放 taskFinished: \(initialKinds)")

        // 增量：新一轮 user → function_call → assistant → ai-title
        events.removeAll()
        try appendCodeBuddyLines([
            #"{"id":"u2","timestamp":\#(now - 2000),"type":"message","role":"user","content":[{"type":"input_text","text":"再看看测试"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"f1","timestamp":\#(now - 1000),"type":"function_call","callId":"call_1","name":"Grep","arguments":"{\"pattern\":\"test\"}","providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"a2","timestamp":\#(now),"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"看完了"}],"providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"t1","timestamp":\#(now),"type":"ai-title","aiTitle":"分析仓库结构","sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: session.sessionFile)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        try expect(kinds.contains { if case .taskStarted = $0 { return true } else { return false } },
                   "新一轮应为 taskStarted: \(kinds)")
        try expect(kinds.contains(.activity(tool: "Grep")),
                   "function_call 应为 activity(Grep): \(kinds)")
        try expect(kinds.contains {
            if case .taskFinished(outcome: .success, _, _) = $0 { return true } else { return false }
        }, "assistant completed 应为 taskFinished(success): \(kinds)")
        try expect(kinds.contains(.titleUpdate(title: "分析仓库结构")),
                   "ai-title 应为 titleUpdate: \(kinds)")
        try expectEqual(events.first?.0.sessionId, "a0cd6d00-5b4c-4d09-bb14-b80de59f6c26")
        try expectEqual(events.first?.0.cwd, "/work/demo")
        try expect(events.allSatisfy { !$0.1 }, "新事件不应判 stale")
    }

    t.test("旧时间戳事件判 stale；半行不消费，补全后产出") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let now = codeBuddyNowMs()
        let userLine = #"{"id":"u1","timestamp":\#(now),"type":"message","role":"user","content":[{"type":"input_text","text":"你好"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#
        try appendCodeBuddyLines([userLine], to: session.sessionFile)

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodeBuddyChatTailer(
            projectsRoot: session.home.appendingPathComponent("projects")
        ) { events.append(($0, $1)) }
        tailer.scanOnce()  // 初见定基线
        events.removeAll()

        // 旧时间戳（1 小时前）→ stale
        let staleLine = #"{"id":"f0","timestamp":\#(now - 3_600_000),"type":"function_call","callId":"call_0","name":"Read","arguments":"{}","sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#
        try appendCodeBuddyLines([staleLine], to: session.sessionFile)
        tailer.scanOnce()
        try expect(events.count == 1 && events[0].1, "1 小时前的事件应判 stale: \(events)")
        events.removeAll()

        // 半行不消费
        let finishLine = #"{"id":"a1","timestamp":\#(now),"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"完"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#
        let handle = try FileHandle(forWritingTo: session.sessionFile)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(finishLine.prefix(finishLine.count / 2)).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出: \(events.map(\.0.kind))")

        let handle2 = try FileHandle(forWritingTo: session.sessionFile)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data(
            (String(finishLine.suffix(finishLine.count - finishLine.count / 2)) + "\n").utf8))
        try handle2.close()
        tailer.scanOnce()
        try expect(events.contains {
            if case .taskFinished = $0.0.kind { return true } else { return false }
        }, "补全后应产出完成")
    }
}

func codeBuddySessionIndexerTests(_ t: TestRunner) {
    t.suite("CodeBuddySessionIndexer")

    t.test("索引：id=文件名 stem；标题 ai-title > summary > 首条 user 文本；cwd/时间") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try appendCodeBuddyLines([
            #"{"id":"u0","timestamp":1784956350000,"type":"message","role":"user","content":[{"type":"input_text","text":"<本地命令回显>"}],"providerData":{"skipRun":true},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"u1","timestamp":1784956356582,"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下这个仓库"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"s1","timestamp":1784976293013,"type":"summary","summary":"首条用户 prompt","sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"t1","timestamp":1784976315818,"type":"ai-title","aiTitle":"分析仓库结构","sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: session.sessionFile)

        let sessions = CodeBuddySessionIndexer.index(
            projectsRoot: session.home.appendingPathComponent("projects"))
        try expectEqual(sessions.count, 1)
        let info = sessions[0]
        try expectEqual(info.source, .codebuddy)
        try expectEqual(info.id, "a0cd6d00-5b4c-4d09-bb14-b80de59f6c26")
        try expectEqual(info.name, "分析仓库结构")  // ai-title 优先
        try expectEqual(info.cwd, "/work/demo")
        try expectEqual(info.startedAt, Date(timeIntervalSince1970: 1784956350.0))
        try expect(info.lastActiveAt >= Date(timeIntervalSince1970: 1784976315.818),
                   "lastActiveAt 应取末行时间戳")

        // 无 ai-title 时回退 summary
        let fallback = try makeCodeBuddySession(
            sessionId: "b1cd6d00-5b4c-4d09-bb14-b80de59f6c26")
        defer { try? FileManager.default.removeItem(at: fallback.home) }
        try appendCodeBuddyLines([
            #"{"id":"u1","timestamp":1784956356582,"type":"message","role":"user","content":[{"type":"input_text","text":"修个 bug"}],"sessionId":"b1cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"s1","timestamp":1784976293013,"type":"summary","summary":"修个 bug","sessionId":"b1cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: fallback.sessionFile)
        let fallbackSessions = CodeBuddySessionIndexer.index(
            projectsRoot: fallback.home.appendingPathComponent("projects"))
        try expectEqual(fallbackSessions.first?.name, "修个 bug")
    }

    t.test("只有 skipRun 元行的空会话不进列表") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try appendCodeBuddyLines([
            #"{"id":"u0","timestamp":1784956350000,"type":"message","role":"user","content":[{"type":"input_text","text":"<本地命令回显>"}],"providerData":{"skipRun":true},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: session.sessionFile)
        try expect(CodeBuddySessionIndexer.index(
            projectsRoot: session.home.appendingPathComponent("projects")).isEmpty)
    }
}

func codeBuddyUsageScannerTests(_ t: TestRunner) {
    t.suite("CodeBuddyUsageScanner")

    t.test("function_call → 用量行 + tool_calls 归类；user → 提问数；重扫幂等") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try appendCodeBuddyLines([
            #"{"id":"u0","timestamp":1784956350000,"type":"message","role":"user","content":[{"type":"input_text","text":"<本地命令回显>"}],"providerData":{"skipRun":true},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"u1","timestamp":1784956356582,"type":"message","role":"user","content":[{"type":"input_text","text":"分析一下这个仓库"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"f1","timestamp":1784975923248,"type":"function_call","callId":"call_1","name":"Skill","arguments":"{\"skill\":\"tdd\"}","providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"f2","timestamp":1784975923249,"type":"function_call","callId":"call_2","name":"mcp__ctx7__query-docs","arguments":"{}","providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"f3","timestamp":1784975923250,"type":"function_call","callId":"call_3","name":"Agent","arguments":"{\"subagent_type\":\"reviewer\"}","providerData":{"model":"glm-5.2"},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"f4","timestamp":1784975923251,"type":"function_call","callId":"call_4","name":"Bash","arguments":"{\"command\":\"ls\"}","providerData":{"model":"glm-5.2","usage":{"requests":1,"inputTokens":25709,"outputTokens":422,"totalTokens":26131,"inputTokensDetails":[{"cached_tokens":12800}]}},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
            #"{"id":"fr4","timestamp":1784975923252,"type":"function_call_result","name":"Bash","callId":"call_4","status":"completed","output":{"type":"text","text":"..."},"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: session.sessionFile)

        let store = try EurekaStore(
            path: session.home.appendingPathComponent("eureka.sqlite"))
        let scanner = CodeBuddyUsageScanner(
            projectsRoot: session.home.appendingPathComponent("projects"), store: store)
        try expectEqual(try scanner.scanOnce(), 1)

        // 用量行：camelCase 口径 input = inputTokens − cached；model 原样
        let rows = (try store.usage.totalsForSessions(
            ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]))["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? []
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].model, "glm-5.2")
        try expectEqual(rows[0].inputTokens, 25709 - 12800)
        try expectEqual(rows[0].outputTokens, 422)
        try expectEqual(rows[0].cacheReadTokens, 12800)
        try expectEqual(rows[0].cacheCreationTokens, 0)

        // tool_calls kind 归类（skill 名取 arguments.skill；mcp 去前缀；agent 取 subagent_type）
        let totals = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0),
            to: Date(timeIntervalSince1970: 4_000_000_000), source: .codebuddy)
        func entry(_ kind: String) -> (name: String, count: Int)? {
            totals.first { $0.kind == kind }.map { ($0.name, $0.count) }
        }
        try expectEqual(entry("skill")?.name, "tdd")
        try expectEqual(entry("mcp")?.name, "ctx7.query-docs")
        try expectEqual(entry("agent")?.name, "reviewer")
        try expectEqual(entry("tool")?.name, "Bash")

        // 提问数：skipRun 不计，真实 user 计 1
        try expectEqual(
            try store.sessionStats.promptCounts(
                for: ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]
            )["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? 0, 1)

        // 重扫幂等：水位已过，不翻倍
        try expectEqual(try scanner.scanOnce(), 0)
        let rows2 = (try store.usage.totalsForSessions(
            ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]))["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? []
        try expectEqual(rows2.count, 1)
        try expectEqual(rows2[0].requestCount, 1)
        try expectEqual(
            try store.sessionStats.promptCounts(
                for: ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]
            )["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? 0, 1)
    }

    t.test("子代理 jsonl：token 归父会话，提问不计") {
        let session = try makeCodeBuddySession()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try appendCodeBuddyLines([
            #"{"id":"u1","timestamp":1784956356582,"type":"message","role":"user","content":[{"type":"input_text","text":"主会话提问"}],"sessionId":"a0cd6d00-5b4c-4d09-bb14-b80de59f6c26","cwd":"/work/demo"}"#,
        ], to: session.sessionFile)
        let subagentsDir = session.home.appendingPathComponent(
            "projects/-work-demo/a0cd6d00-5b4c-4d09-bb14-b80de59f6c26/subagents",
            isDirectory: true)
        try FileManager.default.createDirectory(
            at: subagentsDir, withIntermediateDirectories: true)
        try appendCodeBuddyLines([
            #"{"id":"u1","timestamp":1784956357000,"type":"message","role":"user","content":[{"type":"input_text","text":"子任务提示"}],"sessionId":"agent-1","cwd":"/work/demo"}"#,
            #"{"id":"f1","timestamp":1784975924000,"type":"function_call","callId":"call_9","name":"Read","arguments":"{}","providerData":{"model":"glm-5.2","usage":{"requests":1,"inputTokens":1000,"outputTokens":50,"totalTokens":1050,"inputTokensDetails":[{"cached_tokens":0}]}},"sessionId":"agent-1","cwd":"/work/demo"}"#,
        ], to: subagentsDir.appendingPathComponent("agent-1.jsonl"))

        let store = try EurekaStore(
            path: session.home.appendingPathComponent("eureka.sqlite"))
        let scanner = CodeBuddyUsageScanner(
            projectsRoot: session.home.appendingPathComponent("projects"), store: store)
        try expectEqual(try scanner.scanOnce(), 1)
        // 子代理 usage 归父会话 id
        let rows = (try store.usage.totalsForSessions(
            ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]))["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? []
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].inputTokens, 1000)
        // 子代理的 user 消息不计提问；主会话 1 次
        try expectEqual(
            try store.sessionStats.promptCounts(
                for: ["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"]
            )["a0cd6d00-5b4c-4d09-bb14-b80de59f6c26"] ?? 0, 1)
    }
}
