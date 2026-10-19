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
        // Existing content is preserved line by line
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

    t.test("他人 notify → 串联：原 argv 原样排在 --chain 之后") {
        let original = try fixtureString("configs/config-with-foreign-notify.toml")
        try expectEqual(CodexNotifyInstaller.status(of: original), .foreign)
        let installed = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        try expect(installed.contains(
            "notify = [\"\(relay)\", \"codex-notify\", \"--chain\", "
                + "\"terminal-notifier\", \"-title\", \"Codex\"]"), installed)
        try expectEqual(installed.components(separatedBy: "notify =").count, 2, "只能有一行 notify")
        try expectEqual(CodexNotifyInstaller.status(of: installed), .installed)
        try expectEqual(
            CodexNotifyInstaller.chainedCommand(in: installed),
            ["terminal-notifier", "-title", "Codex"])
    }

    t.test("串联后卸载：逐字恢复他人的 notify") {
        let original = try fixtureString("configs/config-with-foreign-notify.toml")
        let installed = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        try expectEqual(CodexNotifyInstaller.uninstall(from: installed), original)
    }

    t.test("串联后重装（换路径 / 旧名迁移）保留被串联的命令，不重复包裹") {
        let original = try fixtureString("configs/config-with-foreign-notify.toml")
        let v1 = try CodexNotifyInstaller.install(into: original, relayPath: "/old/eureka-relay")
        let v2 = try CodexNotifyInstaller.install(into: v1, relayPath: relay)
        let v3 = try CodexNotifyInstaller.install(into: v2, relayPath: relay)
        try expectEqual(v2, v3, "幂等")
        try expectEqual(v3.components(separatedBy: "--chain").count, 2, "只包一层")
        try expect(!v3.contains("/old/eureka-relay"))
        try expectEqual(CodexNotifyInstaller.uninstall(from: v3), original)
    }

    t.test("真实形态：Computer Use 占用的 notify（路径含空格）可串联并还原") {
        let client = "/Users/me/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/"
            + "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        let original = "model = \"gpt-5.5\"\nnotify = [\"\(client)\", \"turn-ended\"]\n\n[tui]\n"
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: original, expectedRelayPath: relay, relayIsExecutable: { _ in true }),
            .chainable(owner: "SkyComputerUseClient"))
        let installed = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        try expectEqual(CodexNotifyInstaller.chainedCommand(in: installed), [client, "turn-ended"])
        try expectEqual(
            CodexNotifyInstaller.diagnose(
                toml: installed, expectedRelayPath: relay, relayIsExecutable: { _ in true }),
            .installed)
        try expectEqual(CodexNotifyInstaller.uninstall(from: installed), original)
    }

    t.test("他人 notify 带行尾注释 / 单引号字面量也能串联") {
        let original = "notify = ['C:\\raw\\tool', \"a\\\"b\"]  # mine\n"
        let installed = try CodexNotifyInstaller.install(into: original, relayPath: relay)
        try expectEqual(CodexNotifyInstaller.chainedCommand(in: installed), ["C:\\raw\\tool", "a\"b"])
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

    t.test("TOMLStringArray：解析与渲染往返") {
        try expectEqual(TOMLStringArray.parse("[]"), [])
        try expectEqual(TOMLStringArray.parse(" [\"a\", 'b' ,] "), ["a", "b"])
        try expectEqual(TOMLStringArray.parse("[\"\\u00e9\\t\\n\"]"), ["é\t\n"])
        let tricky = ["/path with space/x", "quote\"inside", "back\\slash", "tab\tnl\n", "\u{01}"]
        try expectEqual(TOMLStringArray.parse(TOMLStringArray.render(tricky)), tricky)
    }

    t.test("TOMLStringArray：子集之外一律 nil（调用方据此拒绝改写）") {
        for bad in [
            "[\"a\",",            // unclosed across lines
            "[\"a\", 1]",         // non-string element
            "[\"\"\"multi\"\"\"]",  // multi-line string
            "[\"a\"] trailing",   // trailing garbage
            "\"a\"",              // not an array
            "[\"bad\\q\"]",     // invalid escape
        ] {
            try expect(TOMLStringArray.parse(bad) == nil, "应拒绝: \(bad)")
        }
    }
}

