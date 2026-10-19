import Darwin
import EurekaIngest
import EurekaInstall
import EurekaKit
import Foundation

// Answering Claude's questions (AskUserQuestion) on the island: answer progress, card queue,
// question file parsing, the answer hook entry in settings.json, and an end-to-end round trip
// actually running eureka-ask.

private func pendingQuestion(
    _ id: String, _ questions: [AskQuestion], pid: Int32 = getpid()
) -> PendingQuestion {
    PendingQuestion(
        id: id, sessionId: "s-\(id)", cwd: "/Users/me/work/demo", hookPid: pid,
        createdAt: Date(timeIntervalSince1970: 1000), questions: questions)
}

private let frameworkQuestion = AskQuestion(
    question: "用哪个框架？", header: "框架",
    options: [AskOption(label: "React", description: "组件库"), AskOption(label: "Vue")],
    multiSelect: false)
private let sectionsQuestion = AskQuestion(
    question: "要哪些章节？", header: "章节",
    options: [AskOption(label: "引言"), AskOption(label: "方法"), AskOption(label: "结论")],
    multiSelect: true)

func questionDraftTests(_ t: TestRunner) {
    t.suite("QuestionDraft")

    t.test("单选点一下即答，逐题前进，全部答完才算完成") {
        var draft = QuestionDraft(
            question: pendingQuestion("q", [frameworkQuestion, sectionsQuestion]))
        try expectEqual(draft.progress.current, 1)
        draft.choose("Angular")  // not among the options
        try expectEqual(draft.answers, [:])
        draft.choose("Vue")
        try expectEqual(draft.answers, ["用哪个框架？": "Vue"])
        try expectEqual(draft.current, sectionsQuestion, "进入第二题")
        try expect(!draft.isComplete)
    }

    t.test("多选按选项顺序用「, 」连接，没勾不能确定") {
        var draft = QuestionDraft(question: pendingQuestion("q", [sectionsQuestion]))
        draft.confirmSelection()
        try expect(!draft.isComplete, "一个没勾")
        draft.toggle("结论")
        draft.toggle("引言")
        draft.toggle("方法")
        draft.toggle("方法")  // uncheck
        draft.choose("引言")  // multi-select doesn't accept a single-select action
        try expectEqual(draft.selected, ["结论", "引言"])
        draft.confirmSelection()
        try expectEqual(draft.answers, ["要哪些章节？": "引言, 结论"])
        try expect(draft.isComplete)
    }

    t.test("其他：空白不算；单选是原文；多选接在已勾选项后面") {
        var single = QuestionDraft(question: pendingQuestion("q", [frameworkQuestion]))
        single.beginOther()
        try expect(single.isTypingOther)
        single.submitOther("   ")
        try expect(!single.isComplete)
        single.submitOther("  Svelte ")
        try expectEqual(single.answers, ["用哪个框架？": "Svelte"])
        try expect(!single.isTypingOther)

        var multi = QuestionDraft(question: pendingQuestion("q", [sectionsQuestion]))
        multi.toggle("方法")
        multi.beginOther()
        multi.submitOther("附录")
        try expectEqual(multi.answers, ["要哪些章节？": "方法, 附录"])
    }
}

func questionQueueTests(_ t: TestRunner) {
    t.suite("IslandCardQueue · 提问卡")

    func finished(_ session: String) -> IslandState.Card {
        .finished(FinishedTask(
            source: .claude, sessionId: session,
            finishedAt: Date(timeIntervalSince1970: 1000), outcome: .success))
    }
    let first = IslandState.Card.question(pendingQuestion("a", [frameworkQuestion]))
    let second = IslandState.Card.question(pendingQuestion("b", [frameworkQuestion]))

    t.test("提问卡顶掉正在展示的完成卡，完成卡回到队首；同 id 不重复入队") {
        var queue = IslandCardQueue()
        queue.enqueue(finished("f1"))
        queue.enqueue(finished("f2"))
        queue.enqueue(first)
        queue.enqueue(first)
        try expectEqual(queue.current, first)
        try expectEqual(queue.pending, [finished("f1"), finished("f2")])
        try expectEqual(queue.questionIds, ["a"])
    }

    t.test("多个提问按到达顺序排在其余卡之前；撤卡后轮到下一张") {
        var queue = IslandCardQueue()
        queue.enqueue(first)
        queue.enqueue(finished("f1"))
        queue.enqueue(second)
        try expectEqual(queue.pending, [second, finished("f1")])
        queue.removeQuestion(id: "a")
        try expectEqual(queue.current, second)
        queue.removeQuestion(id: "b")
        try expectEqual(queue.current, finished("f1"))
        try expectEqual(IslandState.Card.question(pendingQuestion("a", [])).autoDismisses, false)
    }
}

