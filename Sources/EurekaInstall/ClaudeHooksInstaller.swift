import Foundation

public enum InstallError: Error, CustomStringConvertible {
    case invalidJSON
    case foreignConfig(String)

    public var description: String {
        switch self {
        case .invalidJSON: return "目标文件不是合法 JSON"
        case .foreignConfig(let detail): return "存在他人配置，拒绝自动修改：\(detail)"
        }
    }
}

/// ~/.claude/settings.json 的 hooks 安装器。
/// 纯字符串进出（文件 IO 由调用方走 ConfigFile），便于黄金用例测试。
/// 以 command 中包含 "eureka-relay" 识别自有条目 → 幂等安装、干净卸载。
public enum ClaudeHooksInstaller {
    /// 受管的 hook 事件（PostToolUse 作 waiting 复位心跳，可在设置关闭后重装）
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd", "PostToolUse",
    ]

    static let marker = "eureka-relay"

    public static func hookCommand(relayPath: String) -> String {
        // 路径含空格（Application Support）必须引号包裹
        "\"\(relayPath)\" claude-hook"
    }

    public static func install(into json: String, relayPath: String) throws -> String {
        var root = try parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let command: [String: Any] = [
            "type": "command",
            "command": hookCommand(relayPath: relayPath),
            "timeout": 5,
        ]
        for event in managedEvents {
            var entries = entriesOf(hooks, event)
            entries.removeAll(where: isEurekaEntry)  // 重装时替换旧条目（路径可能变了）
            var entry: [String: Any] = ["hooks": [command]]
            if event == "PostToolUse" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    public static func uninstall(from json: String) throws -> String {
        var root = try parse(json)
        guard var hooks = root["hooks"] as? [String: Any] else { return try serialize(root) }
        for (event, _) in hooks {
            var entries = entriesOf(hooks, event)
            let before = entries.count
            entries.removeAll(where: isEurekaEntry)
            if entries.isEmpty && before > 0 {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try serialize(root)
    }

    public static func status(of json: String) -> InstallStatus {
        guard
            let root = try? parse(json),
            let hooks = root["hooks"] as? [String: Any]
        else { return .none }
        let installed = managedEvents.filter { event in
            entriesOf(hooks, event).contains(where: isEurekaEntry)
        }.count
        if installed == managedEvents.count { return .installed }
        return installed == 0 ? .none : .partial
    }

    // MARK: - 内部

    private static func entriesOf(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func isEurekaEntry(_ entry: [String: Any]) -> Bool {
        let commands = entry["hooks"] as? [[String: Any]] ?? []
        return commands.contains { ($0["command"] as? String)?.contains(marker) == true }
    }

    static func parse(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let dict = object as? [String: Any]
        else { throw InstallError.invalidJSON }
        return dict
    }

    /// 测试构造中间态用
    public static func serializeForTest(_ dict: [String: Any]) throws -> String {
        try serialize(dict)
    }

    static func serialize(_ dict: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
