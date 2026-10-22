import EurekaIngest
import EurekaKit
import Foundation

/// A Claude session that ends its turn to wait for background agents is not finished: the
/// fixture is a Desktop turn that launched two background agents (`async_launched`) and has not
/// ended yet; tests append the end_turn and the reports in the order Claude Code writes them.
func backgroundTaskTests(_ t: TestRunner) {
    t.suite("Claude 后台任务")

    let sessionId = "fixture-bg-1"
    let agentA = "a0000000000000aaa"
    let agentB = "a0000000000000bbb"

    func line(_ object: [String: Any]) -> String {
        var object = object
        object["sessionId"] = object["sessionId"] ?? sessionId
        object["cwd"] = object["cwd"] ?? "/Users/me/work/review"
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    func notification(_ id: String, toolUseId: String, status: String = "completed") -> String {
        """
        <task-notification>
        <task-id>\(id)</task-id>
        <tool-use-id>\(toolUseId)</tool-use-id>
        <output-file>/private/tmp/claude/tasks/\(id).output</output-file>
        <status>\(status)</status>
        <summary>Agent "Re-attribute" finished</summary>
        <result>报告已写好</result>
        </task-notification>
        """
    }

    func endTurn(_ timestamp: String, text: String = "等审查回来再比对") -> String {
        line([
            "type": "assistant", "isSidechain": false, "uuid": "end-\(timestamp)",
            "timestamp": timestamp,
            "message": [
                "id": "msg-\(timestamp)", "model": "claude-opus-5-5", "role": "assistant",
                "stop_reason": "end_turn", "type": "message",
                "content": [["type": "text", "text": text]],
            ] as [String: Any],
        ])
    }

    func enqueue(_ id: String, toolUseId: String, at timestamp: String) -> String {
        line([
            "type": "queue-operation", "operation": "enqueue", "timestamp": timestamp,
            "content": notification(id, toolUseId: toolUseId),
        ])
    }

    func reportPrompt(_ id: String, toolUseId: String, at timestamp: String,
                      status: String = "completed") -> String {
        line([
            "type": "user", "isSidechain": false, "uuid": "note-\(timestamp)",
            "timestamp": timestamp, "origin": ["kind": "task-notification"],
            "message": ["role": "user", "content": notification(
                id, toolUseId: toolUseId, status: status)] as [String: Any],
        ])
    }

    func interrupt(_ timestamp: String) -> String {
        line([
            "type": "user", "isSidechain": false, "uuid": "int-\(timestamp)",
            "timestamp": timestamp,
            "message": ["role": "user", "content": [
                ["type": "text", "text": "[Request interrupted by user]"],
            ]] as [String: Any],
        ])
    }

    /// projects/<project>/<session>.jsonl holding the fixture, mtime bumped to now
    func makeSession() throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-bg-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-review")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(sessionId).jsonl")
        try FileManager.default.copyItem(
            at: fixtureURL("claude-transcript-background-agents.jsonl"), to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return (root, file)
    }

    /// Appends lines and moves the mtime forward (second-granularity timestamps would flake)
    func append(_ lines: [String], to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        let mtime = (try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]
            as? Date) ?? Date()
        try FileManager.default.setAttributes(
            [.modificationDate: mtime.addingTimeInterval(2)], ofItemAtPath: file.path)
    }

    func observeAll(_ lines: [String]) -> ClaudeBackgroundTasks {
        var tasks = ClaudeBackgroundTasks()
        for text in lines {
            guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8))
                    as? [String: Any],
                  let type = root["type"] as? String
            else { continue }
            tasks.observe(root, type: type)
        }
        return tasks
    }

    func launch(_ id: String, key: String = "agentId", sidechain: Bool = false) -> String {
        line([
            "type": "user", "isSidechain": sidechain, "timestamp": "2026-10-22T02:00:22.000Z",
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_\(id)", "content": "launched"],
            ]] as [String: Any],
            "toolUseResult": ["status": "async_launched", key: id] as [String: Any],
        ])
    }

    t.test("启动与回报：async_launched 记启动，三种回报形态与 TaskStop 记结束，最后一个事件为准") {
        let workflowLaunch = launch("wf1", key: "taskId")
        let bashLaunch = line([
            "type": "user", "timestamp": "2026-10-22T02:00:23.000Z",
            "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "toolu_bash", "content": "running"],
            ]] as [String: Any],
            "toolUseResult": ["stdout": "", "backgroundTaskId": "bsrv01"],
        ])
        var tasks = observeAll([
            launch("ag1"), launch("ag2"), launch("ag3"), workflowLaunch, bashLaunch,
            launch("side1", sidechain: true),
        ])
        try expectEqual(tasks.pendingIds, ["ag1", "ag2", "ag3", "wf1"],
                        "后台 Bash 与侧链启动不计入")

        tasks = observeAll([
            launch("ag1"), launch("ag2"), launch("ag3"), workflowLaunch,
            // Delivered mid-turn as a queued_command attachment
            line(["type": "attachment", "timestamp": "2026-10-22T02:05:00.000Z", "attachment": [
                "type": "queued_command", "commandMode": "task-notification",
                "prompt": notification("ag1", toolUseId: "toolu_ag1"),
            ] as [String: Any]]),
            // Queued for delivery
            enqueue("ag2", toolUseId: "toolu_ag2", at: "2026-10-22T02:06:00.000Z"),
            // The prompt of the follow-up turn (status killed still means it ended)
            reportPrompt("wf1", toolUseId: "toolu_wf1", at: "2026-10-22T02:07:00.000Z",
                         status: "killed"),
            // TaskStop result
            line(["type": "user", "timestamp": "2026-10-22T02:08:00.000Z",
                  "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "toolu_stop", "content": "stopped"],
                  ]] as [String: Any],
                  "toolUseResult": ["task_id": "ag3", "task_type": "local_agent",
                                    "message": "stopped", "command": ""]]),
        ])
        try expectEqual(tasks.pendingCount, 0, "\(tasks.pendingIds)")

        // A tool result quoting someone else's report is not a report
        let quoted = line([
            "type": "user", "timestamp": "2026-10-22T02:09:00.000Z",
            "message": ["role": "user", "content": [[
                "type": "tool_result", "tool_use_id": "toolu_grep",
                "content": notification("ag1", toolUseId: "toolu_ag1"),
            ]]] as [String: Any],
        ])
        try expectEqual(observeAll([launch("ag1"), quoted]).pendingIds, ["ag1"])

        // Resumed with SendMessage and launched again after its first report → running again
        try expectEqual(observeAll([
            launch("ag1"),
            reportPrompt("ag1", toolUseId: "toolu_ag1", at: "2026-10-22T02:10:00.000Z"),
            launch("ag1"),
        ]).pendingIds, ["ag1"])
    }

    t.test("回报解析：一条 prompt 里多个通知块都取到 id、tool_use_id、状态") {
        let reports = ClaudeBackgroundTasks.parseReports(
            notification("x1", toolUseId: "toolu_x1")
                + "\n" + notification("x2", toolUseId: "toolu_x2", status: "failed"))
        try expectEqual(reports.map(\.id), ["x1", "x2"])
        try expectEqual(reports.map(\.toolUseId), ["toolu_x1", "toolu_x2"])
        try expectEqual(reports.map(\.status), ["completed", "failed"])
    }

    t.test("尾窗分类：收尾时还有 2 个后台 agent → 等待 2；中断的 turn 不等待") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        var snapshot = ClaudeSessionBootstrap.classify(fileURL: file)
        try expectEqual(snapshot?.running, true)
        try expectEqual(snapshot?.pendingBackgroundTasks, 2)
        try expectEqual(snapshot?.awaitingBackgroundTasks, 0, "turn 还在跑时不算等待")

        try append([endTurn("2026-10-22T02:01:50.000Z")], to: file)
        snapshot = ClaudeSessionBootstrap.classify(fileURL: file)
        try expectEqual(snapshot?.running, false)
        try expectEqual(snapshot?.awaitingBackgroundTasks, 2)
        try expectEqual(snapshot?.userPromptAt,
                        ISO8601DateFormatter().date(from: "2026-10-22T02:00:00Z"))

        // App launched while waiting → registered as running, then waiting
        let events = ClaudeSessionBootstrap.inspectSession(
            fileURL: file, mtime: Date(), isResumedAlive: { _ in true })
        try expectEqual(Array(events.map(\.kind).prefix(2)), [
            .taskStarted(title: "再复核一下每行的归因"),
            .awaitingBackgroundTasks(count: 2),
        ])

        let (root2, interrupted) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root2) }
        try append([interrupt("2026-10-22T02:01:10.000Z")], to: interrupted)
        snapshot = ClaudeSessionBootstrap.classify(fileURL: interrupted)
        try expectEqual(snapshot?.turnEndOutcome, .interrupted)
        try expectEqual(snapshot?.awaitingBackgroundTasks, 0)
    }

    t.test("尾窗分类：回报已入队、下一轮的 prompt 还没写 → 仍算运行，不在 30ms 间隙里判收尾") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try append([
            endTurn("2026-10-22T02:01:50.000Z"),
            enqueue(agentA, toolUseId: "toolu_bgA", at: "2026-10-22T02:17:02.132Z"),
        ], to: file)
        let snapshot = ClaudeSessionBootstrap.classify(fileURL: file)
        try expectEqual(snapshot?.running, true)
        try expectEqual(snapshot?.pendingBackgroundTasks, 1)
    }

    t.test("监视器全程：收尾转等待、回报轮不出卡，最后一个回报的 turn 收尾才出恰好一张完成卡") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root, liveResumedSessionIds: { [] }) {
            event, _ in events.append(event)
        }
        let store = TaskStore()
        var effects: [TaskStoreEffect] = []
        func scan() {
            events.removeAll()
            watcher.scanOnce()
            for event in events { effects.append(contentsOf: store.apply(event)) }
        }
        func finishes() -> [TaskOutcome] {
            events.compactMap {
                if case .taskFinished(let outcome, _, _) = $0.kind { return outcome } else { return nil }
            }
        }
        func cards() -> Int {
            effects.filter { if case .taskFinished = $0 { return true } else { return false } }.count
        }

        scan()
        guard case .taskStarted = events.first?.kind else {
            throw ExpectationError(description: "首扫应发现运行中: \(events)")
        }

        // The main agent ends its turn with both agents running
        try append([endTurn("2026-10-22T02:01:50.000Z")], to: file)
        scan()
        try expectEqual(finishes(), [], "\(events)")
        try expect(events.contains { $0.kind == .awaitingBackgroundTasks(count: 2) }, "\(events)")
        try expectEqual(store.sortedActiveTasks.first?.awaitingBackgroundTasks, 2)

        // Agent A reports: enqueue, then the follow-up turn's prompt, then that turn ends
        try append([enqueue(agentA, toolUseId: "toolu_bgA", at: "2026-10-22T02:17:02.132Z")],
                   to: file)
        scan()
        try expectEqual(finishes(), [], "入队到 prompt 之间不该判收尾: \(events)")
        try append([reportPrompt(agentA, toolUseId: "toolu_bgA", at: "2026-10-22T02:17:02.163Z")],
                   to: file)
        scan()
        try expectEqual(store.sortedActiveTasks.first?.awaitingBackgroundTasks, 0)
        try append([endTurn("2026-10-22T02:17:16.000Z", text: "A 组回来了")], to: file)
        scan()
        try expectEqual(finishes(), [], "\(events)")
        try expect(events.contains { $0.kind == .awaitingBackgroundTasks(count: 1) }, "\(events)")
        try expectEqual(cards(), 0, "还有后台任务时不出完成卡")

        // Agent B reports and its turn ends: now the job is done
        try append([
            enqueue(agentB, toolUseId: "toolu_bgB", at: "2026-10-22T02:17:52.873Z"),
            reportPrompt(agentB, toolUseId: "toolu_bgB", at: "2026-10-22T02:17:52.956Z"),
            endTurn("2026-10-22T02:18:42.000Z", text: "两组都比对完了"),
        ], to: file)
        scan()
        try expectEqual(finishes(), [.success], "\(events)")
        try expectEqual(cards(), 1, "整件事只出一张卡: \(effects)")
        guard case .taskFinished(let finished)? = effects.last(where: {
            if case .taskFinished = $0 { return true } else { return false }
        }) else { throw ExpectationError(description: "缺完成卡") }
        try expectEqual(finished.startedAt,
                        ISO8601DateFormatter().date(from: "2026-10-22T02:00:00Z"),
                        "计时从用户的 prompt 起算")
        try expectEqual(finished.finishedAt,
                        ISO8601DateFormatter().date(from: "2026-10-22T02:18:42Z"))
    }

    t.test("监视器：等待后台任务时进程退出 → 不补成功收尾，会话结束判中断") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root, liveResumedSessionIds: { [] }) {
            event, _ in events.append(event)
        }
        let store = TaskStore()
        watcher.scanOnce()
        try append([
            endTurn("2026-10-22T02:01:50.000Z"),
            line(["type": "cost-state", "totalCostUSD": 0.4]),
        ], to: file)
        watcher.scanOnce()
        let effects = events.flatMap { store.apply($0) }
        let outcomes = effects.compactMap { effect -> TaskOutcome? in
            if case .taskFinished(let finished) = effect { return finished.outcome } else { return nil }
        }
        try expectEqual(outcomes, [.interrupted], "\(events)")
        try expect(store.activeTasks.isEmpty)
    }

    t.test("进程退出清空后台任务：续开后的 turn 收尾不再等待上一个进程留下的 agent") {
        let tasks = observeAll([launch("ag1"), line(["type": "cost-state"])])
        try expectEqual(tasks.pendingCount, 0)
        try expectEqual(tasks.abandonedAtExit, 1)

        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try append([
            endTurn("2026-10-22T02:01:50.000Z"),
            line(["type": "cost-state", "totalCostUSD": 0.4]),
        ], to: file)
        var snapshot = ClaudeSessionBootstrap.classify(fileURL: file)
        try expectEqual(snapshot?.abandonedBackgroundTasks, 2)
        try expectEqual(snapshot?.awaitingBackgroundTasks, 0)

        try append([
            line(["type": "cost-state", "totalCostUSD": 0.4]),
            line(["type": "user", "isSidechain": false, "uuid": "u-resume",
                  "timestamp": "2026-10-22T05:00:00.000Z",
                  "message": ["role": "user", "content": "继续"] as [String: Any]]),
            endTurn("2026-10-22T05:00:30.000Z"),
        ], to: file)
        snapshot = ClaudeSessionBootstrap.classify(fileURL: file)
        try expectEqual(snapshot?.running, false)
        try expectEqual(snapshot?.awaitingBackgroundTasks, 0)
        try expectEqual(snapshot?.abandonedBackgroundTasks, 0)
    }

    t.test("Stop hook：还有后台 agent 未回报 → 转为等待并带上会话名；全部回报后才是完成") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        try append([endTurn("2026-10-22T02:01:50.000Z")], to: file)
        let stop = TaskEvent(
            source: .claude, sessionId: sessionId,
            kind: .taskFinished(outcome: .success, title: nil, detail: nil),
            timestamp: Date(), transcriptPath: file.path)
        try expectEqual(EventPipeline.enrichClaudeFinish(stop).map(\.kind), [
            .titleUpdate(title: "复核归因"),
            .awaitingBackgroundTasks(count: 2),
        ])

        try append([
            reportPrompt(agentA, toolUseId: "toolu_bgA", at: "2026-10-22T02:17:02.163Z"),
            endTurn("2026-10-22T02:17:16.000Z"),
            reportPrompt(agentB, toolUseId: "toolu_bgB", at: "2026-10-22T02:17:52.956Z"),
            endTurn("2026-10-22T02:18:42.000Z"),
        ], to: file)
        try expectEqual(EventPipeline.enrichClaudeFinish(stop).map(\.kind), [
            .taskFinished(outcome: .success, title: "复核归因", detail: nil),
        ])
    }

    t.test("子 agent：后台 agent 的启动回执不算完成，回报到了才算（非 completed → 失败）") {
        let (root, file) = try makeSession()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDir = file.deletingPathExtension()
        let subagents = sessionDir.appendingPathComponent("subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagents, withIntermediateDirectories: true)
        for (id, toolUseId) in [(agentA, "toolu_bgA"), (agentB, "toolu_bgB")] {
            try Data(#"{"agentType":"general-purpose","description":"Re-attribute","toolUseId":"\#(toolUseId)"}"#.utf8)
                .write(to: subagents.appendingPathComponent("agent-\(id).meta.json"))
        }
        func statuses() -> [SubagentInfo.Status] {
            ClaudeSubagentScanner.scan(sessionDir: sessionDir, parentTranscript: file)
                .sorted { $0.agentId < $1.agentId }.map(\.status)
        }
        try expectEqual(statuses(), [.running, .running])

        try append([
            endTurn("2026-10-22T02:01:50.000Z"),
            reportPrompt(agentA, toolUseId: "toolu_bgA", at: "2026-10-22T02:17:02.163Z"),
            reportPrompt(agentB, toolUseId: "toolu_bgB", at: "2026-10-22T02:17:52.956Z",
                         status: "killed"),
        ], to: file)
        try expectEqual(statuses(), [.completed, .failed])
    }
}
