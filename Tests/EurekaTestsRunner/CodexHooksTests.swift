import EurekaIngest
import EurekaInstall
import EurekaKit
import Foundation

/// Codex hooks（`~/.codex/hooks.json`，Codex 0.145.0 实勘）：安装器 + 解码器。
/// fixture 照抄本机真实文件的形状 —— 该文件正被 Otty 占用，所以「共存」是首要测点。
func codexHooksTests(_ t: TestRunner) {
    codexHooksInstallerTests(t)
    codexHookDecoderTests(t)
}

/// 本机真实 hooks.json 的骨架（Otty 占着 4 个事件；`_otty` 是它自己的标记字段）
private let ottyOccupied = """
{
  "hooks": {
    "PermissionRequest": [
      { "_otty": true, "hooks": [{ "command": "'/Applications/Otty.app/…/otty-hook.sh' awaiting", "type": "command" }] }
    ],
    "SessionStart": [
      { "_otty": true, "hooks": [{ "command": "'/Applications/Otty.app/…/otty-hook.sh' start", "type": "command" }] }
    ]
  }
}
"""

private func codexHooksInstallerTests(_ t: TestRunner) {
    t.suite("CodexHooksInstaller · hooks.json 深合并")

    t.test("装进被 Otty 占用的文件：别人的条目必须一条不少") {
        let relay = "/Users/me/Library/Application Support/Eureka/bin/eureka-relay"
        let updated = try CodexHooksInstaller.install(into: ottyOccupied, relayPath: relay)
        let root = try expectSome(
            (try? JSONSerialization.jsonObject(with: Data(updated.utf8))) as? [String: Any])
        let hooks = try expectSome(root["hooks"] as? [String: Any])

        // 4 个事件全装上
        try expectEqual(
            Set(hooks.keys), Set(CodexHooksInstaller.managedEvents),
            "实得 \(hooks.keys.sorted())")

        // Otty 原有的两个事件里，它自己的条目仍在（这是最容易踩坏的地方）
        for event in ["PermissionRequest", "SessionStart"] {
            let entries = try expectSome(hooks[event] as? [[String: Any]])
            let otty = entries.filter { $0["_otty"] as? Bool == true }
            try expectEqual(otty.count, 1, "\(event) 里 Otty 的条目被弄丢了")
            let ours = entries.filter { entry in
                (entry["hooks"] as? [[String: Any]] ?? []).contains {
                    ($0["command"] as? String)?.contains("eureka-relay") == true
                }
            }
            try expectEqual(ours.count, 1, "\(event) 应恰好有我们一条")
        }

        // 命令行必须带事件名（Codex 载荷不含事件名，只能靠这个区分）
        let permission = try expectSome(hooks["PermissionRequest"] as? [[String: Any]])
        let command = permission
            .flatMap { $0["hooks"] as? [[String: Any]] ?? [] }
            .compactMap { $0["command"] as? String }
            .first { $0.contains("eureka-relay") }
        try expectEqual(
            command, "\"\(relay)\" codex-hook PermissionRequest",
            "路径要带引号（Application Support 有空格），事件名要带在命令行上")
    }

    t.test("重装替换自己的旧条目而不叠加；卸载只摘自己的") {
        let old = try CodexHooksInstaller.install(
            into: ottyOccupied, relayPath: "/old/path/eureka-relay")
        let again = try CodexHooksInstaller.install(
            into: old, relayPath: "/new/path/eureka-relay")
        let againRoot = try expectSome(
            (try? JSONSerialization.jsonObject(with: Data(again.utf8))) as? [String: Any])
        let hooks = try expectSome(againRoot["hooks"] as? [String: Any])
        let entries = try expectSome(hooks["Stop"] as? [[String: Any]])
        try expectEqual(entries.count, 1, "重装不该叠加成两条")
        try expect(
            (entries[0]["hooks"] as? [[String: Any]] ?? [])
                .compactMap { $0["command"] as? String }
                .allSatisfy { $0.contains("/new/path/") },
            "重装应把路径换成新的")

        let removed = try CodexHooksInstaller.uninstall(from: again)
        let removedRoot = try expectSome(
            (try? JSONSerialization.jsonObject(with: Data(removed.utf8))) as? [String: Any])
        let after = try expectSome(removedRoot["hooks"] as? [String: Any])
        try expectEqual(
            Set(after.keys), ["PermissionRequest", "SessionStart"],
            "卸载后应只剩 Otty 原有的两个事件，实得 \(after.keys.sorted())")
        for event in after.keys {
            let entries = try expectSome(after[event] as? [[String: Any]])
            try expect(
                entries.allSatisfy { $0["_otty"] as? Bool == true },
                "\(event) 里应只剩 Otty 的条目")
        }
    }

    t.test("认不出的结构一律拒写，绝不覆盖看不懂的内容") {
        // 事件值不是条目数组 → 必须抛错。若当成空数组处理，会把这段直接删掉。
        let weird = #"{"hooks":{"Stop":"some-command-string"}}"#
        var threw = false
        do { _ = try CodexHooksInstaller.install(into: weird, relayPath: "/r/eureka-relay") }
        catch { threw = true }
        try expect(threw, "不是条目数组时必须拒绝改写")
        try expectEqual(CodexHooksInstaller.status(of: weird), .none)
    }

    t.test("状态与诊断：装全 / 装一半 / 路径漂移 / relay 不见了") {
        let relay = "/stable/eureka-relay"
        let full = try CodexHooksInstaller.install(into: "", relayPath: relay)
        try expectEqual(CodexHooksInstaller.status(of: full), .installed)
        try expectEqual(
            CodexHooksInstaller.diagnose(
                json: full, expectedRelayPath: relay, relayIsExecutable: { _ in true }),
            .installed)

        // relay 不可执行 → 配置没问题但事件全静默丢，必须单独报出来
        try expectEqual(
            CodexHooksInstaller.diagnose(
                json: full, expectedRelayPath: relay, relayIsExecutable: { _ in false }),
            .relayMissing(path: relay))

        // 路径被手改过 → driftedPath（安装按钮默认拒绝覆盖）
        let drifted = full.replacingOccurrences(of: "/stable/", with: "/hand-edited/")
        guard case .driftedPath = CodexHooksInstaller.diagnose(
            json: drifted, expectedRelayPath: relay, relayIsExecutable: { _ in true })
        else { throw ExpectationError(description: "路径漂移应判 driftedPath") }

        try expectEqual(CodexHooksInstaller.status(of: ottyOccupied), .none, "只有别人的条目 = 未安装")
    }

    t.test("他人条目被如实报出（用于告知共存）") {
        let report = CodexHooksInstaller.foreignHooks(in: ottyOccupied)
        try expect(!report.isEmpty)
        try expectEqual(report.events, ["PermissionRequest", "SessionStart"])
        try expect(
            report.tools.contains { $0.contains("otty") },
            "应认出 Otty，实得 \(report.tools)")
    }
}

