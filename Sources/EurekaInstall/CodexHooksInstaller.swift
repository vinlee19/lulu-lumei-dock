import Foundation

/// 把 eureka-relay 装进 Codex 的 `~/.codex/hooks.json`（Codex 0.145.0 实勘）。
///
/// 与 `ClaudeHooksInstaller` **结构完全同构**：`{"hooks": {事件: [{"hooks": [{type, command}]}]}}`。
/// 差别只有三处：
///  1. 事件集只有 4 个（Codex 目前就这些）：`UserPromptSubmit` / `Stop` / `SessionStart` /
///     **`PermissionRequest`**。后者是装它的主要理由 —— Codex 的 rollout 不落授权事件，
///     不装 hooks 就永远看不到「等待授权」。
///  2. Codex 的载荷**不带事件名**（Claude 有 `hook_event_name`），所以事件名必须写进命令行：
///     `"<relay>" codex-hook <Event>`，由 relay 补进载荷。
///  3. Codex 的条目没有 `matcher` 概念（Claude 的 PostToolUse 要 `matcher: "*"`）。
///
/// 安全口径逐条照搬 Claude 那份，一条都不能松：
///  - **绝不整段覆盖 `hooks[event]`**：本机这份文件正被别的 app（Otty）占用，
///    事件值是条目数组，我们只增删含 `eureka-relay` marker 的那一条，别人的原样留着。
///  - 认不出的形态（事件值不是条目数组）→ 直接拒绝改写并报错，宁可什么都不做，
///    也不能把看不懂的内容删掉。
///  - **`PermissionRequest` 的 stdout 极可能被 Codex 当作放行/拦截决策**（同 Claude 的
///    PreToolUse）→ relay 必须绝对静默、立即 exit 0。我们只报告，从不参与决策。
public enum CodexHooksInstaller {
    /// Codex 支持的 4 个事件（实勘 `~/.codex/hooks.json` 的键集）
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "SessionStart", "PermissionRequest",
    ]

    static let marker = "eureka-relay"

    /// 每个事件一条独立命令（事件名要带在命令行上）
    public static func hookCommand(relayPath: String, event: String) -> String {
        // 路径含空格（Application Support）必须引号包裹
        "\"\(relayPath)\" codex-hook \(event)"
    }

    /// hooks 里是否有我们**无法安全改写**的形态。返回第一个有问题的事件名。
    /// 语义与 `ClaudeHooksInstaller.unsupportedShapeEvent` 一致（同一风险、同一处理）。
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
            "hooks.json 的 hooks.\(event) 结构无法识别（不是条目数组）。"
                + "为避免删掉看不懂的内容，不做任何改动 —— 请先手动整理该字段。")
    }

    public static func install(into json: String, relayPath: String) throws -> String {
        var root = try parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        try rejectUnsupportedShape(hooks)
        for event in managedEvents {
            var entries = entriesOf(hooks, event)
            entries.removeAll(where: isEurekaEntry)  // 重装时替换旧条目（路径可能变了）
            entries.append([
                "hooks": [[
                    "type": "command",
                    "command": hookCommand(relayPath: relayPath, event: event),
                ]]
            ])
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
        guard let root = try? parse(json),
            let hooks = root["hooks"] as? [String: Any]
        else { return .none }
        let installed = managedEvents.filter { event in
            entriesOf(hooks, event).contains(where: isEurekaEntry)
        }.count
        if installed == managedEvents.count { return .installed }
        return installed == 0 ? .none : .partial
    }

    /// 带异常识别的诊断，判定顺序与 Claude 版一致：
    /// 先认「根本没法动」，再认「看着装了其实挂了」（路径歪 / relay 没了），最后才是缺事件。
    public static func diagnose(
        json: String, expectedRelayPath: String,
        relayIsExecutable: (String) -> Bool
    ) -> HookDiagnosis {
        guard let root = try? parse(json) else {
            return .unparseable(reason: "hooks.json 不是合法 JSON")
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        if let event = unsupportedShapeEvent(in: hooks) {
            return .unparseable(reason: "hooks.\(event) 的结构无法识别（不是条目数组）")
        }

        let ourCommands = eurekaCommands(in: hooks)
        guard !ourCommands.isEmpty else { return .notInstalled }

        let drifted = ourCommands.compactMap { command -> String? in
            guard let path = HookCommandPath.extract(from: command) else { return command }
            return path == expectedRelayPath ? nil : command
        }
        if !drifted.isEmpty { return .driftedPath(found: drifted.sorted()) }

        if !relayIsExecutable(expectedRelayPath) {
            return .relayMissing(path: expectedRelayPath)
        }

        let missing = managedEvents.filter { event in
            !entriesOf(hooks, event).contains(where: isEurekaEntry)
        }
        return missing.isEmpty ? .installed : .stale(missing: missing)
    }

    /// 同一份 hooks.json 里他人的条目（只为告知；我们只增删含 marker 的条目）。
    /// 本机实测该文件被 Otty 占用，这里正是用来把「和谁共存」显示给用户的。
    public static func foreignHooks(in json: String) -> ForeignHookReport {
        guard let root = try? parse(json),
            let hooks = root["hooks"] as? [String: Any]
        else { return ForeignHookReport() }
        var events: Set<String> = []
        var tools: Set<String> = []
        for (event, _) in hooks {
            for entry in entriesOf(hooks, event) where !isEurekaEntry(entry) {
                for command in entry["hooks"] as? [[String: Any]] ?? [] {
                    guard let text = command["command"] as? String,
                        let name = HookCommandPath.shortName(of: text)
                    else { continue }
                    events.insert(event)
                    tools.insert(name)
                }
            }
        }
        return ForeignHookReport(events: events.sorted(), tools: tools.sorted())
    }

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
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            throw InstallError.foreignConfig("hooks.json 不是合法 JSON 对象，未做改动")
        }
        return root
    }

    static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw InstallError.foreignConfig("序列化 hooks.json 失败")
        }
        return text + "\n"
    }
}
