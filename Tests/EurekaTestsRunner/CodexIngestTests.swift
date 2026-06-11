import EurekaIngest
import EurekaInstall
import EurekaKit
import Foundation

func codexNotifyInstallerTests(_ t: TestRunner) {
    t.suite("CodexNotifyInstaller")
    let relay = "/Users/me/Library/Application Support/Eureka/bin/eureka-relay"

    t.test("notify 插在首个 [table] 之前（核心回归）") {
        let original = try fixtureString("configs/config-with-tables.toml")
        let result = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        let lines = result.components(separatedBy: "\n")
        let notifyIndex = lines.firstIndex { $0.hasPrefix("notify = ") }
        let firstTableIndex = lines.firstIndex { $0.hasPrefix("[") }
        try expect(notifyIndex != nil && firstTableIndex != nil)
        try expect(notifyIndex! < firstTableIndex!, "notify 必须在首个 table 之前")
        // 原有内容逐行保留
        for line in ["model = \"gpt-5.5\"", "[mcp_servers.notion]", "[apps.example]", "key = \"value\""] {
            try expect(result.contains(line), "应保留: \(line)")
        }
    }

    t.test("空文件安装 / 卸载还原") {
        let installed = try CodexNotifyInstaller.install(into: "", relayPath: relay)
        try expectEqual(installed, "notify = [\"\(relay)\", \"codex-notify\"]\n")
        try expectEqual(CodexNotifyInstaller.status(of: installed), .installed)
    }

    t.test("幂等重装（路径更新）") {
        let v1 = try CodexNotifyInstaller.install(into: "", relayPath: "/old/eureka-relay")
        let v2 = try CodexNotifyInstaller.install(into: v1, relayPath: relay)
        try expect(v2.contains(relay))
        try expectEqual(v2.components(separatedBy: "notify =").count, 2, "只能有一行 notify")
    }

    t.test("他人 notify 拒绝覆盖") {
        let original = try fixtureString("configs/config-with-foreign-notify.toml")
        try expectEqual(CodexNotifyInstaller.status(of: original), .foreign)
        do {
            _ = try CodexNotifyInstaller.install(into: original, relayPath: relay)
            throw ExpectationError(description: "应抛 foreignConfig")
        } catch InstallError.foreignConfig {}
    }

    t.test("安装后卸载恢复原文") {
        let original = try fixtureString("configs/config-with-tables.toml")
        let installed = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        let restored = CodexNotifyInstaller.uninstall(from: installed)
        try expectEqual(restored, original)
        try expectEqual(CodexNotifyInstaller.status(of: restored), InstallStatus.none)
    }

    t.test("table 内的 notify 字样不被误认") {
        let toml = "model = \"gpt-5.5\"\n\n[apps.example]\nnotify = [\"other\"]\n"
        try expectEqual(CodexNotifyInstaller.status(of: toml), InstallStatus.none)
        let installed = try CodexNotifyInstaller.install(into: toml, relayPath: relay)
        let lines = installed.components(separatedBy: "\n")
        try expect(lines[1].hasPrefix("notify = ") || lines[2].hasPrefix("notify = "),
                   "应插入顶层而不是动 table 内的")
        try expect(installed.contains("notify = [\"other\"]"), "table 内的原样保留")
    }
}

