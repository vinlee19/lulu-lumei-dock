import Darwin
import EurekaIngest
import EurekaInstall
import EurekaKit
import Foundation

// 灵动岛回答 Claude 提问（AskUserQuestion）：作答进度、卡片队列、问题文件解析、
// settings.json 里的答题 hook 条目，以及真实运行 eureka-ask 的端到端往返。

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
        draft.choose("Angular")  // 不在选项里
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
        draft.toggle("方法")  // 取消
        draft.choose("引言")  // 多选题不接受单选操作
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

func claudeAskHookInstallerTests(_ t: TestRunner) {
    t.suite("ClaudeAskHookInstaller")

    let askPath = "/Users/me/Library/Application Support/Eureka/bin/lululumei-ask"
    let relayPath = "/Users/me/Library/Application Support/Eureka/bin/lululumei-relay"
    let foreign = """
    {"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/opt/guard.sh"}]}]},
     "model":"opus"}
    """

    func preToolUse(_ json: String) throws -> [[String: Any]] {
        let root = try ClaudeHooksInstaller.parseForTest(json)
        return (root["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]] ?? []
    }

    t.test("装上：matcher 精确为 AskUserQuestion、timeout 610，他人条目逐字不动；重装替换路径") {
        let withRelay = try ClaudeHooksInstaller.install(into: foreign, relayPath: relayPath)
        let installed = try ClaudeAskHookInstaller.install(into: withRelay, askPath: askPath)
        let entries = try preToolUse(installed)
        try expectEqual(entries.count, 3, "他人 + relay + 答题")
        let ask = entries.first { $0["matcher"] as? String == "AskUserQuestion" }
        let command = (ask?["hooks"] as? [[String: Any]])?.first
        try expectEqual(command?["command"] as? String, "\"\(askPath)\"")
        try expectEqual(command?["timeout"] as? Int, 610)
        try expect(ClaudeAskHookInstaller.isInstalled(in: installed, askPath: askPath))
        try expectEqual(ClaudeHooksInstaller.status(of: installed), .installed)

        let moved = try ClaudeAskHookInstaller.install(into: installed, askPath: "/new/lululumei-ask")
        try expectEqual(try preToolUse(moved).count, 3, "替换不重复")
        try expect(!ClaudeAskHookInstaller.isInstalled(in: moved, askPath: askPath))
        try expect(ClaudeAskHookInstaller.isInstalled(in: moved, askPath: "/new/lululumei-ask"))
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
        let left = try preToolUse(allOff)
        try expectEqual(left.count, 1)
        try expectEqual(left.first?["matcher"] as? String, "Bash")
        let root = try ClaudeHooksInstaller.parseForTest(allOff)
        try expectEqual(root["model"] as? String, "opus")
    }
}

// MARK: - 端到端：真实运行 eureka-ask

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

    /// 仓库内的沙箱目录（.build 已被 gitignore）
    func sandbox(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/test-sandbox/ask-\(name)", isDirectory: true)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func hookInput(tool: String = "AskUserQuestion", id: String = "toolu_e2e") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hook_event_name": "PreToolUse", "session_id": "sess-e2e", "cwd": "/Users/me/work/demo",
            "tool_name": tool, "tool_use_id": id, "tool_input": toolInput,
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

    t.test("岛不在（没有心跳）：立刻静默退出，Claude 回终端提问") {
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

    t.test("岛上作答：hook 输出 allow + 原样带回 questions 的 updatedInput + answers") {
        let root = try sandbox("answer")
        let inbox = QuestionInbox(root: root)
        try inbox.writeHeartbeat()
        let run = try launch(root: root, input: hookInput())
        let question = try waitForQuestion(inbox)
        try expectEqual(question.id, "toolu_e2e")
        try expectEqual(question.sessionId, "sess-e2e")
        try expectEqual(question.questions, [frameworkQuestion])
        try inbox.send(.answer(["用哪个框架？": "Vue"]), to: question.id)
        let result = run.finish()
        try expectEqual(result.status, 0)
        let object = try JSONSerialization.jsonObject(with: Data(result.output.utf8))
        let output = (object as? [String: Any])?["hookSpecificOutput"] as? [String: Any]
        try expectEqual(output?["hookEventName"] as? String, "PreToolUse")
        try expectEqual(output?["permissionDecision"] as? String, "allow")
        let updated = output?["updatedInput"] as? [String: Any]
        try expectEqual(updated?["answers"] as? [String: String], ["用哪个框架？": "Vue"])
        let echoed = try JSONSerialization.data(
            withJSONObject: updated?["questions"] ?? [], options: .sortedKeys)
        let original = try JSONSerialization.data(
            withJSONObject: toolInput["questions"]!, options: .sortedKeys)
        try expectEqual(echoed, original, "questions 原样带回")
        try expect(inbox.pending().isEmpty, "问题文件已删")
    }

    t.test("回终端 / 答案缺题：静默退出") {
        for (name, reply) in [
            ("terminal", QuestionInbox.Reply.terminal),
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