func questionInboxTests(_ t: TestRunner) {
    t.suite("QuestionInbox")

    func record(pid: Int, questions: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "v": 1, "id": "ignored", "pid": pid, "createdAtMs": 1_700_000_000_000,
            "sessionId": "sess-1", "cwd": "/Users/me/work/demo",
            "transcriptPath": "/Users/me/.claude/projects/-demo/sess-1.jsonl",
            "toolInput": ["questions": questions],
        ])
    }
    let rawQuestion: [String: Any] = [
        "question": "用哪个框架？", "header": "框架", "multiSelect": false,
        "options": [["label": "React", "description": "组件库"], ["label": "Vue"]],
    ]

    t.test("解析 hook 写的问题文件；id 以文件名为准") {
        let question = try QuestionInbox.decode(
            record(pid: 4242, questions: [rawQuestion]), fileName: "toolu_01AB-c.json")
        try expectEqual(question?.id, "toolu_01AB-c")
        try expectEqual(question?.hookPid, 4242)
        try expectEqual(question?.taskId, "claude:sess-1")
        try expectEqual(question?.transcriptPath, "/Users/me/.claude/projects/-demo/sess-1.jsonl")
        try expectEqual(question?.questions, [frameworkQuestion])
        try expectEqual(question?.createdAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    t.test("拒绝可疑文件名、缺 pid、任何一个问题读不懂") {
        let data = try record(pid: 4242, questions: [rawQuestion])
        try expect(QuestionInbox.decode(data, fileName: "../evil.json") == nil)
        try expect(QuestionInbox.decode(data, fileName: "a b.json") == nil)
        try expect(QuestionInbox.decode(data, fileName: "toolu.txt") == nil)
        let noPid = try record(pid: 0, questions: [rawQuestion])
        try expect(QuestionInbox.decode(noPid, fileName: "x.json") == nil)
        let noOptions: [String: Any] = ["question": "空选项？", "options": []]
        let partlyBroken = try record(pid: 4242, questions: [rawQuestion, noOptions])
        try expect(QuestionInbox.decode(partlyBroken, fileName: "x.json") == nil,
                   "漏答任何一题 hook 都不放行，整张不接")
    }
}

func questionTranscriptProbeTests(_ t: TestRunner) {
    t.suite("QuestionTranscriptProbe · Claude 里作答后撤卡")

    /// Question time: 2026-10-19T07:00:00Z
    let askedAt = Date(timeIntervalSince1970: 1_792_393_200)
    func stamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: askedAt.addingTimeInterval(offset))
    }
    func line(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) + "\n"
    }
    func toolUse(_ id: String, _ question: String = "用哪个框架？", at offset: TimeInterval = -1,
                 sidechain: Bool = false) throws -> String {
        try line([
            "type": "assistant", "timestamp": stamp(offset), "isSidechain": sidechain,
            "message": ["role": "assistant", "content": [[
                "type": "tool_use", "id": id, "name": "AskUserQuestion",
                "input": ["questions": [["question": question, "header": "框架", "multiSelect": false,
                                         "options": [["label": "React"], ["label": "Vue"]]]]],
            ]]],
        ])
    }
    func toolResult(_ id: String, at offset: TimeInterval, sidechain: Bool = false) throws -> String {
        try line([
            "type": "user", "timestamp": stamp(offset), "isSidechain": sidechain,
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": id, "content": "User has answered your questions",
            ]]],
            "toolUseResult": ["questions": [], "answers": ["用哪个框架？": "Vue"]],
        ])
    }
    func transcript(_ name: String, _ text: String) throws -> URL {
        let dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-sandbox/question-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).jsonl")
        try Data(text.utf8).write(to: url)
        return url
    }
    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
        try handle.close()
    }
    func question(_ url: URL?) -> PendingQuestion {
        PendingQuestion(
            id: "q-\(url?.lastPathComponent ?? "none")", sessionId: "s-1", transcriptPath: url?.path,
            hookPid: getpid(), createdAt: askedAt, questions: [frameworkQuestion])
    }

    t.test("等待中没有结果；Claude 里答完写出 tool_result 后判定了结") {
        let url = try transcript("answered", toolUse("toolu_B"))
        let probe = QuestionTranscriptProbe()
        try expect(!probe.isSettled(question(url)))
        try append(toolResult("toolu_B", at: 4), to: url)
        try expect(probe.isSettled(question(url)))
    }

    t.test("同样的题问过一次：上一次的 tool_result 早于提问，不算") {
        let earlier = try toolUse("toolu_A", at: -60) + toolResult("toolu_A", at: -50) + toolUse("toolu_B")
        let url = try transcript("asked-twice", earlier)
        let probe = QuestionTranscriptProbe()
        try expect(!probe.isSettled(question(url)))
        try append(toolResult("toolu_B", at: 3), to: url)
        try expect(probe.isSettled(question(url)))
    }

    t.test("别的题、子代理的结果都不算") {
        let text = try toolUse("toolu_X", "要哪些章节？") + toolUse("toolu_S", sidechain: true)
            + toolResult("toolu_X", at: 2) + toolResult("toolu_S", at: 2, sidechain: true)
        let url = try transcript("unrelated", text)
        try expect(!QuestionTranscriptProbe().isSettled(question(url)))
    }

    t.test("行被拆成两次写入、首次从文件中间开始读：都不误判、不漏判") {
        let filler = try line(["type": "progress", "data": String(repeating: "x", count: 4096)])
        let url = try transcript("partial", filler + toolUse("toolu_B"))
        let probe = QuestionTranscriptProbe(initialTailBytes: 1024)
        let result = try toolResult("toolu_B", at: 5)
        let cut = result.index(result.startIndex, offsetBy: 40)
        try append(String(result[..<cut]), to: url)
        try expect(!probe.isSettled(question(url)))
        try append(String(result[cut...]), to: url)
        try expect(probe.isSettled(question(url)))
    }

    t.test("没有转录路径 / 文件不存在：不判定了结") {
        try expect(!QuestionTranscriptProbe().isSettled(question(nil)))
        let missing = URL(fileURLWithPath: "/nonexistent/transcript.jsonl")
        try expect(!QuestionTranscriptProbe().isSettled(question(missing)))
    }
}