func codexRolloutTests(_ t: TestRunner) {
    t.suite("CodexRolloutTailer")

    /// 在临时 sessions 树（今天的日期目录）里建一个 rollout 文件
    struct Spool {
        let root: URL
        let file: URL
    }
    func makeSessions() throws -> Spool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-codex-\(UUID().uuidString)", isDirectory: true)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent(
            "rollout-2026-06-09T12-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0001.jsonl")
        return Spool(root: root, file: file)
    }

    /// fixture 行集（lifecycle 文件）按行号取
    let lifecycleLines = try! fixtureString("codex-rollout-lifecycle.jsonl")
        .components(separatedBy: "\n").filter { !$0.isEmpty }

    func append(_ lines: [String], to url: URL) throws {
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

    t.test("初见文件恢复进行中状态；增量追加产出完整生命周期") {
        let spool = try makeSessions()
        var events: [(TaskEvent, Bool)] = []
        var snapshots: [RateLimitSnapshot] = []
        let tailer = CodexRolloutTailer(
            sessionsRoot: spool.root,
            rateLimitHandler: { snapshots.append($0) },
            handler: { events.append(($0, $1)) }
        )

        // 初见：session_meta + task_started → 恢复 running（不受 stale 抑制）
        try append(Array(lifecycleLines[0...1]), to: spool.file)
        tailer.scanOnce()
        try expectEqual(events.count, 1)
        guard case .taskStarted = events[0].0.kind else {
            throw ExpectationError(description: "初见应恢复 running: \(events[0].0.kind)")
        }
        try expectEqual(events[0].0.sessionId, "fixture-codex-1")
        try expectEqual(events[0].0.turnId, "turn-001")
        try expect(events[0].1 == false, "恢复的 running 不该标 stale")
        // started_at 来自 epoch 字段
        try expectEqual(events[0].0.timestamp, Date(timeIntervalSince1970: 1_781_006_401))

        // 追加 user_message + token_count + agent_message + task_complete
        events.removeAll()
        try append(Array(lifecycleLines[2...5]), to: spool.file)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        guard case .taskStarted(title: "跑一下集成测试并修复失败用例") = kinds[0] else {
            throw ExpectationError(description: "user_message 应补标题: \(kinds[0])")
        }
        // token_count 应产出上下文占用：19629 / 258400 ≈ 7.6%
        guard case .contextUpdate(let percent) = kinds[1] else {
            throw ExpectationError(description: "应有 contextUpdate: \(kinds)")
        }
        try expect(abs(percent - 7.596) < 0.01, "context \(percent)")
        guard case .taskFinished(outcome: .success, _, let detail) = kinds[2] else {
            throw ExpectationError(description: "应有 task_complete: \(kinds)")
        }
        try expect(detail?.contains("集成测试全部通过") == true)
        try expectEqual(snapshots.count, 1, "token_count 应转发限额快照")
        try expectEqual(snapshots[0].primary?.usedPercent, 1.0)
        try expectEqual(snapshots[0].secondary?.windowMinutes, 10080)
        try expectEqual(snapshots[0].planType, "plus")

        // 追加 turn-002 start + abort
        events.removeAll()
        try append(Array(lifecycleLines[6...7]), to: spool.file)
        tailer.scanOnce()
        guard case .taskFinished(outcome: .interrupted, _, _) = events.last!.0.kind else {
            throw ExpectationError(description: "turn_aborted 应判中断")
        }
    }

    t.test("半行不消费，补全后产出") {
        let spool = try makeSessions()
        var events: [(TaskEvent, Bool)] = []
        let tailer = CodexRolloutTailer(sessionsRoot: spool.root) { events.append(($0, $1)) }

        try append([lifecycleLines[0]], to: spool.file)
        tailer.scanOnce()  // 初见

        // 写半行（无换行符）
        let half = lifecycleLines[1]
        let mid = half.index(half.startIndex, offsetBy: half.count / 2)
        let handle = try FileHandle(forWritingTo: spool.file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(String(half[..<mid]).utf8))
        try handle.close()
        tailer.scanOnce()
        try expect(events.isEmpty, "半行不该产出事件")

        let handle2 = try FileHandle(forWritingTo: spool.file)
        _ = try handle2.seekToEnd()
        try handle2.write(contentsOf: Data((String(half[mid...]) + "\n").utf8))
        try handle2.close()
        tailer.scanOnce()
        try expectEqual(events.count, 1)
        guard case .taskStarted = events[0].0.kind else {
            throw ExpectationError(description: "补全后应产出 task_started")
        }
    }
}

func contextEstimatorTests(_ t: TestRunner) {
    t.suite("ClaudeContextEstimator")

    t.test("取最近主链 assistant 的输入侧 token，按模型窗口（fable=1M）折算") {
        let percent = ClaudeContextEstimator.estimate(
            transcriptPath: try fixtureURL("claude-transcript-usage-dups.jsonl").path)
        // 最后主链 assistant = msg_01BBB（claude-fable-5，1M 窗口）：
        // 3400 + 8000 cache_read = 11400 / 1_000_000 = 1.14%
        // （末尾的 sidechain haiku 行应被跳过）
        try expect(percent != nil)
        try expect(abs(percent! - 1.14) < 0.01, "got \(percent!)")
    }

    t.test("ContextWindows：前缀匹配 + 覆盖优先 + 默认 200k") {
        try expectEqual(ContextWindows.window(forModel: "claude-fable-5"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "claude-haiku-4-5"), 200_000)
        try expectEqual(ContextWindows.window(forModel: nil), 200_000)
        ContextWindows.overrides = ["claude-opus-4-8": 1_000_000]
        defer { ContextWindows.overrides = [:] }
        try expectEqual(ContextWindows.window(forModel: "claude-opus-4-8"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "claude-opus-4-1"), 200_000)
    }

    t.test("synthetic 错误行（usage 全零）不参与估算") {
        let percent = ClaudeContextEstimator.estimate(
            transcriptPath: try fixtureURL("claude-transcript-api-error.jsonl").path)
        try expect(percent == nil, "全零行应跳过：\(String(describing: percent))")
    }
}

