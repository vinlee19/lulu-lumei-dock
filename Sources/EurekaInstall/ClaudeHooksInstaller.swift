import EurekaKit
import Foundation

public enum InstallError: Error, CustomStringConvertible {
    case invalidJSON
    case foreignConfig(String)

    public var description: String {
        switch self {
        case .invalidJSON: return L10n.text("The target file is not valid JSON", zhHans: "目标文件不是合法 JSON")
        case .foreignConfig(let detail): return L10n.format("Other configuration exists; automatic changes are refused: %@", zhHans: "存在他人配置，拒绝自动修改：%@", String(detail))
        }
    }
}

/// Hooks installer for ~/.claude/settings.json. Pure string in/out (file IO goes through ConfigFile
/// in the caller), which makes golden tests easy. Our entries are those whose command contains the
/// relay name (`lululumei-relay`, or legacy `eureka-relay`, see `RelayIdentity`) → idempotent
/// install, clean uninstall.
public enum ClaudeHooksInstaller {
    /// Managed hook events.
    ///
    /// PostToolUse is the heartbeat that resets waiting; PreToolUse says "what is about to run" (the permission card relies on it
    /// to show what is being requested); PreCompact keeps compaction from looking like a hang.
    ///
    /// **Claude reads PreToolUse stdout as an allow/block decision**, so the relay must stay
    /// absolutely silent and exit 0 immediately: we only report, never take part in the decision
    /// (see the hard invariants in CLAUDE.md).
    public static let managedEvents = [
        "UserPromptSubmit", "Stop", "Notification", "SessionStart", "SessionEnd",
        "PreToolUse", "PostToolUse", "PreCompact",
    ]

    public static func hookCommand(relayPath: String) -> String {
        // The path contains a space (Application Support) and must be quoted
        "\"\(relayPath)\" claude-hook"
    }

    /// Whether hooks contain a shape we **cannot safely rewrite**: an event value that isn't an
    /// array of entries, or an entry that isn't an object.
    ///
    /// Must be rejected rather than treated as an empty array: `entriesOf` returns `[]` for unrecognized shapes, and then
    /// `hooks[event] = entries` would overwrite the original content wholesale, deleting what we can't understand.
    /// Returns the first offending event name.
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
            L10n.format("The hooks.%@ structure in settings.json is not recognized (expected an array of entries).", zhHans: "settings.json 的 hooks.%@ 结构无法识别（不是条目数组）。", String(event))
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
            entries.removeAll(where: isEurekaEntry)  // Reinstall replaces old entries (the path may have changed)
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

    // MARK: - Diagnosis

    /// Diagnosis with anomaly detection. Pure function: whether the relay is executable is injected
    /// by the caller, for unit tests.
    ///
    /// The order is deliberate: first catch "can't touch it at all" (broken config), then the hidden failures that "look installed but
    /// are broken" (drifted path / missing relay), and only then ordinary missing events.
    public static func diagnose(
        json: String, expectedRelayPath: String,
        relayIsExecutable: (String) -> Bool
    ) -> HookDiagnosis {
        guard let root = try? parse(json) else {
            return .unparseable(reason: L10n.text("settings.json is not valid JSON", zhHans: "settings.json 不是合法 JSON"))
        }
        guard let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
        // Any unrecognized shape counts as "unparseable": better to do nothing than overwrite
        // content we can't understand
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

        // Relay missing: config is fine but the forwarder isn't executable → all events are
        // silently dropped
        if !relayIsExecutable(expectedRelayPath) {
            return .relayMissing(path: expectedRelayPath)
        }
        if !paths.legacy.isEmpty { return .legacyRelayName(found: paths.legacy) }

        let missing = managedEvents.filter { event in
            !entriesOf(hooks, event).contains(where: isEurekaEntry)
        }
        return missing.isEmpty ? .installed : .stale(missing: missing)
    }

    /// Other parties' hook entries in the same settings.json (informational only; we only
    /// add/remove entries carrying the marker)
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

    /// Full command string of our entry (for drift detection and display)
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
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)),
            let dict = object as? [String: Any]
        else { throw InstallError.invalidJSON }
        return dict
    }

    /// For building intermediate states in tests
    public static func parseForTest(_ json: String) throws -> [String: Any] {
        try parse(json)
    }

    /// For building intermediate states in tests
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