func claudeAskHookInstallerTests(_ t: TestRunner) {
    t.suite("ClaudeAskHookInstaller")

    let askPath = "/Users/me/Library/Application Support/Eureka/bin/lululumei-ask"
    let relayPath = "/Users/me/Library/Application Support/Eureka/bin/lululumei-relay"
    let foreign = """
    {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/guard.sh"}]}]},
     "model":"opus"}
    """

    func entries(_ json: String, _ event: String) throws -> [[String: Any]] {
        let root = try ClaudeHooksInstaller.parseForTest(json)
        return (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
    }

    t.test("装在 PermissionRequest：matcher 精确为 AskUserQuestion、timeout 610，他人条目逐字不动；重装替换路径") {
        let withRelay = try ClaudeHooksInstaller.install(into: foreign, relayPath: relayPath)
        let installed = try ClaudeAskHookInstaller.install(into: withRelay, askPath: askPath)
        try expectEqual(try entries(installed, "PreToolUse").count, 2, "他人 + relay，没有答题条目")
        let asks = try entries(installed, "PermissionRequest")
        try expectEqual(asks.count, 1)
        try expectEqual(asks.first?["matcher"] as? String, "AskUserQuestion")
        let command = (asks.first?["hooks"] as? [[String: Any]])?.first
        try expectEqual(command?["command"] as? String, "\"\(askPath)\"")
        try expectEqual(command?["timeout"] as? Int, 610)
        try expect(ClaudeAskHookInstaller.isInstalled(in: installed, askPath: askPath))
        try expectEqual(ClaudeHooksInstaller.status(of: installed), .installed)

        let moved = try ClaudeAskHookInstaller.install(into: installed, askPath: "/new/lululumei-ask")
        try expectEqual(try entries(moved, "PermissionRequest").count, 1, "替换不重复")
        try expect(!ClaudeAskHookInstaller.isInstalled(in: moved, askPath: askPath))
        try expect(ClaudeAskHookInstaller.isInstalled(in: moved, askPath: "/new/lululumei-ask"))
    }

    t.test("挂在 PreToolUse 下的答题条目算没装好；重装后只剩 PermissionRequest 下的一条") {
        let askEntry = """
        {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"\\"\(askPath)\\"","timeout":610}]}
        """
        let guardEntry = #"{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/guard.sh"}]}"#
        let preToolUseOnly = #"{"hooks":{"PreToolUse":["# + guardEntry + "," + askEntry + "]}}"
        try expect(ClaudeAskHookInstaller.hasAnyEntry(in: preToolUseOnly))
        try expect(!ClaudeAskHookInstaller.isInstalled(in: preToolUseOnly, askPath: askPath))

        let migrated = try ClaudeAskHookInstaller.install(into: preToolUseOnly, askPath: askPath)
        let left = try entries(migrated, "PreToolUse")
        try expectEqual(left.count, 1)
        try expectEqual(left.first?["matcher"] as? String, "Bash")
        try expectEqual(try entries(migrated, "PermissionRequest").count, 1)
        try expect(ClaudeAskHookInstaller.isInstalled(in: migrated, askPath: askPath))

        // Present in both: the PermissionRequest one is correct, but the PreToolUse one still
        // blocks the confirmation UI
        let both = #"{"hooks":{"PreToolUse":["# + askEntry + #"],"PermissionRequest":["# + askEntry + "]}}"
        try expect(!ClaudeAskHookInstaller.isInstalled(in: both, askPath: askPath))
        let cleaned = try ClaudeAskHookInstaller.install(into: both, askPath: askPath)
        try expectEqual(try entries(cleaned, "PreToolUse").count, 0)
        let root = try ClaudeHooksInstaller.parseForTest(cleaned)
        try expect((root["hooks"] as? [String: Any])?["PreToolUse"] == nil, "空事件连键删掉")
        try expect(ClaudeAskHookInstaller.isInstalled(in: cleaned, askPath: askPath))

        let off = try ClaudeAskHookInstaller.uninstall(from: both)
        try expect(!ClaudeAskHookInstaller.hasAnyEntry(in: off), "关掉开关时两处都卸")
    }

    t.test("关掉开关只卸答题那条；卸 Claude hooks 时一起卸；不算他人 hook") {
        let full = try ClaudeAskHookInstaller.install(
            into: ClaudeHooksInstaller.install(into: foreign, relayPath: relayPath),
            askPath: askPath)
        try expectEqual(ClaudeHooksInstaller.foreignHooks(in: full).tools, ["guard.sh"])

        let askOff = try ClaudeAskHookInstaller.uninstall(from: full)
        try expect(!ClaudeAskHookInstaller.hasAnyEntry(in: askOff))
        try expectEqual(ClaudeHooksInstaller.status(of: askOff), .installed, "relay 条目还在")

        let allOff = try ClaudeHooksInstaller.uninstall(from: full)
        try expect(!ClaudeAskHookInstaller.hasAnyEntry(in: allOff))
        let left = try entries(allOff, "PreToolUse")
        try expectEqual(left.count, 1)
        try expectEqual(left.first?["matcher"] as? String, "Bash")
        let root = try ClaudeHooksInstaller.parseForTest(allOff)
        try expectEqual(root["model"] as? String, "opus")
    }
}

// MARK: - End to end: actually running eureka-ask

func askHookEndToEndTests(_ t: TestRunner) {
    t.suite("eureka-ask 端到端")

    let askBinary = Bundle.main.executableURL!.deletingLastPathComponent()
        .appendingPathComponent("eureka-ask")
    let toolInput: [String: Any] = [
        "questions": [[
            "question": "用哪个框架？", "header": "框架", "multiSelect": false,
            "options": [["label": "React", "description": "组件库"], ["label": "Vue"]],
        ]],
    ]

    /// Sandbox directory inside the repo (.build is already gitignored)
    func sandbox(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-sandbox/ask-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// PermissionRequest stdin: no tool_use_id
    func hookInput(tool: String = "AskUserQuestion") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PermissionRequest", "session_id": "sess-e2e",
            "cwd": "/Users/me/work/demo", "permission_mode": "default",
            "transcript_path": "/Users/me/.claude/projects/-demo/sess-e2e.jsonl",
            "tool_name": tool, "tool_input": toolInput, "permission_suggestions": [],
        ])
    }

    struct Run {
        let process: Process
        let stdout: Pipe
        func finish() -> (output: String, status: Int32) {
            process.waitUntilExit()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return (String(decoding: data, as: UTF8.self), process.terminationStatus)
        }
    }

    func launch(root: URL, input: Data) throws -> Run {
        let process = Process()
        process.executableURL = askBinary
        process.environment = ["EUREKA_SPOOL_DIR": root.path]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        stdin.fileHandleForWriting.write(input)
        try stdin.fileHandleForWriting.close()
        return Run(process: process, stdout: stdout)
    }

    func waitForQuestion(_ inbox: QuestionInbox) throws -> PendingQuestion {
        for _ in 0..<60 {
            if let question = inbox.pending().first { return question }
            usleep(50_000)
        }
        throw ExpectationError(description: "3 秒内没等到问题文件")
    }

    t.test("构建产物存在") {
        try expect(FileManager.default.isExecutableFile(atPath: askBinary.path),
                   "先 swift build --product eureka-ask（make test 会做）")
    }

    t.test("岛不在（没有心跳）：立刻静默退出，只留 Claude 自己的确认界面") {
        let root = try sandbox("no-heartbeat")
        let started = Date()
        let result = try launch(root: root, input: hookInput()).finish()
        try expectEqual(result.status, 0)
        try expectEqual(result.output, "")
        try expect(Date().timeIntervalSince(started) < 2, "不该等待")
    }

    t.test("不是 AskUserQuestion：静默退出，绝不输出放行决定") {
        let root = try sandbox("other-tool")
        try QuestionInbox(root: root).writeHeartbeat()
        let result = try launch(root: root, input: hookInput(tool: "Bash")).finish()
        try expectEqual(result.output, "")
        try expectEqual(result.status, 0)
    }

    t.test("岛上作答：hook 输出 PermissionRequest 的 allow 决定 + 原样带回 questions 的 updatedInput + answers") {
        let root = try sandbox("answer")
        let inbox = QuestionInbox(root: root)
        try inbox.writeHeartbeat()
        let run = try launch(root: root, input: hookInput())
        let question = try waitForQuestion(inbox)
        try expect(UUID(uuidString: question.id) != nil, "题目 id 是 hook 生成的 UUID")
        try expectEqual(question.sessionId, "sess-e2e")
        try expectEqual(question.transcriptPath, "/Users/me/.claude/projects/-demo/sess-e2e.jsonl")
        try expectEqual(question.questions, [frameworkQuestion])
        try inbox.send(.answer(["用哪个框架？": "Vue"]), to: question.id)
        let result = run.finish()
        try expectEqual(result.status, 0)
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
        let output = (object as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        try expectEqual(output?["hookEventName"] as? String, "PermissionRequest")
        let decision = output?["decision"] as? [String: Any]
        try expectEqual(decision?["behavior"] as? String, "allow")
        try expectEqual(Set(output?.keys.map { $0 } ?? []), ["hookEventName", "decision"])
        let updated = decision?["updatedInput"] as? [String: Any]
        try expectEqual(updated?["answers"] as? [String: String], ["用哪个框架？": "Vue"])
        let echoed = try JSONSerialization.data(
            withJSONObject: updated?["questions"] ?? [], options: .sortedKeys)
        let original = try JSONSerialization.data(
            withJSONObject: toolInput["questions"]!, options: .sortedKeys)
        try expectEqual(echoed, original, "questions 原样带回")
        try expect(inbox.pending().isEmpty, "问题文件已删")
    }

    t.test("收起 / 答案缺题：静默退出") {
        for (name, reply) in [
            ("dismiss", QuestionInbox.Reply.dismiss),
            ("partial", QuestionInbox.Reply.answer(["别的问题": "x"])),
        ] {
            let root = try sandbox(name)
            let inbox = QuestionInbox(root: root)
            try inbox.writeHeartbeat()
            let run = try launch(root: root, input: hookInput())
            let question = try waitForQuestion(inbox)
            try inbox.send(reply, to: question.id)
            let result = run.finish()
            try expectEqual(result.output, "", name)
            try expectEqual(result.status, 0, name)
        }
    }

    t.test("被 Claude 终止（SIGTERM）：删掉问题文件，岛上的卡随之撤掉") {
        let root = try sandbox("sigterm")
        let inbox = QuestionInbox(root: root)
        try inbox.writeHeartbeat()
        let run = try launch(root: root, input: hookInput())
        _ = try waitForQuestion(inbox)
        run.process.terminate()
        let result = run.finish()
        try expectEqual(result.output, "")
        try expect(inbox.pending().isEmpty)
    }

    t.test("等待中岛没了（心跳删除）：几秒内放手") {
        let root = try sandbox("island-gone")
        let inbox = QuestionInbox(root: root)
        try inbox.writeHeartbeat()
        let run = try launch(root: root, input: hookInput())
        _ = try waitForQuestion(inbox)
        let started = Date()
        inbox.removeHeartbeat()
        let result = run.finish()
        try expectEqual(result.output, "")
        try expect(Date().timeIntervalSince(started) < 4, "2 秒一查")
        try expect(inbox.pending().isEmpty)
    }
}