func codexRolloutTests(_ t: TestRunner) {
    t.suite("CodexRolloutTailer")

    /// Creates a rollout file in a temporary sessions tree (today's date directory)
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

    /// Fixture lines (lifecycle file), indexed by line number
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

    func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
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

        // First sight: session_meta + task_started → restore running (not subject to stale
        // suppression)
        try append(Array(lifecycleLines[0...1]), to: spool.file)
        tailer.scanOnce()
        try expectEqual(events.count, 1)
        guard case .taskStarted = events[0].0.kind else {
            throw ExpectationError(description: "初见应恢复 running: \(events[0].0.kind)")
        }
        try expectEqual(events[0].0.sessionId, "fixture-codex-1")
        try expectEqual(events[0].0.turnId, "turn-001")
        try expect(events[0].1 == false, "恢复的 running 不该标 stale")
        // started_at comes from the epoch field
        try expectEqual(events[0].0.timestamp, Date(timeIntervalSince1970: 1_781_006_401))

        // Append user_message + token_count + agent_message + task_complete
        events.removeAll()
        try append(Array(lifecycleLines[2...5]), to: spool.file)
        tailer.scanOnce()
        let kinds = events.map(\.0.kind)
        guard case .taskStarted(title: "跑一下集成测试并修复失败用例") = kinds[0] else {
            throw ExpectationError(description: "user_message 应补标题: \(kinds[0])")
        }
        // token_count should yield context usage: 19629 / 258400 ≈ 7.6%
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

        // Append turn-002 start + abort
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
        tailer.scanOnce()  // first sight

        // Write half a line (no newline)
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

    t.test("超长 session_meta 不截断；session_index 正式标题优先并实时更新") {
        let spool = try makeSessions()
        let indexURL = spool.root.appendingPathComponent("session_index.jsonl")
        let sessionId = "codex-large-meta"
        let meta = try jsonLine([
            "timestamp": "2026-07-21T08:00:00.000Z",
            "type": "session_meta",
            "payload": [
                "id": sessionId,
                "timestamp": "2026-07-21T07:59:59.000Z",
                "cwd": "/Users/me/work/large",
                "base_instructions": String(repeating: "x", count: 128 * 1024),
            ],
        ])
        let started = try jsonLine([
            "timestamp": "2026-07-21T08:00:01.000Z",
            "type": "event_msg",
            "payload": ["type": "task_started", "turn_id": "turn-large"],
        ])
        let prompt = try jsonLine([
            "timestamp": "2026-07-21T08:00:02.000Z",
            "type": "event_msg",
            "payload": ["type": "user_message", "message": "这不是最终标题"],
        ])
        try append([meta, started, prompt], to: spool.file)
        try append([
            try jsonLine(["id": sessionId, "thread_name": "修复 Codex 会话标题"]),
        ], to: indexURL)

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodexRolloutTailer(
            sessionsRoot: spool.root, sessionIndexURL: indexURL
        ) { events.append(($0, $1)) }
        tailer.scanOnce()

        try expectEqual(events.count, 1)
        try expectEqual(events[0].0.sessionId, sessionId)
        try expectEqual(events[0].0.cwd, "/Users/me/work/large")
        try expectEqual(
            events[0].0.sessionStartedAt,
            ISO8601DateFormatter().date(from: "2026-07-21T07:59:59Z"))
        guard case .taskStarted(title: "修复 Codex 会话标题") = events[0].0.kind else {
            throw ExpectationError(description: "正式线程名应覆盖 prompt 摘要: \(events)")
        }

        events.removeAll()
        try append([
            try jsonLine(["id": sessionId, "thread_name": "Codex 标题已更新"]),
        ], to: indexURL)
        tailer.scanOnce()
        try expect(events.contains {
            $0.0.kind == .titleUpdate(title: "Codex 标题已更新")
                && $0.0.sessionId == sessionId
        }, "session_index 追加的新标题应实时送达")
    }

    t.test("session_index 指纹未变时跳过重解析，变化后仍实时更新") {
        let spool = try makeSessions()
        let indexURL = spool.root.appendingPathComponent("session_index.jsonl")
        let sessionId = "codex-fingerprint"

        // Both titles have the same byte count, so size is unchanged after the overwrite
        try append([
            try jsonLine(["id": sessionId, "thread_name": "标题甲"]),
        ], to: indexURL)
        // setAttributes loses precision converting Date → nanoseconds; only whole-second timestamps
        // round-trip exactly
        let fixedMtime = Date(timeIntervalSince1970: 1_784_990_000)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedMtime], ofItemAtPath: indexURL.path)

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodexRolloutTailer(
            sessionsRoot: spool.root, sessionIndexURL: indexURL
        ) { events.append(($0, $1)) }
        tailer.scanOnce()  // first load establishes the baseline

        // Overwrite with same-size content and restore the same mtime: fingerprint unchanged → must
        // not reparse a new title
        try Data((try jsonLine(["id": sessionId, "thread_name": "标题乙"]) + "\n").utf8)
            .write(to: indexURL)
        try FileManager.default.setAttributes(
            [.modificationDate: fixedMtime], ofItemAtPath: indexURL.path)
        tailer.scanOnce()
        try expect(events.isEmpty, "指纹未变应跳过重解析，不该出现 titleUpdate: \(events)")

        // Actually append a line: size/mtime change → the new title should arrive live
        try append([
            try jsonLine(["id": sessionId, "thread_name": "标题丙"]),
        ], to: indexURL)
        tailer.scanOnce()
        try expect(events.contains {
            $0.0.kind == .titleUpdate(title: "标题丙") && $0.0.sessionId == sessionId
        }, "session_index 变化后新标题应实时送达: \(events)")
    }

    t.test("rollout 内 thread_name_updated 解码为正式标题事件") {
        let line = try jsonLine([
            "timestamp": "2026-07-21T08:00:03.000Z",
            "type": "event_msg",
            "payload": [
                "type": "thread_name_updated",
                "thread_id": "named-thread",
                "thread_name": "分析 Plan 与 Memory",
            ],
        ])
        let decoded = CodexRolloutDecoder.decode(
            line: Data(line.utf8), sessionId: "fallback", cwd: "/work")
        guard case .event(let event) = decoded.first,
              event.sessionId == "named-thread",
              event.kind == .titleUpdate(title: "分析 Plan 与 Memory") else {
            throw ExpectationError(description: "未解码 thread_name_updated: \(decoded)")
        }
    }

    t.test("resume 的旧会话（老日期目录 + 新 mtime）有实时事件流；冷历史不 tail") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-codex-resumed-\(UUID().uuidString)", isDirectory: true)
        let oldDayDir = root.appendingPathComponent("2025/01/01", isDirectory: true)
        try fm.createDirectory(at: oldDayDir, withIntermediateDirectories: true)

        // A resumed old session: its creation-day directory is old, but in-place appends make the
        // mtime recent
        let resumedFile = oldDayDir.appendingPathComponent(
            "rollout-2025-01-01T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0003.jsonl")
        try append(Array(lifecycleLines[0...1]), to: resumedFile)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: resumedFile.path)

        // Truly cold history: old directory + old mtime → outside recentWindow, must not be tailed
        let ancientDir = root.appendingPathComponent("2024/12/31", isDirectory: true)
        try fm.createDirectory(at: ancientDir, withIntermediateDirectories: true)
        let ancientFile = ancientDir.appendingPathComponent(
            "rollout-2024-12-31T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0004.jsonl")
        try append([
            try jsonLine([
                "timestamp": "2024-12-31T10:00:00.000Z", "type": "session_meta",
                "payload": ["id": "codex-ancient", "cwd": "/Users/me/work/old"],
            ]),
            try jsonLine([
                "timestamp": "2024-12-31T10:00:01.000Z", "type": "event_msg",
                "payload": ["type": "task_started", "turn_id": "turn-old"],
            ]),
        ], to: ancientFile)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-10 * 86400)],
            ofItemAtPath: ancientFile.path)

        var events: [(TaskEvent, Bool)] = []
        let tailer = CodexRolloutTailer(sessionsRoot: root) { events.append(($0, $1)) }

        // First sight: the resumed session in the old directory restores running; cold history
        // emits no events at all
        tailer.scanOnce()
        try expectEqual(events.count, 1, "只有 resume 会话应出事件: \(events)")
        try expectEqual(events[0].0.sessionId, "fixture-codex-1")
        guard case .taskStarted = events[0].0.kind else {
            throw ExpectationError(description: "resume 会话应恢复 running: \(events)")
        }

        // Incremental append: events keep flowing live (live monitoring covers old directories)
        events.removeAll()
        try append(Array(lifecycleLines[2...5]), to: resumedFile)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: resumedFile.path)
        tailer.scanOnce()
        try expect(events.contains {
            if case .taskFinished = $0.0.kind { return true } else { return false }
        }, "resume 会话的后续事件应实时送达: \(events.map(\.0.kind))")
        try expect(
            events.allSatisfy { $0.0.sessionId == "fixture-codex-1" },
            "冷历史文件不该产出任何事件: \(events)")
    }
}