// MARK: - 解码器

private func codexHookDecoderTests(_ t: TestRunner) {
    t.suite("CodexHookDecoder · Codex hook 载荷")

    func decode(_ payload: [String: Any]) -> TaskEvent? {
        CodexHookDecoder.decode(payload: payload, receivedAt: Date())
    }

    t.test("PermissionRequest → 等待授权（这是装 hooks 的主要理由）") {
        let event = try expectSome(decode([
            "hook_event_name": "PermissionRequest",
            "session_id": "s1", "cwd": "/w", "tool_name": "shell",
        ]))
        guard case .waiting(let reason, let message) = event.kind else {
            throw ExpectationError(description: "应出 waiting，实得 \(event.kind)")
        }
        try expectEqual(reason, .permission)
        try expectEqual(message, "shell")
        try expectEqual(event.source, .codex)
        try expectEqual(event.cwd, "/w")

        // 取不到工具名也要照样出等待卡（"在等你确认"本身就是要传达的信息）
        let bare = try expectSome(decode([
            "hook_event_name": "PermissionRequest", "session_id": "s1",
        ]))
        guard case .waiting(let r2, let m2) = bare.kind else {
            throw ExpectationError(description: "无工具名时也应出 waiting")
        }
        try expectEqual(r2, .permission)
        try expect(m2 == nil)
    }

    t.test("UserPromptSubmit / Stop / SessionStart 映射") {
        guard case .taskStarted(let title)? = decode([
            "hook_event_name": "UserPromptSubmit", "session_id": "s1", "prompt": "修一下构建",
        ])?.kind else { throw ExpectationError(description: "应出 taskStarted") }
        try expectEqual(title, "修一下构建")

        guard case .taskFinished(let outcome, _, _)? = decode([
            "hook_event_name": "Stop", "session_id": "s1",
        ])?.kind else { throw ExpectationError(description: "应出 taskFinished") }
        try expectEqual(outcome, .success)

        guard case .sessionStarted? = decode([
            "hook_event_name": "SessionStart", "session_id": "s1",
        ])?.kind else { throw ExpectationError(description: "应出 sessionStarted") }
    }

    t.test("session id 两种落法都认；缺事件名/会话 id 一律返回 nil 不抛错") {
        // 实勘旁证：同机 Otty 的 codex 钩子脚本同时兼容顶层 session_id 与 payload.id
        let nested = try expectSome(decode([
            "hook_event_name": "Stop", "payload": ["id": "nested-1"],
        ]))
        try expectEqual(nested.sessionId, "nested-1")

        try expect(decode(["hook_event_name": "Stop"]) == nil, "无会话 id 应返回 nil")
        try expect(decode(["session_id": "s1"]) == nil, "无事件名应返回 nil")
        try expect(
            decode(["hook_event_name": "SomeFutureEvent", "session_id": "s1"]) == nil,
            "不认识的事件应返回 nil 而不是崩")
    }

    t.test("codex-hook 通道接进 EventRouter") {
        // RawEvent 只有 init?(data:)：照 relay 写进 spool 的信封形状构造
        let envelope: [String: Any] = [
            "channel": "codex-hook",
            "receivedAtMs": Date().timeIntervalSince1970 * 1000,
            "payload": ["hook_event_name": "PermissionRequest", "session_id": "s9"],
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let raw = try expectSome(RawEvent(data: data))
        let events = EventRouter.route(raw)
        try expectEqual(events.count, 1)
        try expectEqual(events.first?.source, .codex)
        guard case .waiting(let reason, _)? = events.first?.kind else {
            throw ExpectationError(description: "应经 router 出 waiting")
        }
        try expectEqual(reason, .permission)
    }
}
