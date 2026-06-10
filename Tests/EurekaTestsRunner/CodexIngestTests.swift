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
        guard case .taskFinished(outcome: .success, _, let detail) = kinds[1] else {
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
