import EurekaKit
import Foundation

/// Installs lululumei-relay into Trae CN's `~/.trae-cn/hooks.json`.
///
/// **Only the CN build has hooks**: the international build's `libai_agent.dylib` (inspected at
/// 3.5.35) lacks the whole `src/domain/hooks/…` tree and has no `hooks.json` asset type either.
///
/// Trae's hooks are a **deliberately Claude Code-compatible implementation** (the binary carries
/// `import_claude_folders` / `global_import_claude_enabled` / `CLAUDE_PROJECT_DIR`, plus a
/// `tool_compatible/` module that maps its own tool names onto Claude's):
///  - stdin keys: `hook_event_name` / `session_id` / `cwd` / `tool_input` / `tool_response` (**no**
///    `transcript_path` - the session DB is encrypted and there is no plaintext transcript);
///  - output contract: `hookSpecificOutput` / `permissionDecision` / `additionalContext` /
///    `stopReason`.
/// So payload decoding reuses `ClaudeHookDecoder` directly (only the source changes), and the relay
/// only needs a `trae-hook` subcommand isomorphic to `claude-hook`.
///
/// It differs from `ClaudeHooksInstaller` in only three ways:
///  1. The target is a **standalone file** `~/.trae-cn/hooks.json` (not a key inside
///     settings.json), the same as `CodexHooksInstaller`;
///  2. A different event set: Trae has `PostCompact` (Claude doesn't) but **no** `SessionEnd` /
///     `Notification` (→ the "waiting for permission" state is never visible for Trae);
///  3. The payload carries its own event name, so the command line needn't include it as Codex's
///     does.
///
/// ⚠️⚠️ **Trae's hooks are a server-side feature rolled out per account, and the local account
/// doesn't have it - so the structure below is "inferred from Trae's Claude-compatible design" and
/// has not been verified on a real install.**
///
/// How it was inspected (2026-08-08, Trae CN 3.3.84): put a probe with this structure into
/// `~/.trae-cn/hooks.json` and ran two real turns. The `ai-agent` log had both
/// `[Hooks] resolve_hooks_config result: is_ok=true` and `[Hooks] UserPromptSubmit hook completed`,
/// but **neither `[Hooks] Triggering hook: id=` nor
/// `[parse_hooks_config] skipping config file '…'`; our file path never even appeared in the log**.
/// So it never read the global config at all, rather than reading it and rejecting the shape.
///
/// The cause is the frontend's visibility check (`workbench.desktop.main.js`, the Hooks settings
/// page `AIHooksSettings`):
/// ```js
/// return jv(i) ? !1 : t.getConfigData()?.iCubeApp?.hooks?.enable === !0 ? !0
///                  : e?.account?.scope === Ol.BYTEDANCE
/// ```
/// i.e. it is enabled only when the server-side dynamic config has `iCubeApp.hooks.enable === true`
/// or the account scope is `BYTEDANCE`. The dynamic config fetched locally has no `hooks` key and
/// `user_scope=marscode` → the feature is off.
///
/// **Both paths are certain** (taken from Trae's own code, not guessed): the global
/// `<dataFolder>/hooks.json` comes from the frontend asset table `globalRelPath:"hooks.json"` +
/// `productService.dataFolderName`, and the project-level one from
/// `projectRelPath:".trae/hooks.json"`. **Only the schema inside the file is uncertain.** The
/// binary also has the field names `id` (`Triggering hook: id=`), `if_expr`
/// (`[HooksConfig] failed to compile regex if_expr`), `exec_env`, `version` (`unsupported_version`)
/// and `matcher` (`invalid_matcher`) - the real structure may be a flat array with `id`s rather
/// than the event map used here.
///
/// Verification once it's enabled (per the steps recorded in CHANGELOG): install → run a turn →
/// `grep -E "Triggering hook: id=|Hook execution finished: id=|parse_hooks_config" <ai-agent log>`.
/// If `skipping config file` shows up, change this file's structure per the reason it reports; the
/// change is confined to `install`.
///
/// Why it's still finished and kept in Settings: it's opt-in, only adds/removes marker-carrying
/// entries, aborts on an unrecognised shape, and backs up before writing - the worst case of a
/// wrong guess is that Trae ignores this config; nothing gets broken.
///
/// The safety rules are copied one for one, and none may be loosened:
///  - **Never overwrite `hooks[event]` wholesale**; only add/remove entries containing the relay
///    name (`RelayIdentity.isOurs`);
///  - Unrecognised shapes (an event value that isn't an entry array) → refuse to rewrite and report
///    an error; better to do nothing;
///  - **Trae reads `PreToolUse` stdout as an allow/block decision** (it honours
///    `permissionDecision`) → the relay must stay absolutely silent and exit 0 immediately. We only
///    report, never take part in decisions.
public enum TraeHooksInstaller {
    /// Managed events. Taken from the event names that actually appear in the `[Hooks]` logs and
    /// `src/domain/hooks/instance/trigger.rs` in `libai_agent.dylib`: `UserPromptSubmit` (seen as
    /// "hook completed" in a real log), `PreToolUse` / `PostToolUse` (both have "stop requested"
    /// and `[Hooks][PreToolUse] applied updatedInput for tool=`), `Stop` (`stop_hook.rs`),
    /// `PreCompact` / `PostCompact` (`PostCompact skipped duplicat…`).
    ///
    /// `SessionStart` appears only once in the binary with no accompanying log → not managed
    /// (better one event fewer than writing a key Trae doesn't recognise at all into the user's
    /// config).
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "PreToolUse", "PostToolUse", "PreCompact", "PostCompact",
    ]

    public static func hookCommand(relayPath: String) -> String {
        // The path contains a space (Application Support), so it must be quoted
        "\"\(relayPath)\" trae-hook"
    }

    /// Whether hooks contains a shape we **cannot safely rewrite**. Returns the first offending
    /// event name. Same semantics as the Claude / Codex versions (same risk, same handling).
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
            L10n.format("The hooks.%@ structure in hooks.json is not recognized (expected an array of entries).", zhHans: "hooks.json 的 hooks.%@ 结构无法识别（不是条目数组）。", String(event))
                + L10n.text(" No changes were made to avoid removing unrecognized content. Please fix this field manually first.", zhHans: "为避免删掉看不懂的内容，不做任何改动 —— 请先手动整理该字段。"))
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
            entries.removeAll(where: isEurekaEntry)  // Reinstall replaces old entries (path may differ)
            var entry: [String: Any] = ["hooks": [command]]
            // Tool events carry a matcher (Trae's error codes include `invalid_matcher`, so it
            // recognises the field); non-tool events don't, to avoid writing a key it doesn't
            // recognise.
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

    /// Same check order as the Claude / Codex versions: first "can't be touched at all", then
    /// "looks installed but is actually broken" (drifted path / relay gone), and missing events
    /// last.
    public static func diagnose(
        json: String, expectedRelayPath: String,
        relayIsExecutable: (String) -> Bool
    ) -> HookDiagnosis {
        guard let root = try? parse(json) else {
            return .unparseable(reason: L10n.text("hooks.json is not valid JSON", zhHans: "hooks.json 不是合法 JSON"))
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        if let event = unsupportedShapeEvent(in: hooks) {
            return .unparseable(reason: L10n.format("The hooks.%@ structure is not recognized (expected an array of entries)", zhHans: "hooks.%@ 的结构无法识别（不是条目数组）", String(event)))
        }

        let ourCommands = eurekaCommands(in: hooks)
        guard !ourCommands.isEmpty else { return .notInstalled }

        // Path drift: our entries point somewhere other than the stable path. The legacy
        // name in the same directory is our own previous path, so it is split out as migratable.
        let paths = RelayIdentity.classify(
            commands: ourCommands, expectedRelayPath: expectedRelayPath)
        if !paths.drifted.isEmpty { return .driftedPath(found: paths.drifted) }

        if !relayIsExecutable(expectedRelayPath) {
            return .relayMissing(path: expectedRelayPath)
        }
        if !paths.legacy.isEmpty { return .legacyRelayName(found: paths.legacy) }

        let missing = managedEvents.filter { event in
            !entriesOf(hooks, event).contains(where: isEurekaEntry)
        }
        return missing.isEmpty ? .installed : .stale(missing: missing)
    }

    /// Others' entries in the same hooks.json (informational only; we only add/remove
    /// marker-carrying entries)
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
                    if let text = command["command"] as? String, RelayIdentity.isOurs(text) {
                        result.append(text)
                    }
                }
            }
        }
        return result
    }

    // MARK: - Internals

    private static func entriesOf(_ hooks: [String: Any], _ event: String) -> [[String: Any]] {
        hooks[event] as? [[String: Any]] ?? []
    }

    private static func isEurekaEntry(_ entry: [String: Any]) -> Bool {
        let commands = entry["hooks"] as? [[String: Any]] ?? []
        return commands.contains { ($0["command"] as? String).map(RelayIdentity.isOurs) == true }
    }

    static func parse(_ json: String) throws -> [String: Any] {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return [:] }
        guard let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any]
        else {
            throw InstallError.foreignConfig(L10n.text("hooks.json is not a valid JSON object; no changes were made", zhHans: "hooks.json 不是合法 JSON 对象，未做改动"))
        }
        return root
    }

    static func serialize(_ root: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        guard let text = String(data: data, encoding: .utf8) else {
            throw InstallError.foreignConfig(L10n.text("Failed to serialize hooks.json", zhHans: "序列化 hooks.json 失败"))
        }
        return text + "\n"
    }
}
