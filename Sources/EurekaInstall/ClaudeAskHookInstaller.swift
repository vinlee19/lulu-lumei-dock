import Foundation

/// 灵动岛答题 hook（`lululumei-ask`）在 ~/.claude/settings.json 里的那一条：
/// `PermissionRequest` + `matcher: "AskUserQuestion"`。
///
/// 必须挂 `PermissionRequest`：Claude Code 先跑完 `PreToolUse` 才进入确认流程，挂在那里等岛上作答，
/// 桌面端的确认卡和终端里的选择框在等待期间都出不来；`PermissionRequest` 的 hook 与确认界面同时运行，
/// 谁先给出回答用谁（Claude Code 2.1.299 实测）。
///
/// 和 relay 的条目分开管：relay 必须静默，而它要把答案写到 stdout，
/// 所以只能挂在 AskUserQuestion 上 —— matcher 必须精确，绝不能是 `*`。
/// 设置里「在灵动岛上回答 Claude 的提问」单独开关它，装卸 Claude hooks 时随之装卸。
public enum ClaudeAskHookInstaller {
    public static let binaryName = "lululumei-ask"
    public static let event = "PermissionRequest"
    public static let matcher = "AskUserQuestion"
    /// hook 自己最多等 600 秒，这里多给 10 秒让它从容收尾（超时会被 Claude 杀掉）
    public static let timeoutSeconds = 610

    public static func isOurs(_ command: String) -> Bool {
        command.contains(binaryName)
    }

    public static func hookCommand(askPath: String) -> String {
        "\"\(askPath)\""
    }

    /// 装上（或替换成指向 `askPath` 的那一条）。其余条目逐字不动。
    /// 先清掉**所有事件**下的答题条目：挂在 `PreToolUse` 下的一条就足以挡住确认界面
    public static func install(into json: String, askPath: String) throws -> String {
        var root = try ClaudeHooksInstaller.parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if ClaudeHooksInstaller.unsupportedShapeEvent(in: hooks) != nil {
            throw InstallError.foreignConfig("settings.json 的 hooks 结构无法识别，不做改动")
        }
        hooks = removingAskEntries(from: hooks)
        var entries = hooks[event] as? [[String: Any]] ?? []
        entries.append([
            "matcher": matcher,
            "hooks": [[
                "type": "command",
                "command": hookCommand(askPath: askPath),
                "timeout": timeoutSeconds,
            ]],
        ])
        hooks[event] = entries
        root["hooks"] = hooks
        return try ClaudeHooksInstaller.serialize(root)
    }

    public static func uninstall(from json: String) throws -> String {
        var root = try ClaudeHooksInstaller.parse(json)
        guard var hooks = root["hooks"] as? [String: Any] else {
            return try ClaudeHooksInstaller.serialize(root)
        }
        if ClaudeHooksInstaller.unsupportedShapeEvent(in: hooks) != nil {
            throw InstallError.foreignConfig("settings.json 的 hooks 结构无法识别，不做改动")
        }
        hooks = removingAskEntries(from: hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try ClaudeHooksInstaller.serialize(root)
    }

    /// 是否已装着、且指向 `askPath`、matcher 精确，别的事件下也没有答题条目
    /// （有就算没装好，启动时的自动更新会重写，把它清掉）
    public static func isInstalled(in json: String, askPath: String) -> Bool {
        guard let root = try? ClaudeHooksInstaller.parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        let strayEntry = hooks.contains { name, value in
            name != event && (value as? [[String: Any]] ?? []).contains(where: isAskEntry)
        }
        guard !strayEntry else { return false }
        let entries = hooks[event] as? [[String: Any]] ?? []
        return entries.contains { entry in
            guard entry["matcher"] as? String == matcher else { return false }
            let commands = entry["hooks"] as? [[String: Any]] ?? []
            return commands.contains { $0["command"] as? String == hookCommand(askPath: askPath) }
        }
    }

    /// 是否有任何一条我们的答题条目（不论路径）
    public static func hasAnyEntry(in json: String) -> Bool {
        guard let root = try? ClaudeHooksInstaller.parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains(where: isAskEntry)
        }
    }

    /// 去掉每个事件下的答题条目；某个事件因此变空就连键一起删掉，其余条目逐字不动
    private static func removingAskEntries(from hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (name, value) in hooks {
            guard var entries = value as? [[String: Any]] else { continue }
            let before = entries.count
            entries.removeAll(where: isAskEntry)
            if entries.isEmpty && before > 0 {
                result.removeValue(forKey: name)
            } else if entries.count != before {
                result[name] = entries
            }
        }
        return result
    }

    static func isAskEntry(_ entry: [String: Any]) -> Bool {
        let commands = entry["hooks"] as? [[String: Any]] ?? []
        return commands.contains { ($0["command"] as? String).map(isOurs) == true }
    }
}
