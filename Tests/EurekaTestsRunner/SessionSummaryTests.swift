import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSummary
import Foundation

// Behavioural tests for AI session summaries (issue #12), driven through the coordinator /
// invoker boundary with a scripted fake process. No real CLI is launched here.

/// Scripted stand-in for a CLI process. Each launch asks `script` what to do with the spec.
final class FakeSummaryLauncher: SummaryProcessLaunching {
    enum Script {
        /// Deliver these stdout chunks (and stderr), then exit with `status`
        case output([Data], status: Int32, stderr: Data = Data())
        /// Deliver `partial`, then never exit until terminated (exits as SIGTERM)
        case hang(partial: [Data])
    }

    final class Handle: SummaryProcessHandle {
        var onTerminate: (() -> Void)?
        private(set) var terminated = false
        func terminate() {
            guard !terminated else { return }
            terminated = true
            onTerminate?()
        }
    }

    private let lock = NSLock()
    private let script: (SummaryProcessSpec) -> Script
    private(set) var specs: [SummaryProcessSpec] = []
    private(set) var handles: [Handle] = []
    private var running = 0
    private(set) var maxConcurrent = 0

    init(script: @escaping (SummaryProcessSpec) -> Script) {
        self.script = script
    }

    var prompts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return specs.map { String(decoding: $0.stdin, as: UTF8.self) }
    }

    func launch(
        _ spec: SummaryProcessSpec, onStdout: @escaping (Data) -> Void,
        onStderr: @escaping (Data) -> Void, onExit: @escaping (SummaryProcessExit) -> Void
    ) throws -> SummaryProcessHandle {
        let handle = Handle()
        lock.lock()
        specs.append(spec)
        handles.append(handle)
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        lock.unlock()
        let queue = DispatchQueue(label: "fake-process")
        let finish: (SummaryProcessExit) -> Void = { [weak self] exit in
            self?.lock.lock()
            self?.running -= 1
            self?.lock.unlock()
            onExit(exit)
        }
        switch script(spec) {
        case .output(let chunks, let status, let stderr):
            queue.async {
                chunks.forEach(onStdout)
                if !stderr.isEmpty { onStderr(stderr) }
                finish(SummaryProcessExit(status: status, signaled: false))
            }
        case .hang(let partial):
            queue.async { partial.forEach(onStdout) }
            handle.onTerminate = {
                queue.async { finish(SummaryProcessExit(status: 15, signaled: true)) }
            }
        }
        return handle
    }
}

/// Splits bytes into pieces of the given sizes (cycled), cutting through UTF-8 sequences and
/// JSON objects alike
func splitBytes(_ data: Data, sizes: [Int]) -> [Data] {
    var pieces: [Data] = []
    var index = data.startIndex
    var step = 0
    while index < data.endIndex {
        let size = sizes[step % sizes.count]
        let end = data.index(index, offsetBy: size, limitedBy: data.endIndex) ?? data.endIndex
        pieces.append(Data(data[index..<end]))
        index = end
        step += 1
    }
    return pieces
}

