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
    /// 受管的 hook 事件。
    ///
    /// PostToolUse 作 waiting 复位心跳；PreToolUse 提供"即将执行什么"（等待授权卡靠它说清
    /// 在请求什么对象）；PreCompact 让压缩期间不至于看着像卡死。
    ///
    /// **PreToolUse 的 stdout 会被 Claude 当作放行/拦截决策**，所以 relay 必须保持
    /// 绝对静默、立即 exit 0 —— 我们只报告，从不参与决策（见 CLAUDE.md 的硬不变量）。
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd",
        "PreToolUse", "PostToolUse", "PreCompact",
    ]

    static let marker = "eureka-relay"

    public static func hookCommand(relayPath: String) -> String {
        // 路径含空格（Application Support）必须引号包裹
        "\"\(relayPath)\" claude-hook"
    }

    /// hooks 里是否有我们**无法安全改写**的形态：事件值不是条目数组，或条目不是对象。
    ///
    /// 必须拒绝而不是当成空数组处理 —— `entriesOf` 对不认识的形态返回 `[]`，随后
    /// `hooks[event] = entries` 会把原本的内容整个覆盖掉，等于删掉了我们看不懂的东西。
    /// 返回第一个有问题的事件名。
    static func unsupportedShapeEvent(in hooks: [String: Any]) -> String? {
        for (event, value) in hooks {
            guard let entries = value as? [Any] else { return event }
            for entry in entries where !(entry is [String: Any]) { return event }
        }
        return nil
    }

    private static func rejectUnsupportedShape(_ hooks: [String: Any]) throws {
        guard let event = unsupportedShapeEvent(in: hooks) else { return }
        throw InstallError.foreignConfig(
            "settings.json 的 hooks.\(event) 结构无法识别（不是条目数组）。"
                + "为避免删掉看不懂的内容，不做任何改动 —— 请先手动整理该字段。")
    }

    public static func install(into json: String, relayPath: String) throws -> String {
        var root = try parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        try rejectUnsupportedShape(hooks)
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
        try rejectUnsupportedShape(hooks)
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

    // MARK: - 诊断

    /// 带异常识别的诊断。纯函数：relay 是否可执行由调用方注入，便于单测。
    ///
    /// 判定顺序刻意如此：先认出"根本没法动"的情况（配置坏了），再认"看起来装着其实挂了"
    /// 的隐蔽故障（路径歪了 / relay 没了），最后才是普通的缺事件。
    public static func diagnose(
        json: String, expectedRelayPath: String,
        relayIsExecutable: (String) -> Bool
    ) -> HookDiagnosis {
        guard let root = try? parse(json) else {
            return .unparseable(reason: "settings.json 不是合法 JSON")
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        // 不认识的形态一律按"无法解析"处理：宁可什么都不做，也不能覆盖掉看不懂的内容
        if let event = unsupportedShapeEvent(in: hooks) {
            return .unparseable(reason: "hooks.\(event) 的结构无法识别（不是条目数组）")
        }

        let ourCommands = eurekaCommands(in: hooks)
        guard !ourCommands.isEmpty else { return .notInstalled }

        // 路径漂移：自有条目指向的不是稳定路径
        let drifted = ourCommands.compactMap { command -> String? in
            guard let path = HookCommandPath.extract(from: command) else { return command }
            return path == expectedRelayPath ? nil : command
        }
        if !drifted.isEmpty { return .driftedPath(found: drifted.sorted()) }

        // relay 不见了：配置没问题，但转发器不可执行 → 事件全静默丢
        if !relayIsExecutable(expectedRelayPath) {
            return .relayMissing(path: expectedRelayPath)
        }

        let missing = managedEvents.filter { event in
            !entriesOf(hooks, event).contains(where: isEurekaEntry)
        }
        return missing.isEmpty ? .installed : .stale(missing: missing)
    }

    /// 同一份 settings.json 里他人的 hook 条目（只为告知；我们只增删含 marker 的条目）
    public static func foreignHooks(in json: String) -> ForeignHookReport {
        guard let root = try? parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return ForeignHookReport() }
        var events: Set<String> = []
        var tools: Set<String> = []
        for (event, _) in hooks {
            for entry in entriesOf(hooks, event) where !isEurekaEntry(entry) {
                for command in entry["hooks"] as? [[String: Any]] ?? [] {
                    guard let text = command["command"] as? String,
                          let name = HookCommandPath.shortName(of: text) else { continue }
                    events.insert(event)
                    tools.insert(name)
                }
            }
        }
        return ForeignHookReport(events: events.sorted(), tools: tools.sorted())
    }

    /// 自有条目的完整命令串（漂移判定与展示用）
    private static func eurekaCommands(in hooks: [String: Any]) -> [String] {
        var result: [String] = []
        for (event, _) in hooks {
            for entry in entriesOf(hooks, event) {
                for command in entry["hooks"] as? [[String: Any]] ?? [] {
                    if let text = command["command"] as? String, text.contains(marker) {
                        result.append(text)
                    }
                }
            }
        }
        return result
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
    public static func parseForTest(_ json: String) throws -> [String: Any] {
        try parse(json)
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