func contextEstimatorTests(_ t: TestRunner) {
    t.suite("ClaudeContextEstimator")

    t.test("取最近主链 assistant 的输入侧 token，按模型窗口（fable=1M）折算") {
        let percent = ClaudeContextEstimator.estimate(
            transcriptPath: try fixtureURL("claude-transcript-usage-dups.jsonl").path)
        // Last main-chain assistant = msg_01BBB (claude-fable-5, 1M window):
        // 3400 + 8000 cache_read = 11400 / 1_000_000 = 1.14%
        // (the trailing sidechain haiku line should be skipped)
        try expect(percent != nil)
        try expect(abs(percent! - 1.14) < 0.01, "got \(percent!)")
    }

    t.test("ContextWindows：前缀匹配 + 覆盖优先 + 默认 200k") {
        try expectEqual(ContextWindows.window(forModel: "claude-fable-5"), 1_000_000)
        // Enterprise 1M as observed: opus-5 / opus-4-8 → 1M; older opus still uses the default
        try expectEqual(ContextWindows.window(forModel: "claude-opus-5"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "claude-opus-4-8"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "claude-opus-4-1"), 200_000)
        try expectEqual(ContextWindows.window(forModel: "claude-haiku-4-5"), 200_000)
        try expectEqual(ContextWindows.window(forModel: nil), 200_000)
        ContextWindows.overrides = ["claude-haiku-4-5": 500_000]
        defer { ContextWindows.overrides = [:] }
        try expectEqual(ContextWindows.window(forModel: "claude-haiku-4-5"), 500_000)
    }

    t.test("ContextWindows：gemini-2.5/3 → 1M；glm/qwen 刻意落默认 200k") {
        // Prefix match against the built-in table (no exact full name needed)
        try expectEqual(ContextWindows.window(forModel: "gemini-2.5-pro"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "gemini-2.5-flash"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "gemini-3-pro-preview"), 1_000_000)
        try expectEqual(ContextWindows.window(forModel: "gemini-3.5-flash"), 1_000_000)
        // Models without an official figure stay out of the table → default; ctx% errs on the
        // conservative side
        try expectEqual(ContextWindows.window(forModel: "glm-5.2"), 200_000)
        try expectEqual(ContextWindows.window(forModel: "qwen3.7-max"), 200_000)
        // Longest prefix wins: a longer user-override key wins, other prefixes still hit the
        // built-in table
        ContextWindows.overrides = ["gemini-3-pro": 500_000]
        defer { ContextWindows.overrides = [:] }
        try expectEqual(ContextWindows.window(forModel: "gemini-3-pro-preview"), 500_000)
        try expectEqual(ContextWindows.window(forModel: "gemini-3.5-flash"), 1_000_000)
        // percent semantics: used ÷ matched window
        try expectEqual(ContextWindows.percent(used: 250_000, model: "gemini-2.5-pro"), 25.0)
        try expectEqual(ContextWindows.percent(used: 250_000, model: "glm-5.2"), 125.0)
    }

    t.test("ContextWindows：kimi k3 → 1M，k3-256k / k2 系 → 256K（最长前缀优先）") {
        // Real model IDs seen in production (measured from usage_records): kimi-code/k3, kimi-k3,
        // k3 → 1M
        try expectEqual(ContextWindows.window(forModel: "kimi-code/k3"), 1_048_576)
        try expectEqual(ContextWindows.window(forModel: "kimi-k3"), 1_048_576)
        try expectEqual(ContextWindows.window(forModel: "k3"), 1_048_576)
        // 256K tier variants must beat the shorter prefix
        try expectEqual(ContextWindows.window(forModel: "kimi-code/k3-256k"), 262_144)
        try expectEqual(ContextWindows.window(forModel: "kimi-k3-256k"), 262_144)
        try expectEqual(ContextWindows.window(forModel: "k3-256k"), 262_144)
        // K2 family (including k2.7-code) is officially 256K
        try expectEqual(ContextWindows.window(forModel: "kimi-k2.7-code"), 262_144)
        try expectEqual(ContextWindows.window(forModel: "kimi-k2-thinking"), 262_144)
        // Subscription tier downgrades are handled by user overrides (overrides beat built-ins)
        ContextWindows.overrides = ["kimi-code/k3": 262_144]
        defer { ContextWindows.overrides = [:] }
        try expectEqual(ContextWindows.window(forModel: "kimi-code/k3"), 262_144)
        let pct = ContextWindows.percent(used: 500_000, model: "kimi-k3")
        try expect(abs(pct - 47.68) < 0.01, "got \(pct)")
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
        // startedAt uses the real prompt time (10:00:00Z), so timing is accurate
        try expectEqual(
            events.first?.timestamp,
            ISO8601DateFormatter().date(from: "2026-06-09T10:00:00Z"))
        // tool_result (user lines whose content is an array) does not count as a new prompt
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

    t.test("桌面端无 turn_duration：end_turn 的 assistant 行即 turn 结束 → 空闲") {
        let url = try fixtureURL("claude-transcript-desktop.jsonl")
        let snapshot = ClaudeSessionBootstrap.classify(fileURL: url)
        try expectEqual(snapshot?.running, false)
        try expectEqual(snapshot?.turnEndOutcome, .success)
        try expectEqual(
            snapshot?.turnEndAt, ISO8601DateFormatter().date(from: "2026-10-18T08:00:15Z"))
        let events = ClaudeSessionBootstrap.inspectSession(fileURL: url, mtime: mtime)
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "应为 sessionStarted（空闲）: \(events)")
        }
    }

    t.test("任务名剥掉注入块：后台任务回报只剩标签 → nil（沿用会话旧标题）") {
        guard var snapshot = ClaudeSessionBootstrap.classify(
            fileURL: try fixtureURL("claude-transcript-desktop.jsonl"))
        else { throw ExpectationError(description: "fixture 应能分类") }
        try expectEqual(snapshot.promptTitle, "检查登录页的报错")
        snapshot.promptText = "<task-notification>\n<task-id>b1</task-id>\n</task-notification>"
        try expectEqual(snapshot.promptTitle, nil)
    }

    t.test("用户中断行视为 turn 结束，结局为中断") {
        let snapshot = ClaudeSessionBootstrap.classify(
            fileURL: try fixtureURL("claude-transcript-interrupted.jsonl"))
        try expectEqual(snapshot?.running, false)
        try expectEqual(snapshot?.turnEndOutcome, .interrupted)
    }

    t.test("API 错误行视为 turn 结束 → 空闲而非幽灵运行") {
        let events = ClaudeSessionBootstrap.inspectSession(
            fileURL: try fixtureURL("claude-transcript-api-error.jsonl"), mtime: mtime)
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "错误终止的 turn 不该判运行: \(events)")
        }
    }

    t.test("超长 turn 中段：尾窗只有执行痕迹（无 prompt 无结束标记）→ 判运行") {
        // Simulate the tail window of a huge turn: only assistant + tool_result, the prompt
        // scrolled out long ago
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
        // startedAt falls back to the earliest timestamp in the tail window (at least it doesn't
        // underestimate duration)
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
        // copyItem keeps the source mtime (possibly very old) → bump it to now so it lands in the
        // active window
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

        // Append the turn-end marker (mtime forced forward; the filesystem's one-second granularity
        // would otherwise make this flaky)
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

        // No new writes: nothing more is emitted
        events.removeAll()
        watcher.scanOnce()
        try expect(events.isEmpty, "无变化不该有事件: \(events)")
    }

    /// Copies the fixture to projects/<project>/<session>.jsonl and bumps its mtime to now
    func makeSession(_ fixture: String) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-watch-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-web")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s.jsonl")
        try FileManager.default.copyItem(at: fixtureURL(fixture), to: file)
        try FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: file.path)
        return (root, file)
    }

    /// Appends lines and moves the mtime forward (guards against flakes from second-granularity
    /// filesystem timestamps)
    func append(_ lines: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(lines.utf8))
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)], ofItemAtPath: file.path)
    }

    func finishes(_ events: [TaskEvent]) -> [TaskOutcome] {
        events.compactMap {
            if case .taskFinished(let outcome, _, _) = $0.kind { return outcome } else { return nil }
        }
    }

    t.test("桌面端会话：运行中追加 end_turn 行 → 恰好一次成功完成") {
        let (root, file) = try makeSession("claude-transcript-running.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root) { event, _ in
            events.append(event)
        }
        watcher.scanOnce()
        guard case .taskStarted = events.first?.kind else {
            throw ExpectationError(description: "首扫应发现运行中: \(events)")
        }

        events.removeAll()
        try append("""
        {"parentUuid":"u-2008","isSidechain":false,"type":"assistant","uuid":"u-2010","timestamp":"2026-06-09T10:00:40.000Z","message":{"id":"msg_RUN9","model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","type":"message","content":[{"type":"text","text":"改好了。"}]},"sessionId":"fixture-running-1","cwd":"/Users/me/work/pipeline"}

        """, to: file)
        watcher.scanOnce()
        try expectEqual(finishes(events), [.success], "收尾应产出恰好一次完成: \(events)")
        try expectEqual(
            events.first { if case .taskFinished = $0.kind { return true } else { return false } }?
                .timestamp,
            ISO8601DateFormatter().date(from: "2026-06-09T10:00:40Z"),
            "完成时间取 end_turn 行时间")
    }

    t.test("运行中追加用户中断行 → 完成结局为中断") {
        let (root, file) = try makeSession("claude-transcript-running.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root) { event, _ in
            events.append(event)
        }
        watcher.scanOnce()
        events.removeAll()
        try append("""
        {"parentUuid":"u-2008","isSidechain":false,"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"uuid":"u-2011","timestamp":"2026-06-09T10:00:45.000Z","sessionId":"fixture-running-1","cwd":"/Users/me/work/pipeline"}

        """, to: file)
        watcher.scanOnce()
        try expectEqual(finishes(events), [.interrupted], "\(events)")
    }

    t.test("短于一次轮询的 turn：两次扫描都空闲但 prompt 变了 → 补开始 + 完成") {
        let (root, file) = try makeSession("claude-transcript-desktop.jsonl")
        defer { try? FileManager.default.removeItem(at: root) }
        var events: [TaskEvent] = []
        let watcher = ClaudeTranscriptWatcher(projectsRoot: root) { event, _ in
            events.append(event)
        }
        watcher.scanOnce()
        guard case .sessionStarted = events.first?.kind else {
            throw ExpectationError(description: "首扫应登记空闲: \(events)")
        }

        events.removeAll()
        try append("""
        {"parentUuid":"u-4005","isSidechain":false,"type":"user","message":{"role":"user","content":"顺便看下注册页"},"uuid":"u-4010","timestamp":"2026-10-18T08:05:00.000Z","sessionId":"fixture-desktop-1","cwd":"/Users/me/work/web"}
        {"parentUuid":"u-4010","isSidechain":false,"type":"assistant","uuid":"u-4011","timestamp":"2026-10-18T08:05:03.000Z","message":{"id":"msg_DESK3","model":"claude-opus-5-5","role":"assistant","stop_reason":"end_turn","type":"message","content":[{"type":"text","text":"注册页没问题。"}]},"sessionId":"fixture-desktop-1","cwd":"/Users/me/work/web"}

        """, to: file)
        watcher.scanOnce()
        guard case .taskStarted(let title) = events.first?.kind else {
            throw ExpectationError(description: "应先补开始: \(events)")
        }
        try expectEqual(title, "顺便看下注册页")
        try expectEqual(events.first?.timestamp, ISO8601DateFormatter().date(from: "2026-10-18T08:05:00Z"))
        try expectEqual(finishes(events), [.success])

        // End to end: one finished card through TaskStore
        let store = TaskStore()
        let effects = events.flatMap { store.apply($0) }
        try expectEqual(effects.filter {
            if case .taskFinished = $0 { return true } else { return false }
        }.count, 1)
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

        // Session with an ai-title
        let withTitle = dir.appendingPathComponent("aaaa-1111.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-usage-dups.jsonl"), to: withTitle)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-100)], ofItemAtPath: withTitle.path)

        // Session with only a prompt (newer)
        let promptOnly = dir.appendingPathComponent("bbbb-2222.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-api-error.jsonl"), to: promptOnly)
        try fm.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: promptOnly.path)

        // Old session outside the window
        let ancient = dir.appendingPathComponent("cccc-3333.jsonl")
        try fm.copyItem(at: fixtureURL("claude-transcript-running.jsonl"), to: ancient)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-40 * 86400)],
            ofItemAtPath: ancient.path)

        let sessions = ClaudeSessionIndexer.index(projectsRoot: root)
        try expectEqual(sessions.count, 2, "窗口外的不索引: \(sessions.map(\.id))")
        // Sorted by mtime descending by default
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

    t.test("Codex 会话索引流式跨过 64KB，并以 session_index 标题为最高优先级") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("eureka-cxidx-large-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let root = base.appendingPathComponent("sessions", isDirectory: true)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-large-index.jsonl")
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let lines = [
            try line([
                "timestamp": "2026-07-21T08:00:00.000Z", "type": "session_meta",
                "payload": [
                    "id": "large-index", "cwd": "/Users/me/work/deep",
                    "base_instructions": String(repeating: "z", count: 96 * 1024),
                ],
            ]),
            try line([
                "timestamp": "2026-07-21T08:00:01.000Z", "type": "event_msg",
                "payload": ["type": "user_message", "message": "跨过固定窗口仍能读取的标题"],
            ]),
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: file, atomically: true, encoding: .utf8)

        let missingIndex = base.appendingPathComponent("missing-index.jsonl")
        var sessions = CodexSessionIndexer.index(
            sessionsRoot: root, threadNameIndexURL: missingIndex)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].id, "large-index")
        try expectEqual(sessions[0].cwd, "/Users/me/work/deep")
        try expectEqual(sessions[0].name, "跨过固定窗口仍能读取的标题")

        let indexURL = base.appendingPathComponent("session_index.jsonl")
        try line(["id": "large-index", "thread_name": "官方 Codex 会话标题"])
            .write(to: indexURL, atomically: true, encoding: .utf8)
        sessions = CodexSessionIndexer.index(
            sessionsRoot: root, threadNameIndexURL: indexURL)
        try expectEqual(sessions[0].name, "官方 Codex 会话标题")
    }

    t.test("Codex 索引：一个文件里两条 session_meta，只认第一条（id 不被 resume 的 meta 覆盖）") {
        // Reproduces a real bug: resumed / forked rollouts write a second session_meta. The old
        // "stop once both id and name are found" logic scanned all the way to EOF, overwriting the
        // id with **another session's id** along the way — so the 121 local rollouts parsed into
        // only 91 unique ids, and 30 sessions were wrongly merged in the list/index.
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-cxidx-dualmeta-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dayDir = root.appendingPathComponent("2026/07/21", isDirectory: true)
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let file = dayDir.appendingPathComponent("rollout-2026-07-21T10-00-00-first-thread.jsonl")
        try ([
            try line([
                "timestamp": "2026-07-21T08:00:00.000Z", "type": "session_meta",
                "payload": ["id": "first-thread", "cwd": "/Users/me/work/first"],
            ]),
            try line([
                "timestamp": "2026-07-21T08:00:01.000Z", "type": "event_msg",
                "payload": ["type": "user_message", "message": "第一个会话的提问"],
            ]),
            // The second meta carried in by resume: must never overwrite the id/cwd above
            try line([
                "timestamp": "2026-07-21T09:00:00.000Z", "type": "session_meta",
                "payload": ["id": "second-thread", "cwd": "/Users/me/work/second"],
            ]),
        ].joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)

        let sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].id, "first-thread")
        try expectEqual(sessions[0].cwd, "/Users/me/work/first")
    }

    t.test("Codex 索引：没有 user_message 的大文件不整文件扫（超出上界即放弃标题）") {
        // Such sessions (subagent / automation / post-compact) are 29 of 121 as observed.
        // Previously they never met the stop condition → the whole file was JSON-parsed line by
        // line (up to 70 MB per file). Now we stop past headScanLimit: id/cwd still come from the
        // first line, name falls back to nil, and the UI's displayName fallback shows the "Session
        // <first 8 of id>" label.
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-cxidx-nouser-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let dayDir = root.appendingPathComponent("2026/07/21", isDirectory: true)
        try fm.createDirectory(at: dayDir, withIntermediateDirectories: true)
        func line(_ object: [String: Any]) throws -> String {
            String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        var body = try line([
            "timestamp": "2026-07-21T08:00:00.000Z", "type": "session_meta",
            "payload": ["id": "no-user", "cwd": "/Users/me/work/auto"],
        ]) + "\n"
        // Unrelated lines that fill past headScanLimit (1 MB)
        let filler = try line([
            "timestamp": "2026-07-21T08:00:02.000Z", "type": "response_item",
            "payload": ["kind": String(repeating: "f", count: 4096)],
        ]) + "\n"
        while body.utf8.count < (1 << 20) + (64 << 10) { body += filler }
        // A user_message that appears only past the limit: must **not** be read
        body += try line([
            "timestamp": "2026-07-21T09:00:00.000Z", "type": "event_msg",
            "payload": ["type": "user_message", "message": "上界之外的标题不该出现"],
        ]) + "\n"
        let file = dayDir.appendingPathComponent("rollout-2026-07-21T10-00-00-no-user.jsonl")
        try body.write(to: file, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)

        let sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].id, "no-user")
        try expectEqual(sessions[0].cwd, "/Users/me/work/auto")
        try expect(sessions[0].name == nil, "上界之外的 user_message 不该被读到")
        try expectEqual(sessions[0].displayName, "会话 no-user")
    }

    t.test("Codex 索引：resume 的旧会话（老日期目录 + 新 mtime）被索引；全量 window 不溢出") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-cxidx-resumed-\(UUID().uuidString)", isDirectory: true)
        let oldDayDir = root.appendingPathComponent("2025/01/01", isDirectory: true)
        try fm.createDirectory(at: oldDayDir, withIntermediateDirectories: true)

        // A resumed old session: old creation-day directory but recent mtime → should be indexed
        let resumed = oldDayDir.appendingPathComponent(
            "rollout-2025-01-01T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0005.jsonl")
        try fm.copyItem(at: fixtureURL("codex-rollout-lifecycle.jsonl"), to: resumed)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: resumed.path)

        // Truly cold history: old directory + old mtime → the window filter should exclude it
        let ancientDir = root.appendingPathComponent("2024/12/31", isDirectory: true)
        try fm.createDirectory(at: ancientDir, withIntermediateDirectories: true)
        let ancient = ancientDir.appendingPathComponent(
            "rollout-2024-12-31T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0006.jsonl")
        try fm.copyItem(at: fixtureURL("codex-rollout-lifecycle.jsonl"), to: ancient)
        try fm.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-400 * 86400)],
            ofItemAtPath: ancient.path)

        let sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1, "老 mtime 的应被窗口排除: \(sessions.map(\.transcriptPath))")
        try expectEqual(sessions[0].id, "fixture-codex-1")
        // Enumerated paths carry a /private prefix (macOS tmp symlink); compare file names only
        try expect(
            sessions[0].transcriptPath.hasSuffix(resumed.lastPathComponent),
            "应索引 resume 文件: \(sessions[0].transcriptPath)")

        // The "Show all" UI passes .greatestFiniteMagnitude: must not overflow/crash, and cold
        // history is returned too
        let all = CodexSessionIndexer.index(
            sessionsRoot: root, window: .greatestFiniteMagnitude)
        try expectEqual(all.count, 2, "全量窗口应连冷历史一起索引: \(all.map(\.transcriptPath))")
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