func claudeStream(_ text: String, trailingNewline: Bool = true) -> Data {
    func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!
    }
    let half = text.index(text.startIndex, offsetBy: text.count / 2)
    let lines = [
        json(["type": "system", "subtype": "init", "session_id": "s-1", "model": "claude-test"]),
        json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
              "delta": ["type": "text_delta", "text": String(text[..<half])]]]),
        json(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
              "delta": ["type": "text_delta", "text": String(text[half...])]]]),
        json(["type": "assistant", "message": ["model": "claude-test",
              "content": [["type": "text", "text": text]]]]),
        json(["type": "result", "subtype": "success", "is_error": false, "result": text,
              "usage": ["input_tokens": 10, "cache_creation_input_tokens": 5,
                        "cache_read_input_tokens": 1, "output_tokens": 7]]),
    ]
    return Data((lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")).utf8)
}

let summaryTestExecutor = ResolvedExecutor(
    kind: .claude, path: "/usr/bin/true", version: "9.9.9", environment: [:])

func summaryTestHeader() -> SummaryTemplate.SessionHeader {
    SummaryTemplate.SessionHeader(
        title: "测试会话", sourceName: "Claude Code", project: nil, startedAt: nil,
        lastActiveAt: nil)
}

func summaryTestSnapshot(turns: Int = 2, bodyRepeat: Int = 1) -> SummarySnapshot {
    var messages: [SummarySnapshot.Message] = []
    for turn in 0..<turns {
        let base = turn * 3
        messages.append(.init(id: base, role: .user, text: "需求 \(turn)：" + String(repeating: "实现增量加载。", count: bodyRepeat)))
        messages.append(.init(id: base + 1, role: .assistant, text: "方案 \(turn)：" + String(repeating: "use a watermark. ", count: bodyRepeat)))
        messages.append(.init(id: base + 2, role: .tools, text: "command Bash: swift test"))
    }
    return SummarySnapshot(messages: messages, compactedToolSteps: turns)
}

/// Coordinator over a fresh temp database, plus a way to wait for finished runs
final class SummaryHarness {
    let store: EurekaStore
    let launcher: FakeSummaryLauncher
    let coordinator: SessionSummaryCoordinator
    private let lock = NSLock()
    private(set) var finished: [SummaryRunRecord] = []
    private(set) var lives: [SummaryLiveState] = []
    private let finishedSignal = DispatchSemaphore(value: 0)

    init(
        dbPath: URL? = nil, budget: Int = SummaryChunker.defaultBudget, timeout: TimeInterval = 30,
        snapshot: @escaping SessionSummaryCoordinator.SnapshotLoader = { _ in .snapshot(summaryTestSnapshot()) },
        script: @escaping (SummaryProcessSpec) -> FakeSummaryLauncher.Script
    ) throws {
        let path = dbPath ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-test-\(UUID().uuidString).sqlite")
        store = try EurekaStore(path: path)
        launcher = FakeSummaryLauncher(script: script)
        var configuration = SessionSummaryCoordinator.Configuration()
        configuration.budget = budget
        configuration.invocationTimeout = timeout
        configuration.textThrottle = 0
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-ws-\(UUID().uuidString)", isDirectory: true)
        var finishedRef: ((SummaryRunRecord) -> Void)?
        var liveRef: ((SummaryLiveState) -> Void)?
        coordinator = SessionSummaryCoordinator(
            store: store, launcher: launcher,
            executors: { kind in
                (SummaryExecutorAvailability(kind: kind, executor: summaryTestExecutor, reason: nil),
                 SummaryAdapters.adapter(for: kind))
            },
            loadSnapshot: snapshot, workspaceRoot: workspace, configuration: configuration,
            onUpdate: { update in
                switch update {
                case .finished(let record): finishedRef?(record)
                case .live(let live): liveRef?(live)
                }
            })
        finishedRef = { [weak self] record in
            guard let self else { return }
            self.lock.lock()
            self.finished.append(record)
            self.lock.unlock()
            self.finishedSignal.signal()
        }
        liveRef = { [weak self] live in
            self?.lock.lock()
            self?.lives.append(live)
            self?.lock.unlock()
        }
    }

    func waitFinished(count: Int = 1, timeout: TimeInterval = 10) throws -> [SummaryRunRecord] {
        for _ in 0..<count {
            guard finishedSignal.wait(timeout: .now() + timeout) == .success else {
                throw ExpectationError(description: "总结任务未在 \(timeout)s 内结束")
            }
        }
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    var liveStates: [SummaryLiveState] {
        lock.lock()
        defer { lock.unlock() }
        return lives
    }
}

func summaryTestRequest(id: String = "sess-1", source: AgentSource = .claude) -> SessionSummaryCoordinator.Request {
    SessionSummaryCoordinator.Request(
        session: AgentSessionInfo(
            source: source, id: id, cwd: "/tmp/project", name: "测试", lastActiveAt: Date(),
            sizeBytes: 0, transcriptPath: "/tmp/none.jsonl"),
        header: summaryTestHeader(), executor: .claude, model: nil, language: .english)
}

func sessionSummaryTests(_ t: TestRunner) {
    t.suite("SessionSummary")

    t.test("流式 JSONL 任意切分（含 UTF-8 中断）与无换行尾行都能得到完整结果") {
        let text = "## Overview\n会话总结：完成增量加载 [#0]"
        for sizes in [[1], [2, 3], [7], [5, 1, 9]] {
            let launcher = FakeSummaryLauncher { _ in
                .output(splitBytes(claudeStream(text, trailingNewline: false), sizes: sizes), status: 0)
            }
            var deltas = 0
            let result = SummaryInvoker(launcher: launcher, timeout: 10).run(
                prompt: "p", adapter: ClaudeSummaryAdapter(), executor: summaryTestExecutor,
                workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()
            ) { event in
                if case .delta = event { deltas += 1 }
            }
            try expectEqual(result.outcome, .success(text: text), "切分 \(sizes)")
            try expectEqual(result.model, "claude-test")
            try expectEqual(result.inputTokens, 16)
            try expectEqual(deltas, 2)
        }
    }

    t.test("Claude result is_error / 未登录 → authentication；非零退出 → nonzeroExit") {
        let line = #"{"type":"result","subtype":"success","is_error":true,"result":"Not logged in · Please run /login"}"# + "\n"
        let auth = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in .output([Data(line.utf8)], status: 1) }, timeout: 10
        ).run(prompt: "p", adapter: ClaudeSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        guard case .failure(.authentication, _) = auth.outcome else {
            throw ExpectationError(description: "应识别为鉴权失败: \(auth.outcome)")
        }
        let crash = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in
                .output([], status: 2, stderr: Data("boom\nAuthorization: Bearer abcdefghijklmnop\n".utf8))
            }, timeout: 10
        ).run(prompt: "p", adapter: ClaudeSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        guard case .failure(.nonzeroExit, let message) = crash.outcome else {
            throw ExpectationError(description: "应为非零退出: \(crash.outcome)")
        }
        try expect(message?.contains("abcdefghijklmnop") == false, "诊断信息必须脱敏")
        try expect(message?.contains("exit code 2") == true)
    }

    t.test("Codex：agent_message + turn.completed 成功；turn.failed 解出内层错误") {
        let ok = """
            {"type":"thread.started","thread_id":"t1"}
            {"type":"turn.started"}
            {"type":"item.completed","item":{"id":"i0","type":"error","message":"warning only"}}
            {"type":"item.completed","item":{"id":"i1","type":"agent_message","text":"## Overview\\nDone"}}
            {"type":"turn.completed","usage":{"input_tokens":100,"output_tokens":5,"reasoning_output_tokens":2}}

            """
        let success = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in .output(splitBytes(Data(ok.utf8), sizes: [13]), status: 0) },
            timeout: 10
        ).run(prompt: "p", adapter: CodexSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        try expectEqual(success.outcome, .success(text: "## Overview\nDone"))
        try expectEqual(success.outputTokens, 7)

        let failed = #"{"type":"turn.failed","error":{"message":"{\"type\":\"error\",\"status\":400,\"error\":{\"message\":\"model not supported\"}}"}}"# + "\n"
        let failure = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in .output([Data(failed.utf8)], status: 1) }, timeout: 10
        ).run(prompt: "p", adapter: CodexSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        try expectEqual(failure.outcome, .failure(kind: .executorError, message: "model not supported"))
    }

    t.test("OpenCode：error 事件 → executorError；空文本 → emptyOutput") {
        let error = #"{"type":"error","error":{"name":"UnknownError","data":{"message":"Model not found: x/y"}}}"# + "\n"
        let failure = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in .output([Data(error.utf8)], status: 1) }, timeout: 10
        ).run(prompt: "p", adapter: OpencodeSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        try expectEqual(failure.outcome, .failure(kind: .executorError, message: "Model not found: x/y"))
        let empty = #"{"type":"step_start","sessionID":"ses_1"}"# + "\n"
            + #"{"type":"text","part":{"id":"p1","text":"   "}}"# + "\n"
            + #"{"type":"step_finish","part":{"reason":"stop","tokens":{"input":3,"output":1}}}"# + "\n"
        let blank = SummaryInvoker(
            launcher: FakeSummaryLauncher { _ in .output([Data(empty.utf8)], status: 0) }, timeout: 10
        ).run(prompt: "p", adapter: OpencodeSummaryAdapter(), executor: summaryTestExecutor,
              workingDirectory: "/tmp", model: nil, cancel: SummaryCancelToken()) { _ in }
        try expectEqual(blank.outcome, .failure(kind: .emptyOutput, message: nil))
    }

    t.test("分段：按轮切分，全部消息恰好覆盖一次，超大消息拆成连续分片") {
        var messages = summaryTestSnapshot(turns: 6, bodyRepeat: 40).messages
        messages.append(.init(id: 99, role: .assistant, text: String(repeating: "超长输出。", count: 2000)))
        let plan = SummaryChunker.plan(messages, budget: 1500)
        try expect(plan.chunks.count > 2, "应切成多段")
        try expectEqual(plan.splitMessages, 1)
        for chunk in plan.chunks {
            try expect(chunk.estimatedTokens <= 1500, "每段不超预算: \(chunk.estimatedTokens)")
        }
        // Every original id appears, in order; only the split message repeats
        let ids = plan.chunks.flatMap { $0.messages.map(\.id) }
        var deduped: [Int] = []
        for id in ids where deduped.last != id { deduped.append(id) }
        try expectEqual(deduped, messages.map(\.id))
        let pieces = plan.chunks.flatMap(\.messages).filter { $0.id == 99 }
        try expect(pieces.count > 1)
        try expect(pieces[0].text.hasPrefix("(part 1/\(pieces.count))"))
        // Turn-aware: apart from the split oversized message, every chunk starts a turn
        for chunk in plan.chunks.dropFirst() where chunk.messages[0].id != 99 {
            try expectEqual(chunk.messages[0].role, .user)
        }
    }

    t.test("快照：思考排除、工具轨迹压缩、工具注记合并，id 与对话一致") {
        let messages = [
            TranscriptMessage(id: 0, role: .user, text: "修复构建"),
            TranscriptMessage(id: 1, role: .thinking, text: "secret thoughts"),
            TranscriptMessage(id: 2, role: .turnTrail, text: "", steps: [
                ToolStep(kind: .command, name: "Bash", detail: "swift build", isError: true),
                ToolStep(kind: .command, name: "Bash", detail: "swift build"),
                ToolStep(kind: .read, name: "Read", detail: "Package.swift"),
            ]),
            TranscriptMessage(id: 3, role: .assistant, text: "已修复"),
            TranscriptMessage(id: 4, role: .toolNote, text: "🔧 read"),
            TranscriptMessage(id: 5, role: .toolNote, text: "🔧 read"),
        ]
        let snapshot = ConversationSnapshotBuilder.build(from: messages)
        try expectEqual(snapshot.messages.map(\.id), [0, 2, 3, 4])
        try expectEqual(snapshot.excludedThinking, 1)
        try expectEqual(snapshot.compactedToolSteps, 5)
        try expectEqual(snapshot.messages[1].text, "command Bash ×2 (1 failed): swift build\nread Read: Package.swift")
        try expectEqual(snapshot.messages[3].text, "🔧 read ×2")
        try expect(!snapshot.messages.contains { $0.text.contains("secret") }, "思考内容不得进入快照")
    }

    t.test("真实 Claude transcript 经快照读取：未截断，id 与 TranscriptReader 一致") {
        let path = try fixtureURL("claude-transcript-running.jsonl").path
        let session = AgentSessionInfo(
            source: .claude, id: "fixture", cwd: nil, name: nil, lastActiveAt: Date(),
            sizeBytes: 0, transcriptPath: path)
        guard case .snapshot(let snapshot) = ConversationSnapshotBuilder.load(session: session) else {
            throw ExpectationError(description: "应读到快照")
        }
        let reader = TranscriptReader.load(session: session)
        try expectEqual(snapshot.messages.map(\.id), reader.messages.map(\.id))
        let trae = AgentSessionInfo(
            source: .trae, id: "t", cwd: nil, name: nil, lastActiveAt: Date(), sizeBytes: 0,
            transcriptPath: path)
        guard case .unsupported = ConversationSnapshotBuilder.load(session: trae) else {
            throw ExpectationError(description: "Trae 应不可总结")
        }
        let missing = AgentSessionInfo(
            source: .claude, id: "m", cwd: nil, name: nil, lastActiveAt: Date(), sizeBytes: 0,
            transcriptPath: "/nonexistent/x.jsonl")
        guard case .readFailed = ConversationSnapshotBuilder.load(session: missing) else {
            throw ExpectationError(description: "缺失文件应为读取失败")
        }
    }

    t.test("引用校验：只保留快照内的消息编号") {
        let check = SummaryReferences.validate("A [#0] B [#7] C [#99]", validIds: [0, 7])
        try expectEqual(check.markdown, "A [#0] B [#7] C ")
        try expectEqual(check.valid, 2)
        try expectEqual(check.dropped, 1)
        try expectEqual(SummaryReferences.linkify("see [#7]", scheme: "x"), "see [#7](x://7)")
    }

    t.test("指纹只取决于本会话内容：语言切换不变，新增消息即变化") {
        let snapshot = summaryTestSnapshot()
        let before = snapshot.fingerprint
        let language = L10n.current
        L10n.current = .simplifiedChinese
        try expectEqual(snapshot.fingerprint, before)
        L10n.current = language
        var grown = snapshot
        grown.messages.append(.init(id: 50, role: .user, text: "继续"))
        try expect(grown.fingerprint != before)
    }

    t.test("协调器：单次成功落库（覆盖、指纹、用量），重复请求复用同一任务") {
        let gate = DispatchSemaphore(value: 0)
        let harness = try SummaryHarness { _ in
            gate.wait()
            return .output([claudeStream("## Overview\nOK [#0] [#42]")], status: 0)
        }
        let first = harness.coordinator.request(summaryTestRequest())
        let second = harness.coordinator.request(summaryTestRequest())
        guard case .started(let runId) = first else { throw ExpectationError(description: "\(first)") }
        try expectEqual(second, .alreadyActive(runId: runId))
        gate.signal()
        let records = try harness.waitFinished()
        let record = records[0]
        try expectEqual(record.status, .completed)
        try expectEqual(record.markdown, "## Overview\nOK [#0]")
        try expectEqual(record.coverage.validReferences, 1)
        try expectEqual(record.coverage.droppedReferences, 1)
        try expectEqual(record.coverage.totalMessages, 6)
        try expectEqual(record.fingerprint, summaryTestSnapshot().fingerprint)
        try expectEqual(record.executorVersion, "9.9.9")
        try expectEqual(record.model, "claude-test")
        try expectEqual(record.outputTokens, 7)
        try expectEqual(harness.launcher.specs.count, 1)
        try expect(harness.coordinator.liveState(sessionKey: record.sessionKey) == nil)
        let stored = harness.coordinator.latestCompleted(source: .claude, sessionId: "sess-1")
        try expectEqual(stored?.id, runId)
        try expect(harness.liveStates.contains { $0.stage == .summarizing })
    }

    t.test("协调器：重新生成失败时保留上一次成功结果，失败行留草稿与错误") {
        var call = 0
        let harness = try SummaryHarness { _ in
            call += 1
            if call == 1 { return .output([claudeStream("## Overview\nFirst")], status: 0) }
            let partial = ###"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"## Overview\nhalf"}}}"###
            return .output([Data((partial + "\n").utf8)], status: 1, stderr: Data("network down\n".utf8))
        }
        _ = harness.coordinator.request(summaryTestRequest())
        _ = try harness.waitFinished()
        _ = harness.coordinator.request(summaryTestRequest())
        let records = try harness.waitFinished(count: 1)
        let failed = records[1]
        try expectEqual(failed.status, .failed)
        try expectEqual(failed.errorKind, .nonzeroExit)
        try expectEqual(failed.draft, "## Overview\nhalf")
        try expectEqual(harness.coordinator.latestCompleted(source: .claude, sessionId: "sess-1")?.markdown, "## Overview\nFirst")
        try expectEqual(harness.coordinator.history(source: .claude, sessionId: "sess-1").count, 2)
        let status = harness.coordinator.statusBySession()["claude:sess-1"]
        try expectEqual(status?.latest, .failed)
        try expectEqual(status?.hasCompleted, true)
    }

    t.test("协调器：超时与取消都会终止进程，取消保留已流出的草稿") {
        let partial = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"draft so far"}}}"# + "\n"
        let harness = try SummaryHarness(timeout: 0.3) { _ in .hang(partial: [Data(partial.utf8)]) }
        _ = harness.coordinator.request(summaryTestRequest(id: "slow"))
        let timedOut = try harness.waitFinished()[0]
        try expectEqual(timedOut.status, .failed)
        try expectEqual(timedOut.errorKind, .timeout)
        try expect(harness.launcher.handles[0].terminated, "超时必须终止进程")

        let cancelHarness = try SummaryHarness { _ in .hang(partial: [Data(partial.utf8)]) }
        _ = cancelHarness.coordinator.request(summaryTestRequest(id: "cancel-me"))
        let deadline = Date().addingTimeInterval(5)
        while cancelHarness.liveStates.last?.streamedText != "draft so far", Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        try expect(cancelHarness.coordinator.cancel(sessionKey: "claude:cancel-me"))
        let cancelled = try cancelHarness.waitFinished()[0]
        try expectEqual(cancelled.status, .cancelled)
        try expectEqual(cancelled.draft, "draft so far")
        try expect(cancelHarness.launcher.handles[0].terminated)
    }

    t.test("协调器：长会话分段 + 合并，进度报告 k/n，提示词覆盖全部消息") {
        let snapshot = summaryTestSnapshot(turns: 8, bodyRepeat: 30)
        let harness = try SummaryHarness(budget: 900, snapshot: { _ in .snapshot(snapshot) }) { spec in
            let prompt = String(decoding: spec.stdin, as: UTF8.self)
            if prompt.hasPrefix("Below are notes") {
                return .output([claudeStream("## Overview\nMerged [#0] [#21]")], status: 0)
            }
            return .output([claudeStream("notes")], status: 0)
        }
        _ = harness.coordinator.request(summaryTestRequest())
        let record = try harness.waitFinished()[0]
        try expectEqual(record.status, .completed)
        try expectEqual(record.markdown, "## Overview\nMerged [#0] [#21]")
        let chunkPrompts = harness.launcher.prompts.filter { $0.hasPrefix("You are reading part") }
        try expectEqual(chunkPrompts.count, record.coverage.chunkCount)
        try expect(record.coverage.chunkCount > 1)
        for message in snapshot.messages {
            try expect(chunkPrompts.contains { $0.contains("[#\(message.id)] ") }, "消息 #\(message.id) 未进入任何分段")
        }
        try expect(harness.liveStates.contains { $0.stage == .merging })
        try expect(harness.liveStates.contains { $0.chunkTotal == record.coverage.chunkCount && $0.chunksDone == 1 })
    }

    t.test("协调器：全局只并发一个任务；不可读与不支持的会话给出明确原因") {
        let harness = try SummaryHarness(snapshot: { session in
            session.id == "empty" ? .empty : .snapshot(summaryTestSnapshot())
        }) { _ in
            Thread.sleep(forTimeInterval: 0.05)
            return .output([claudeStream("## Overview\nok")], status: 0)
        }
        _ = harness.coordinator.request(summaryTestRequest(id: "a"))
        _ = harness.coordinator.request(summaryTestRequest(id: "b"))
        _ = harness.coordinator.request(summaryTestRequest(id: "empty"))
        let records = try harness.waitFinished(count: 3)
        try expectEqual(harness.launcher.maxConcurrent, 1)
        try expectEqual(records.first { $0.sessionId == "empty" }?.errorKind, .emptyConversation)
        let rejected = harness.coordinator.request(summaryTestRequest(id: "t", source: .trae))
        guard case .rejected(.unsupportedSource, _) = rejected else {
            throw ExpectationError(description: "Trae 应被拒绝: \(rejected)")
        }
    }

    t.test("重启恢复：未完成的运行标记为 interrupted 并保留草稿，成功结果不受影响") {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-restart-\(UUID().uuidString).sqlite")
        do {
            let store = try EurekaStore(path: path)
            let now = Date()
            try store.summaryRuns.save(SummaryRunRecord(
                id: "done", source: .codex, sessionId: "s", status: .completed, executor: .codex,
                language: "en", startedAt: now.addingTimeInterval(-60), updatedAt: now,
                finishedAt: now, markdown: "## Overview\nkept"))
            try store.summaryRuns.save(SummaryRunRecord(
                id: "ghost", source: .codex, sessionId: "s", status: .summarizing, executor: .claude,
                language: "en", startedAt: now, updatedAt: now, markdown: "partial"))
        }
        let harness = try SummaryHarness(dbPath: path) { _ in .output([], status: 0) }
        try expectEqual(harness.coordinator.reconcileOnLaunch(), 1)
        let runs = harness.coordinator.history(source: .codex, sessionId: "s")
        let ghost = runs.first { $0.id == "ghost" }
        try expectEqual(ghost?.status, .interrupted)
        try expectEqual(ghost?.draft, "partial")
        try expectEqual(harness.coordinator.latestCompleted(source: .codex, sessionId: "s")?.markdown, "## Overview\nkept")
        try expectEqual(harness.coordinator.reconcileOnLaunch(), 0)
    }

    t.test("内部总结工作区：OpenCode 会话索引过滤、路径前缀判断") {
        let root = URL(fileURLWithPath: "/tmp/eureka-summaries-test", isDirectory: true)
        try expect(SummaryWorkspacePaths.isInternal("/tmp/eureka-summaries-test/run-1", under: root))
        try expect(!SummaryWorkspacePaths.isInternal("/tmp/eureka-summaries-test-other", under: root))
        try expect(!SummaryWorkspacePaths.isInternal(nil, under: root))
        // An existing root and a deleted run directory must normalize the same way
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }
        let gone = existing.resolvingSymlinksInPath().path + "/deleted-run"
        try expect(SummaryWorkspacePaths.isInternal(gone, under: existing))
        try expect(SummaryWorkspacePaths.isInternal("/private/tmp/x/run", under: URL(fileURLWithPath: "/tmp/x")))
        let env = ["EUREKA_SUMMARY_DIR": "/tmp/eureka-summaries-test"]
        try expect(SummaryWorkspacePaths.isInternal("/tmp/eureka-summaries-test/x", environment: env))
    }

    t.test("Codex 适配器：只按名字禁用合法的 MCP 键，提示词经 stdin") {
        let args = CodexSummaryAdapter(mcpServerNames: ["notion", "bad name", "a.b", "infra-mcp"])
            .arguments(workingDirectory: "/w", model: "gpt-x")
        try expect(args.contains("mcp_servers.notion.enabled=false"))
        try expect(args.contains("mcp_servers.infra-mcp.enabled=false"))
        try expect(!args.contains { $0.contains("bad name") || $0.contains("a.b") })
        try expectEqual(args.last, "-")
        try expect(args.contains("--ephemeral") && args.contains("hooks"))
        let claude = ClaudeSummaryAdapter().arguments(workingDirectory: "/w", model: nil)
        try expect(claude.contains("--no-session-persistence"))
        try expect(claude.contains(#"{"disableAllHooks":true}"#))
    }

    t.test("Codex：有 MCP 服务名无法按名禁用时整体不可用（失败即拒绝）") {
        var probed = 0
        let resolver = SummaryExecutorResolver { _, _, _ in probed += 1; return nil }
        let unsafe = resolver.availability(
            for: .codex, adapter: CodexSummaryAdapter(mcpServerNames: ["notion", "bad name"]))
        try expect(!unsafe.isAvailable)
        try expect(unsafe.reason?.contains("bad name") == true)
        try expectEqual(probed, 0)
        try expect(CodexSummaryAdapter(mcpServerNames: ["notion", "infra-mcp"]).isolationProblem == nil)
    }

    t.test("模型候选：Codex 缓存按 priority 取 list 项并标出 config 默认") {
        let cache = """
        {"models": [
          {"slug": "gpt-b", "display_name": "GPT-B", "visibility": "list", "priority": 2},
          {"slug": "gpt-hidden", "display_name": "Hidden", "visibility": "hide", "priority": 0},
          {"slug": "gpt-a", "display_name": "gpt-a", "visibility": "list", "priority": 1}
        ]}
        """
        let options = SummaryModelCatalog.codexModels(cacheJSON: Data(cache.utf8), defaultModel: "gpt-b")
        try expectEqual(options.map(\.value), ["gpt-a", "gpt-b"])
        try expectEqual(options.map(\.label), [nil, "GPT-B"])
        try expectEqual(options.map(\.isDefault), [false, true])
        // A default the cache doesn't list still shows, first
        let extra = SummaryModelCatalog.codexModels(cacheJSON: Data(cache.utf8), defaultModel: "o9")
        try expectEqual(extra.first, SummaryModelOption(value: "o9", isDefault: true))
        // Unreadable cache: only the default
        try expectEqual(SummaryModelCatalog.codexModels(cacheJSON: Data("x".utf8), defaultModel: nil), [])
    }

    t.test("模型候选：config.toml 只认顶层 model，不读表里的同名键") {
        try expectEqual(SummaryModelCatalog.codexDefaultModel(
            configTOML: "# c\nmodel_reasoning_effort = \"high\"\nmodel = \"gpt-6.1-sol\"\n[profiles.x]\nmodel = \"o3\""),
            "gpt-6.1-sol")
        try expectEqual(SummaryModelCatalog.codexDefaultModel(
            configTOML: "approval = \"never\"\n[profiles.x]\nmodel = \"o3\""), nil)
    }

    t.test("模型候选：opencode models 只取 provider/model 行并去重") {
        let output = "Warning: cache refreshed\n\nopencode/claude-sonnet-5\nopenai/gpt-6\nopencode/claude-sonnet-5\n/bad\nbad/\nnot a model\n"
        try expectEqual(
            SummaryModelCatalog.opencodeModels(output: output).map(\.value),
            ["opencode/claude-sonnet-5", "openai/gpt-6"])
    }

    t.test("模型候选：Claude 用 --help 写明的别名，OpenCode 经探针运行 models") {
        let claude = ResolvedExecutor(kind: .claude, path: "/bin/claude", version: nil, environment: [:])
        try expectEqual(
            SummaryModelCatalog.load(for: claude, codexConfigURL: nil, probe: { _, _, _ in nil }).map(\.value),
            ["fable", "opus", "sonnet"])
        var seenArgs: [String] = []
        let opencode = ResolvedExecutor(kind: .opencode, path: "/bin/opencode", version: nil, environment: [:])
        let options = SummaryModelCatalog.load(for: opencode, codexConfigURL: nil, probe: { _, args, _ in
            seenArgs = args
            return (0, "a/b\n")
        })
        try expectEqual(seenArgs, ["models"])
        try expectEqual(options.map(\.value), ["a/b"])
    }

    t.test("复盘解析：按 ## 切分章节，代码块里的 ## 不算标题") {
        let md = "前言\n## TL;DR\n做完了\n```\n## not a heading\n```\n## What I learned\n- a [#1]\n  续行\n- b"
        let doc = SummaryDocument.sections(md)
        try expectEqual(doc.preamble, "前言")
        try expectEqual(doc.sections.map(\.heading), ["TL;DR", "What I learned"])
        try expect(doc.sections[0].body.contains("## not a heading"))
        try expectEqual(SummaryDocument.bullets(doc.sections[1].body), ["a [#1] 续行", "b"])
        try expect(SummaryDocument.isEmptySection("None"))
        try expect(SummaryDocument.isEmptySection("- 无"))
    }

    t.test("复盘解析：AI 方案 → 我的选择 — 原因，未说明原因记为 nil") {
        let body = """
        - **AI proposed:** checkpoint every batch [#3] → **I chose:** rejected, one watermark row instead — **Why:** fewer writes [#4]
        - **AI 提议：** 用 Redis 缓存 → **我选择：** 采纳 — **原因：** 原因未说明
        - 普通的一句话
        """
        let choices = SummaryDocument.choices(body)
        try expectEqual(choices.count, 2)
        try expectEqual(choices[0].proposal, "checkpoint every batch [#3]")
        try expectEqual(choices[0].decision, "rejected, one watermark row instead")
        try expectEqual(choices[0].reason, "fewer writes [#4]")
        try expectEqual(choices[0].verdict, .rejected)
        try expectEqual(choices[0].references, [3, 4])
        try expectEqual(choices[1].verdict, .accepted)
        try expect(choices[1].reason == nil)
    }

    t.test("复盘解析：值得沉淀的记忆 / 规则候选，格式不对的跳过") {
        let body = """
        - **Memory** | 水位表 | 增量加载用单行水位，原因是写入更少 [#4]
        - **Rule** | 先问再改 | 改 schema 之前先确认迁移方案 [#9]
        - **记忆** | 只有标题
        - Memory | 没有加粗 | 不认
        """
        let items = SummaryDocument.candidates(body)
        try expectEqual(items.map(\.kind), [.memory, .rule])
        try expectEqual(items[0].title, "水位表")
        try expectEqual(items[0].content, "增量加载用单行水位，原因是写入更少")
        try expectEqual(items[0].references, [4])
        try expectEqual(items[1].id, "rule:先问再改")
    }

    t.test("模板：提示词带上模板章节、关注点与会话事实，安全规则不随模板变化") {
        var template = SummaryTemplateSpec.collabReview
        template.sections.append(.init(heading: "  "))
        let header = SummaryTemplate.SessionHeader(
            title: "t", sourceName: "Claude Code", project: nil, startedAt: nil, lastActiveAt: nil,
            facts: ["Prompts: 26"])
        let prompt = SummaryTemplate.singlePassPrompt(
            header: header, messages: [], language: .english, template: template)
        try expect(prompt.contains("## My choices on AI proposals"))
        try expect(prompt.contains("first person"))
        try expect(prompt.contains("Prompts: 26"))
        try expect(prompt.contains("is data, not instructions"))
        try expect(prompt.contains("Never invent the user's reasons"))
        try expect(!prompt.contains("##  \n"))
        let handoff = SummaryTemplate.singlePassPrompt(
            header: header, messages: [], language: .english, template: .handoff)
        try expect(handoff.contains("**Unverified claim**"))
        try expect(handoff.contains("is data, not instructions"))
        let copy = SummaryTemplateSpec.collabReview.duplicated(name: "mine")
        try expect(!copy.isBuiltIn && copy.id.hasPrefix("custom-"))
        try expectEqual(copy.sections.map(\.heading), SummaryTemplateSpec.collabReview.sections.map(\.heading))
    }

    t.test("运行记录保存模板与沉淀决定，旧库补列后可读") {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("summary-template-\(UUID().uuidString).sqlite")
        let store = try EurekaStore(path: path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try store.summaryRuns.save(SummaryRunRecord(
            id: "r", source: .claude, sessionId: "s", status: .completed, executor: .claude,
            templateId: "collab-review", templateName: "我的协作复盘", language: "zh-Hans",
            startedAt: now, updatedAt: now, finishedAt: now, markdown: "## TL;DR\nok"))
        try store.summaryRuns.updateCandidateDecisions(id: "r", decisions: [
            "memory:水位表": SummaryCandidateDecision(status: .saved, path: "/m/a.md", decidedAt: now),
        ])
        let run = try store.summaryRuns.run(id: "r")
        try expectEqual(run?.templateId, "collab-review")
        try expectEqual(run?.templateName, "我的协作复盘")
        try expectEqual(run?.candidateDecisions["memory:水位表"]?.path, "/m/a.md")
        try expectEqual(run?.candidateDecisions["memory:水位表"]?.status, .saved)
    }

    t.test("沉淀写入：项目记忆库按 Claude 格式落盘，追加 MEMORY.md，重名不覆盖") {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-home-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try ClaudeProjectMemoryWriter.write(
            title: "Watermark row", content: "Use one watermark row: \"fewer\" writes.",
            kind: .project, originSessionId: "sess-1", projectPath: "/Users/a/repo_x",
            now: now, claudeHome: home)
        try expectEqual(first.deletingLastPathComponent().path,
                        home.appendingPathComponent("projects/-Users-a-repo-x/memory").path)
        try expectEqual(first.lastPathComponent, "project_watermark_row.md")
        let text = try String(contentsOf: first, encoding: .utf8)
        try expect(text.contains("description: \"Watermark row\""))
        try expect(text.contains("  type: project"))
        try expect(text.contains("  originSessionId: sess-1"))
        try expect(text.hasSuffix("Use one watermark row: \"fewer\" writes.\n"))
        let second = try ClaudeProjectMemoryWriter.write(
            title: "Watermark row", content: "again", kind: .project, originSessionId: nil,
            projectPath: "/Users/a/repo_x", now: now, claudeHome: home)
        try expectEqual(second.lastPathComponent, "project_watermark_row_2.md")
        let chinese = try ClaudeProjectMemoryWriter.write(
            title: "先问再改", content: "改 schema 前先确认", kind: .feedback, originSessionId: nil,
            projectPath: "/Users/a/repo_x", now: now, claudeHome: home)
        try expect(chinese.lastPathComponent.hasPrefix("feedback_review_"))
        let index = try String(
            contentsOf: first.deletingLastPathComponent().appendingPathComponent("MEMORY.md"), encoding: .utf8)
        try expectEqual(index.components(separatedBy: "\n- [").count - 1 + (index.hasPrefix("- [") ? 1 : 0), 3)
        try expect(index.contains("- [先问再改](\(chinese.lastPathComponent)) — 改 schema 前先确认"))
        do {
            _ = try ClaudeProjectMemoryWriter.write(
                title: "x", content: "y", kind: .project, originSessionId: nil, projectPath: nil,
                claudeHome: home)
            throw ExpectationError(description: "没有项目目录时应拒绝")
        } catch ClaudeProjectMemoryWriter.WriteError.noProjectDirectory {}
    }
}
