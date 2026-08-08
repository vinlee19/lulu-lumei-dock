import Foundation

/// 把 eureka-relay 装进 Trae CN 的 `~/.trae-cn/hooks.json`。
///
/// **只有 CN 版有 hooks**：国际版（实勘 3.5.35）的 `libai_agent.dylib` 里没有
/// `src/domain/hooks/…` 那一整套，也没有 `hooks.json` 这个资产类型。
///
/// Trae 的 hooks 是**刻意做的 Claude Code 兼容实现**（二进制里带着
/// `import_claude_folders` / `global_import_claude_enabled` / `CLAUDE_PROJECT_DIR`，
/// 还有一个 `tool_compatible/` 模块把自家工具名映射成 Claude 的）：
///  - stdin 键：`hook_event_name` / `session_id` / `cwd` / `tool_input` / `tool_response`
///    （**没有** `transcript_path` —— 会话库加密，没有明文转录）；
///  - 输出契约：`hookSpecificOutput` / `permissionDecision` / `additionalContext` / `stopReason`。
/// 所以载荷解码直接复用 `ClaudeHookDecoder`（只换 source），relay 也只需一个
/// 与 `claude-hook` 同构的 `trae-hook` 子命令。
///
/// 与 `ClaudeHooksInstaller` 的差别只有三处：
///  1. 目标是**独立文件** `~/.trae-cn/hooks.json`（不是 settings.json 里的一个键），
///     这点与 `CodexHooksInstaller` 相同；
///  2. 事件集不同：Trae 有 `PostCompact`（Claude 没有），但**没有** `SessionEnd` /
///     `Notification`（→ 「等待授权」这个状态对 Trae 永远不可见）；
///  3. 载荷自带事件名，所以命令行不用像 Codex 那样把事件名带上。
///
/// ⚠️⚠️ **Trae 的 hooks 是按账号灰度的服务端功能，而且本机账号没放开 —— 所以下面这份
/// 结构是「按 Trae 的 Claude 兼容取向推的」，尚未实机验证过。**
///
/// 实勘经过（2026-08-08，Trae CN 3.3.84）：往 `~/.trae-cn/hooks.json` 放了一份本结构的探针，
/// 跑了两个真实回合，`ai-agent` 日志里 `[Hooks] resolve_hooks_config result: is_ok=true`、
/// `[Hooks] UserPromptSubmit hook completed` 都有，但**既没有 `[Hooks] Triggering hook: id=`，
/// 也没有 `[parse_hooks_config] skipping config file '…'`，日志里连我们的文件路径都没出现过**
/// —— 说明它压根没去读全局配置，不是读了嫌形状不对。
///
/// 原因在前端的可见性判定（`workbench.desktop.main.js`，Hooks 设置页 `AIHooksSettings`）：
/// ```js
/// return jv(i) ? !1 : t.getConfigData()?.iCubeApp?.hooks?.enable === !0 ? !0
///                  : e?.account?.scope === Ol.BYTEDANCE
/// ```
/// 即：服务端动态配置 `iCubeApp.hooks.enable === true`，或账号 scope 是 `BYTEDANCE`，
/// 二者之一才开放。本机拉到的动态配置里没有 `hooks` 键、`user_scope=marscode` → 功能关着。
///
/// **两条路径是确定的**（取自 Trae 自己的代码，不是猜）：全局 `<dataFolder>/hooks.json`
/// 来自前端资产表 `globalRelPath:"hooks.json"` + `productService.dataFolderName`，
/// 项目级来自 `projectRelPath:".trae/hooks.json"`。**不确定的只有文件内部的 schema。**
/// 二进制里另有 `id`（`Triggering hook: id=`）、`if_expr`（`[HooksConfig] failed to compile
/// regex if_expr`）、`exec_env`、`version`（`unsupported_version`）、`matcher`
/// （`invalid_matcher`）这些字段名 —— 真实结构可能是带 `id` 的扁平数组而非这里的事件映射表。
///
/// 放开后要做的验证（照 CHANGELOG 里记的步骤）：装上 → 跑一个回合 →
/// `grep -E "Triggering hook: id=|Hook execution finished: id=|parse_hooks_config" <ai-agent 日志>`。
/// 如果出现 `skipping config file`，就按它报的原因改本文件的结构；改动只集中在 `install`。
///
/// 之所以仍然把它做完并留在设置里：它 opt-in、只增删带 marker 的条目、形状认不出就 abort、
/// 写前备份 —— 形状猜错的最坏后果只是 Trae 忽略这份配置，不会弄坏任何东西。
///
/// 安全口径逐条照搬，一条都不能松：
///  - **绝不整段覆盖 `hooks[event]`**，只增删含 `eureka-relay` marker 的条目；
///  - 认不出的形态（事件值不是条目数组）→ 拒绝改写并报错，宁可什么都不做；
///  - **`PreToolUse` 的 stdout 会被 Trae 当作放行/拦截决策**（它认
///    `permissionDecision`）→ relay 必须绝对静默、立即 exit 0。我们只报告，从不参与决策。
public enum TraeHooksInstaller {
    /// 受管事件。取自 `libai_agent.dylib` 里 `[Hooks]` 日志与 `src/domain/hooks/instance/trigger.rs`
    /// 实际出现的事件名：`UserPromptSubmit`（实机日志见过 "hook completed"）、
    /// `PreToolUse` / `PostToolUse`（均有 "stop requested" 与
    /// `[Hooks][PreToolUse] applied updatedInput for tool=`）、`Stop`（`stop_hook.rs`）、
    /// `PreCompact` / `PostCompact`（`PostCompact skipped duplicat…`）。
    ///
    /// `SessionStart` 在二进制里只出现一次且无配套日志 → 不纳管（宁可少一个事件，
    /// 也不要往用户配置里写一个 Trae 根本不认的键）。
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact",
    ]

    static let marker = "eureka-relay"

    public static func hookCommand(relayPath: String) -> String {
        // 路径含空格（Application Support）必须引号包裹
        "\"\(relayPath)\" trae-hook"
    }

    /// hooks 里是否有我们**无法安全改写**的形态。返回第一个有问题的事件名。
    /// 语义与 Claude / Codex 两份一致（同一风险、同一处理）。
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
        let command: [String: Any] = [
            "type": "command",
            "command": hookCommand(relayPath: relayPath),
            "timeout": 5,
        ]
        for event in managedEvents {
            var entries = entriesOf(hooks, event)
            entries.removeAll(where: isEurekaEntry)  // 重装时替换旧条目（路径可能变了）
            var entry: [String: Any] = ["hooks": [command]]
            // 工具类事件带 matcher（Trae 的错误码里有 `invalid_matcher`，说明它认这个字段）；
            // 非工具事件不写，免得写进一个它不认的键。
            if event == "PreToolUse" || event == "PostToolUse" { entry["matcher"] = "*" }
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
        guard let root = try? parse(json),
            let hooks = root["hooks"] as? [String: Any]
        else { return .none }
        let installed = managedEvents.filter { event in
            entriesOf(hooks, event).contains(where: isEurekaEntry)
        }.count
        if installed == managedEvents.count { return .installed }
        return installed == 0 ? .none : .partial
    }

    /// 判定顺序与 Claude / Codex 版一致：
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

    /// 同一份 hooks.json 里他人的条目（只为告知；我们只增删含 marker 的条目）
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
