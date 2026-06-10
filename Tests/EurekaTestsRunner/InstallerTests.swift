import EurekaInstall
import Foundation

private let relayPath = "/Users/me/Library/Application Support/Eureka/bin/eureka-relay"

private func parseJSON(_ string: String) throws -> [String: Any] {
    guard
        let object = try? JSONSerialization.jsonObject(with: Data(string.utf8)),
        let dict = object as? [String: Any]
    else { throw ExpectationError(description: "结果不是合法 JSON object") }
    return dict
}

private func hookEntries(_ root: [String: Any], _ event: String) -> [[String: Any]] {
    (root["hooks"] as? [String: Any])?[event] as? [[String: Any]] ?? []
}

private func commands(in entry: [String: Any]) -> [String] {
    (entry["hooks"] as? [[String: Any]])?.compactMap { $0["command"] as? String } ?? []
}

func installerTests(_ t: TestRunner) {
    t.suite("ClaudeHooksInstaller")

    t.test("空文件安装：六个事件齐全，命令带引号与 timeout") {
        let result = try ClaudeHooksInstaller.install(into: "", relayPath: relayPath)
        let root = try parseJSON(result)
        for event in ClaudeHooksInstaller.managedEvents {
            let entries = hookEntries(root, event)
            try expectEqual(entries.count, 1)
            let cmds = commands(in: entries[0])
            try expectEqual(cmds, ["\"\(relayPath)\" claude-hook"])
            let timeout = (entries[0]["hooks"] as? [[String: Any]])?.first?["timeout"] as? Int
            try expectEqual(timeout, 5)
        }
        // PostToolUse 需要 matcher=*，其余不带 matcher
        try expectEqual(hookEntries(root, "PostToolUse")[0]["matcher"] as? String, "*")
        try expect(hookEntries(root, "Stop")[0]["matcher"] == nil)
    }

    t.test("已有 env/plugins 等键全部保留") {
        let original = try fixtureString("configs/settings-with-env.json")
        let result = try ClaudeHooksInstaller.install(into: original, relayPath: relayPath)
        let root = try parseJSON(result)
        let originalRoot = try parseJSON(original)

        try expectEqual(root["model"] as? String, originalRoot["model"] as? String)
        try expectEqual(root["effortLevel"] as? String, "xhigh")
        let env = root["env"] as? [String: String]
        try expectEqual(env?["OTEL_EXPORTER_OTLP_ENDPOINT"], "http://otel.example.invalid:4318")
        let plugins = root["enabledPlugins"] as? [String: Bool]
        try expectEqual(plugins?["superpowers@claude-plugins-official"], true)
    }

    t.test("幂等：安装两次结果一致，不重复条目") {
        let once = try ClaudeHooksInstaller.install(into: "", relayPath: relayPath)
        let twice = try ClaudeHooksInstaller.install(into: once, relayPath: relayPath)
        try expectEqual(once, twice)
    }

    t.test("重装更新 relay 路径") {
        let old = try ClaudeHooksInstaller.install(into: "", relayPath: "/old/path/eureka-relay")
        let updated = try ClaudeHooksInstaller.install(into: old, relayPath: relayPath)
        let root = try parseJSON(updated)
        let cmds = commands(in: hookEntries(root, "Stop")[0])
        try expect(cmds[0].contains(relayPath), "应替换为新路径")
        try expectEqual(hookEntries(root, "Stop").count, 1)
    }

    t.test("他人 hooks 共存：安装保留、卸载不动") {
        let original = try fixtureString("configs/settings-with-foreign-hooks.json")
        let installed = try ClaudeHooksInstaller.install(into: original, relayPath: relayPath)
        var root = try parseJSON(installed)

        // Stop 事件：他人的 terminal-notifier + 我们的，共 2 条
        let stopEntries = hookEntries(root, "Stop")
        try expectEqual(stopEntries.count, 2)
        try expect(stopEntries.flatMap(commands(in:)).contains { $0.contains("terminal-notifier") })

        // 不受管的 PreToolUse 原样保留
        try expectEqual(hookEntries(root, "PreToolUse").count, 1)

        let uninstalled = try ClaudeHooksInstaller.uninstall(from: installed)
        root = try parseJSON(uninstalled)
        try expectEqual(hookEntries(root, "Stop").count, 1)
        try expect(commands(in: hookEntries(root, "Stop")[0])[0].contains("terminal-notifier"))
        try expectEqual(hookEntries(root, "PreToolUse").count, 1)
        try expect(hookEntries(root, "UserPromptSubmit").isEmpty, "我们的事件应被清掉")
    }

    t.test("纯净安装后卸载：恢复语义等价（hooks 键消失，其余键不变）") {
        let original = try fixtureString("configs/settings-with-env.json")
        let installed = try ClaudeHooksInstaller.install(into: original, relayPath: relayPath)
        let uninstalled = try ClaudeHooksInstaller.uninstall(from: installed)
        let root = try parseJSON(uninstalled)
        try expect(root["hooks"] == nil, "卸载后 hooks 键应消失")
        let originalRoot = try parseJSON(original)
        try expectEqual(
            NSDictionary(dictionary: root),
            NSDictionary(dictionary: originalRoot)
        )
    }

    t.test("status 三态") {
        try expectEqual(ClaudeHooksInstaller.status(of: ""), InstallStatus.none)
        let installed = try ClaudeHooksInstaller.install(into: "", relayPath: relayPath)
        try expectEqual(ClaudeHooksInstaller.status(of: installed), .installed)
        // 手工去掉一个事件 → partial
        var root = try parseJSON(installed)
        var hooks = root["hooks"] as! [String: Any]
        hooks.removeValue(forKey: "Stop")
        root["hooks"] = hooks
        let partial = try ClaudeHooksInstaller.serializeForTest(root)
        try expectEqual(ClaudeHooksInstaller.status(of: partial), .partial)
    }

    t.test("非法 JSON 报错不破坏") {
        do {
            _ = try ClaudeHooksInstaller.install(into: "{broken", relayPath: relayPath)
            throw ExpectationError(description: "应抛 invalidJSON")
        } catch is InstallError {}
    }
}
