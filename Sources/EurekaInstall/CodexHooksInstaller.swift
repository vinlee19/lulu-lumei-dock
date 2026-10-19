import EurekaKit
import Foundation

/// Installs lululumei-relay into Codex's `~/.codex/hooks.json` (surveyed on Codex 0.145.0).
///
/// **Structurally identical** to `ClaudeHooksInstaller`: `{"hooks": {Event: [{"hooks": [{type,
/// command}]}]}}`. Only three differences:
///  1. Only 4 events (all Codex has today): `UserPromptSubmit` / `Stop` / `SessionStart` /
///     **`PermissionRequest`**. The last is the main reason to install: Codex rollouts don't record permission events,
///     so without hooks "waiting for permission" is never visible.
///  2. Codex payloads **carry no event name** (Claude has `hook_event_name`), so the event name
///     must go on the command line: `"<relay>" codex-hook <Event>`, and the relay adds it to the
///     payload.
///  3. Codex entries have no `matcher` concept (Claude's PostToolUse needs `matcher: "*"`).
///
/// The safety rules are copied one by one from the Claude installer, and none may be relaxed:
///  - **Never overwrite `hooks[event]` wholesale**: on this machine the file is in use by another
///    app (Otty); event values are arrays of entries, and we only add/remove the one carrying the
///    relay name (`RelayIdentity.isOurs`), leaving others intact.
///  - Unrecognized shapes (an event value that isn't an array of entries) → refuse to write and
///    report an error; better to do nothing than delete content we can't understand.
///  - **Codex very likely reads `PermissionRequest` stdout as an allow/block decision** (like
///    Claude's PreToolUse) → the relay must stay absolutely silent and exit 0 immediately. We only
///    report, never take part in the decision.
public enum CodexHooksInstaller {
    /// The 4 events Codex supports (key set observed in `~/.codex/hooks.json`)
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "SessionStart", "PermissionRequest",
    ]

    /// One standalone command per event (the event name must be on the command line)
    public static func hookCommand(relayPath: String, event: String) -> String {
        // The path contains a space (Application Support) and must be quoted
        "\"\(relayPath)\" codex-hook \(event)"
    }

    /// Whether hooks contain a shape we **cannot safely rewrite**. Returns the first offending
    /// event name. Same semantics as `ClaudeHooksInstaller.unsupportedShapeEvent` (same risk, same
    /// handling).
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
        for event in managedEvents {
            var entries = entriesOf(hooks, event)
            entries.removeAll(where: isEurekaEntry)  // Reinstall replaces old entries (the path may have changed)
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

    /// Diagnosis with anomaly detection, in the same order as the Claude version: first "can't
    /// touch it at all", then "looks installed but is broken" (drifted path / missing relay), and
    /// only then missing events.
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

    /// Other parties' entries in the same hooks.json (informational only; we only add/remove
    /// entries carrying the marker). Locally this file is in use by Otty; this is exactly what
    /// shows the user who we coexist with.
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

    // MARK: - Internal

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
