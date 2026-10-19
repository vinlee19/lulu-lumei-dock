import EurekaKit
import Foundation

/// The island answer hook (`lululumei-ask`) entry in ~/.claude/settings.json:
/// `PermissionRequest` + `matcher: "AskUserQuestion"`.
///
/// It must hang on `PermissionRequest`: Claude Code finishes `PreToolUse` before entering the
/// confirmation flow, so waiting there for the island answer would keep both the desktop
/// confirmation card and the terminal picker from appearing; a `PermissionRequest` hook runs
/// alongside the confirmation UI, and whichever answers first wins (verified on Claude Code
/// 2.1.299).
///
/// Managed separately from the relay entries: the relay must stay silent, whereas this writes the
/// answer to stdout, so it may only hang on AskUserQuestion -- the matcher must be exact, never
/// `*`. The "Answer Claude's questions on the island" setting toggles it on its own, and it is
/// installed/removed along with Claude hooks.
public enum ClaudeAskHookInstaller {
    public static let binaryName = "lululumei-ask"
    public static let event = "PermissionRequest"
    public static let matcher = "AskUserQuestion"
    /// The hook itself waits at most 600 seconds; give 10 more here so it can wrap up calmly (on
    /// timeout Claude kills it)
    public static let timeoutSeconds = 610

    public static func isOurs(_ command: String) -> Bool {
        command.contains(binaryName)
    }

    public static func hookCommand(askPath: String) -> String {
        "\"\(askPath)\""
    }

    /// Computed on each throw so it follows the current interface language
    private static var unrecognizedShapeMessage: String {
        L10n.text(
            "The hooks structure in settings.json is not recognized; nothing was changed",
            zhHans: "settings.json 的 hooks 结构无法识别，不做改动")
    }

    /// Installs it (or replaces it with the entry pointing at `askPath`). All other entries are
    /// left verbatim. First clears answer entries under **every event**: a single one under
    /// `PreToolUse` is enough to block the confirmation UI
    public static func install(into json: String, askPath: String) throws -> String {
        var root = try ClaudeHooksInstaller.parse(json)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        if ClaudeHooksInstaller.unsupportedShapeEvent(in: hooks) != nil {
            throw InstallError.foreignConfig(unrecognizedShapeMessage)
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
            throw InstallError.foreignConfig(unrecognizedShapeMessage)
        }
        hooks = removingAskEntries(from: hooks)
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return try ClaudeHooksInstaller.serialize(root)
    }

    /// Whether it is installed, points at `askPath`, has the exact matcher, and no other event
    /// holds an answer entry (if one does, it counts as not properly installed; the auto-update at
    /// launch rewrites and clears it)
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

    /// Whether any of our answer entries exists (regardless of path)
    public static func hasAnyEntry(in json: String) -> Bool {
        guard let root = try? ClaudeHooksInstaller.parse(json),
              let hooks = root["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            (value as? [[String: Any]] ?? []).contains(where: isAskEntry)
        }
    }

    /// Removes the answer entries under each event; an event left empty as a result is deleted
    /// along with its key; all other entries are left verbatim
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