func sessionBootstrapTests(_ t: TestRunner) {
    t.suite("ClaudeSessionBootstrap")
    let mtime = Date()

    t.test("最后 prompt 之后无结束标记 → 重建为运行中（含标题/上下文）") {
        let events = ClaudeSessionBootstrap.inspectSession(
            fileURL: try fixtureURL("claude-transcript-running.jsonl"), mtime: mtime)
        guard case .taskStarted(let title) = events.first?.kind else {
            throw ExpectationError(description: "应为 taskStarted: \(events)")
        }
        try expectEqual(title, "重构数据管道的增量加载逻辑")
        try expectEqual(events.first?.sessionId, "fixture-running-1")
        // startedAt 用真实 prompt 时间（10:00:00Z），计时准确
        try expectEqual(
            events.first?.timestamp,
            ISO8601DateFormatter().date(from: "2026-06-09T10:00:00Z"))
        // tool_result（content 为数组的 user 行）不算新 prompt
        let kinds = events.map(\.kind)
        try expect(kinds.contains(.titleUpdate(title: "重构数据管道增量加载")), "ai-title 应跟上")
        try expect(kinds.contains { if case .contextUpdate = $0 { return true } else { return false } })
    }

    t.test("turn_duration 在 prompt 之后 → 重建为空闲") {
        let events = ClaudeSessionBootstrap.inspectSession(
            fileURL: try fixtureURL("claude-transcript-usage-dups.jsonl"), mtime: mtime)
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "应为 sessionStarted（空闲）: \(events)")
        }
    }

    t.test("API 错误行视为 turn 结束 → 空闲而非幽灵运行") {
        let events = ClaudeSessionBootstrap.inspectSession(
            fileURL: try fixtureURL("claude-transcript-api-error.jsonl"), mtime: mtime)
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "错误终止的 turn 不该判运行: \(events)")
        }
    }

    t.test("超长 turn 中段：尾窗只有执行痕迹（无 prompt 无结束标记）→ 判运行") {
        // 模拟巨型 turn 的尾窗：只有 assistant + tool_result，prompt 早已滚出
        let lines = """
        {"type":"assistant","isSidechain":false,"uuid":"u-m1","timestamp":"2026-06-09T12:30:00.000Z","message":{"id":"msg_M1","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":4000,"output_tokens":300,"cache_creation_input_tokens":0,"cache_read_input_tokens":170000,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}},"sessionId":"fixture-midturn-1","cwd":"/Users/me/work/big"}
        {"type":"user","isMeta":false,"uuid":"u-m2","timestamp":"2026-06-09T12:30:05.000Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"sessionId":"fixture-midturn-1","cwd":"/Users/me/work/big"}

        """
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("midturn-\(UUID().uuidString).jsonl")
        try Data(lines.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let events = ClaudeSessionBootstrap.inspectSession(fileURL: tmp, mtime: mtime)
        guard case .taskStarted = events.first?.kind else {
            throw ExpectationError(description: "应判运行中: \(events)")
        }
        // startedAt 用尾窗最早时间戳兜底（至少不低估时长）
        try expectEqual(
            events.first?.timestamp,
            ISO8601DateFormatter().date(from: "2026-06-09T12:30:00Z"))
        try expectEqual(events.first?.sessionId, "fixture-midturn-1")
    }
}

func transcriptWatcherTests(_ t: TestRunner) {
    t.suite("ClaudeTranscriptWatcher")

    t.test("无 hooks 会话全生命周期：发现运行 → 收尾完成（只一次）") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-watch-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-pipeline")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s1.jsonl")
        try FileManager.default.copyItem(
            at: fixtureURL("claude-transcript-running.jsonl"), to: file)
        // copyItem 保留源 mtime（可能很旧）→ 刷成现在，落进活跃窗
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)

        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root) { event, _ in
            events.append(event)
        }

        watcher.scanOnce()
        guard case .taskStarted(let title) = events.first?.kind else {
            throw ExpectationError(description: "首扫应发现运行中: \(events)")
        }
        try expectEqual(title, "重构数据管道的增量加载逻辑")

        // 追加 turn 结束标记（mtime 强制前移，文件系统秒级粒度防 flake）
        events.removeAll()
        let endLine = """
        {"type":"system","subtype":"turn_duration","durationMs":30000,"timestamp":"2026-06-09T10:00:30.000Z","uuid":"u-2009","sessionId":"fixture-running-1","cwd":"/Users/me/work/pipeline"}

        """
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(endLine.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)

        watcher.scanOnce()
        let finishes = events.filter {
            if case .taskFinished = $0.kind { return true } else { return false }
        }
        try expectEqual(finishes.count, 1, "收尾应产出恰好一次完成: \(events)")

        // 无新写入：不再产出
        events.removeAll()
        watcher.scanOnce()
        try expect(events.isEmpty, "无变化不该有事件: \(events)")
    }

    t.test("空闲会话首见登记 sessionStarted") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-watch-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let idleFile = dir.appendingPathComponent("s2.jsonl")
        try FileManager.default.copyItem(
            at: fixtureURL("claude-transcript-usage-dups.jsonl"), to: idleFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: idleFile.path)

        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root) { event, _ in
            events.append(event)
        }
        watcher.scanOnce()
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "应登记空闲: \(events)")
        }
        try expect(events.contains {
            $0.kind == .titleUpdate(title: "修复登录页 Safari 兼容性报错")
        }, "ai-title 应跟上")
    }
}

