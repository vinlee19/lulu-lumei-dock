import Foundation

/// 灵动岛答题 hook（`lululumei-ask`）在 ~/.claude/settings.json 里的那一条：
/// `PreToolUse` + `matcher: "AskUserQuestion"`。
///
/// 和 relay 的条目分开管：relay 必须静默，而它要把答案写到 stdout，
/// 所以只能挂在 AskUserQuestion 上 —— matcher 必须精确，绝不能是 `*`。
/// 设置里「在灵动岛上回答 Claude 的提问」单独开关它，装卸 Claude hooks 时随之装卸。
public enum ClaudeAskHookInstaller {
    public static let binaryName = "lululumei-ask"
    public static let event = "PreToolUse"
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
    public static func install(into json: String, askPath: String) throws -> String {
        var root = try ClaudeHooksInstaller.parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if ClaudeHooksInstaller.unsupportedShapeEvent(in: hooks) != nil {
            throw InstallError.foreignConfig("settings.json 的 hooks 结构无法识别，不做改动")
        }
        var entries = hooks[event] as? [[String: Any]] ?? []
        entries.removeAll(where: isAskEntry)
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
        var entries = hooks[event] as? [[String: Any]] ?? []
        let before = entries.count
        entries.removeAll(where: isAskEntry)
        if entries.isEmpty && before > 0 {
            hooks.removeValue(forKey: event)
        } else if entries.count != before {
            hooks[event] = entries
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try ClaudeHooksInstaller.serialize(root)
    }

    /// 是否已装着、且指向 `askPath`、matcher 精确
    public static func isInstalled(in json: String, askPath: String) -> Bool {
        guard let root = try? ClaudeHooksInstaller.parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return false }
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

    static func isAskEntry(_ entry: [String: Any]) -> Bool {
        let commands = entry["hooks"] as? [[String: Any]] ?? []
        return commands.contains { ($0["command"] as? String).map(isOurs) == true }
    }
}