func sessionIndexerTests(_ t: TestRunner) {
    t.suite("ClaudeSessionIndexer")

    t.test("索引：ai-title 命名优先，缺则退首条 prompt；时间窗过滤") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-index-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default

        // 有 ai-title 的会话
        let withTitle = dir.appendingPathComponent("aaaa-1111.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-usage-dups.jsonl"), to: withTitle)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-100)], ofItemAtPath: withTitle.path)

        // 只有 prompt 的会话（更新）
        let promptOnly = dir.appendingPathComponent("bbbb-2222.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-api-error.jsonl"), to: promptOnly)
        try fm.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: promptOnly.path)

        // 窗口外的老会话
        let ancient = dir.appendingPathComponent("cccc-3333.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-running.jsonl"), to: ancient)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86400)],
            ofItemAtPath: ancient.path)

        let sessions = ClaudeSessionIndexer.index(projectsRoot: root)
        try expectEqual(sessions.count, 2, "窗口外的不索引: \(sessions.map(\.id))")
        // 默认按 mtime 倒序
        try expectEqual(sessions[0].id, "bbbb-2222")
        try expectEqual(sessions[0].name, "继续重构数据管道")
        try expectEqual(sessions[1].name, "修复登录页 Safari 兼容性报错")
        try expectEqual(sessions[1].cwd, "/Users/me/work/demo")
        try expect(sessions[0].sizeBytes > 0)
        try expectEqual(sessions[0].source, .claude)
    }

    t.test("Codex 会话索引：session_meta 取 id/cwd，首条 user_message 命名") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cxidx-\(UUID().uuidString)", isDirectory: true)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent(
            "rollout-2026-06-11T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0002.jsonl")
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-lifecycle.jsonl"), to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)

        let sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].source, .codex)
        try expectEqual(sessions[0].id, "fixture-codex-1")
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expectEqual(sessions[0].name, "跑一下集成测试并修复失败用例")
    }
}

func errorSnifferTests(_ t: TestRunner) {
    t.suite("ClaudeErrorSniffer")

    t.test("API 错误行 → 出错 + 错误详情") {
        let findings = ClaudeErrorSniffer.sniff(
            transcriptPath: try fixtureURL("claude-transcript-api-error.jsonl").path)
        try expectEqual(findings.isError, true)
        try expect(findings.errorDetail?.contains("API Error: 403") == true)
    }

    t.test("正常 transcript → 不报错 + 取 ai-title") {
        let findings = ClaudeErrorSniffer.sniff(
            transcriptPath: try fixtureURL("claude-transcript-usage-dups.jsonl").path)
        try expectEqual(findings.isError, false)
        try expectEqual(findings.aiTitle, "修复登录页 Safari 兼容性报错")
    }

    t.test("文件不存在 → 安静返回默认") {
        let findings = ClaudeErrorSniffer.sniff(transcriptPath: "/nonexistent/x.jsonl")
        try expectEqual(findings, ClaudeErrorSniffer.Findings())
    }
}

func deduplicatorTests(_ t: TestRunner) {
    t.suite("EventDeduplicator")

    t.test("codex 同 turn 完成事件去重；claude 不受影响") {
        let dedup = EventDeduplicator()
        let codexFinish = TaskEvent(
            source: .codex, sessionId: "s", kind: .taskFinished(outcome: .success, title: nil, detail: nil),
            timestamp: Date(), turnId: "t1")
        try expectEqual(dedup.isDuplicate(codexFinish), false)
        try expect(dedup.isDuplicate(codexFinish) == true, "同 turn 第二次应判重")

        let differentTurn = TaskEvent(
            source: .codex, sessionId: "s", kind: .taskFinished(outcome: .success, title: nil, detail: nil),
            timestamp: Date(), turnId: "t2")
        try expectEqual(dedup.isDuplicate(differentTurn), false)

        let claude = TaskEvent(
            source: .claude, sessionId: "s", kind: .taskFinished(outcome: .success, title: nil, detail: nil),
            timestamp: Date())
        try expectEqual(dedup.isDuplicate(claude), false)
        try expectEqual(dedup.isDuplicate(claude), false, "claude 单通道不去重")
    }
}
