import EurekaKit
import Foundation

/// The **diagnostic** verdict for one hook integration.
///
/// Adds an "anomaly" dimension over `InstallStatus`: the old `status(of:)` showed a broken config,
/// a drifted path and a missing relay all as "not installed", so users neither knew something was
/// wrong nor why there was no data. This separates them and states which cases **forbid** automatic
/// writes - a config we can't understand is never "helpfully fixed".
public enum HookDiagnosis: Equatable, Sendable {
    /// No entries of ours (cleanly not installed)
    case notInstalled
    /// All our entries present, pointing at the stable path, relay executable
    case installed
    /// Only some managed events installed - usually the managed set grew after an app upgrade;
    /// clicking update fixes it
    case stale(missing: [String])
    /// Our entries point at something **other than** the stable path (hand-edited, or a leftover
    /// old app-bundle path). This link breaks once the app moves/upgrades, yet the config looks
    /// "installed" - a hidden failure.
    case driftedPath(found: [String])
    /// Our entries still name the relay by its pre-0.36 file name at the stable directory.
    /// They keep working (the old name is a symlink), and since the path is our own,
    /// rewriting them is safe to do automatically.
    case legacyRelayName(found: [String])
    /// The relay referenced by the config is missing or not executable → every event is silently
    /// lost; the hardest case to notice on your own
    case relayMissing(path: String)
    /// The key is taken by someone else and only one is allowed (Codex's top-level notify) → never
    /// changed automatically
    case foreignOccupied(detail: String)
    /// The single-slot key is taken by another program but its value is understood, so
    /// installing wraps it: the relay forwards to the original command, which keeps working
    /// (Codex's top-level notify). `owner` is the short name of that program.
    case chainable(owner: String)
    /// Config structure not recognised (e.g. settings.json is not valid JSON) → writes refused
    case unparseable(reason: String)

    /// All good
    public var isHealthy: Bool { self == .installed }

    /// Whether automatic writes are **forbidden**. Automatic updates must skip these entirely and
    /// tell the user, rather than guess-editing a config we didn't understand.
    public var blocksAutomaticWrite: Bool {
        switch self {
        case .driftedPath, .unparseable, .foreignOccupied: return true
        case .notInstalled, .installed, .stale, .legacyRelayName, .relayMissing, .chainable:
            return false
        }
    }

    /// Whether this counts as "the user already agreed to install it" (decides whether automatic
    /// updates manage it)
    public var isInstalledInSomeForm: Bool {
        switch self {
        case .installed, .stale, .legacyRelayName, .driftedPath, .relayMissing: return true
        case .notInstalled, .unparseable, .foreignOccupied, .chainable: return false
        }
    }

    /// Severity; the UI picks colours from it
    public enum Severity: Sendable { case ok, info, warning, error }

    public var severity: Severity {
        switch self {
        case .installed: return .ok
        case .notInstalled, .legacyRelayName, .chainable: return .info
        case .stale, .driftedPath: return .warning
        case .relayMissing, .unparseable, .foreignOccupied: return .error
        }
    }

    public var label: String {
        switch self {
        case .notInstalled: return L10n.text("Not installed", zhHans: "未安装")
        case .installed: return L10n.text("Installed", zhHans: "已安装")
        case .stale, .legacyRelayName: return L10n.text("Update required", zhHans: "需更新")
        case .driftedPath: return L10n.text("Path no longer valid", zhHans: "路径已失效")
        case .relayMissing: return L10n.text("Relay missing", zhHans: "relay 缺失")
        case .foreignOccupied: return L10n.text("Used by another program", zhHans: "已被他人占用")
        case .chainable: return L10n.text("Can chain installation", zhHans: "可串联安装")
        case .unparseable: return L10n.text("Cannot parse configuration", zhHans: "配置无法解析")
        }
    }

    /// User-facing explanation: what happened, what the consequence is, and what we will / won't do
    public var detail: String? {
        switch self {
        case .notInstalled, .installed:
            return nil
        case .stale(let missing):
            return L10n.format("Missing events: %@. Click “Update” to add them.", zhHans: "缺少事件：%@。点「更新」补齐。", String(missing.joined(separator: L10n.text(", ", zhHans: "、"))))
        case .driftedPath(let found):
            return L10n.text("The configuration does not point to the stable path; events may not arrive:\n", zhHans: "配置指向的不是稳定路径，事件可能收不到：\n")
                + found.joined(separator: "\n")
                + L10n.text("\nTo preserve your manual changes, this will not be fixed automatically. Click “Repair” to use the stable path.", zhHans: "\n为避免覆盖你的手改内容，不会自动修正 —— 点「修复」改为稳定路径。")
        case .legacyRelayName:
            return L10n.format("The configuration still references the old name %@ (kept as a link to the new relay;", zhHans: "配置仍引用旧名 %@（旧名保留为指向新转发器的链接，", String(RelayIdentity.legacyBinaryName))
                + L10n.format(" events still arrive normally). Click “Update” to use %@.", zhHans: "事件照常收到）。点「更新」改用 %@。", String(RelayIdentity.binaryName))
        case .chainable(let owner):
            return L10n.format("Only one notify is allowed; it is currently used by %@. When enabled,", zhHans: "notify 只能有一个，现由 %@ 使用。打开开关后改为先由 ", String(owner))
                + L10n.format(" %@ forwards the notification unchanged to %@ before recording the event, so both work;", zhHans: "%@ 把通知原样转给 %@、再记录事件，两者同时生效；", String(RelayIdentity.binaryName), String(owner))
                + L10n.text(" disabling restores the original notify.", zhHans: "关闭开关会恢复原来的 notify。")
        case .relayMissing(let path):
            return L10n.format("The configured relay does not exist or is not executable:\n%@\n", zhHans: "配置引用的转发器不存在或不可执行：\n%@\n", String(path))
                + L10n.text("All events will be silently discarded. Click “Install/Update” again to recreate it.", zhHans: "所有事件都会被静默丢弃。重新点「安装/更新」可重建。")
        case .foreignOccupied(let detail):
            return detail
        case .unparseable(let reason):
            return L10n.format("%@\nWriting is refused to avoid damaging the file. Please fix it manually before installing.", zhHans: "%@\n拒绝写入以免破坏文件，请先手动修好再回来安装。", String(reason))
        }
    }
}

/// **Someone else's** hook entries in the same config file. Informational only; nothing is ever
/// changed based on it.
public struct ForeignHookReport: Equatable, Sendable {
    /// Event names involved (Claude settings.json and Codex hooks.json both map event → entry
    /// array)
    public var events: [String]
    /// Recognisable short names of others' commands (basename of the first token; the full command
    /// is not shown)
    public var tools: [String]

    public var isEmpty: Bool { tools.isEmpty }

    public init(events: [String] = [], tools: [String] = []) {
        self.events = events
        self.tools = tools
    }

    /// Merges others' entries from two configs (Claude settings.json + Codex hooks.json, scanned
    /// once each)
    public func merging(_ other: ForeignHookReport) -> ForeignHookReport {
        ForeignHookReport(
            events: Array(Set(events).union(other.events)).sorted(),
            tools: Array(Set(tools).union(other.tools)).sorted())
    }
}

/// Resolves the executable path in a hook command line.
///
/// All three real-world forms must be recognised (the local `otty-cli` uses single quotes;
/// recognising only double quotes would drag the closing quote into the short name):
/// - `"…/lululumei-relay" claude-hook` (ours; the path contains spaces, so it must be
///   double-quoted)
/// - `'/opt/homebrew/bin/otty-cli' hook` (someone else's, single quotes)
/// - `/usr/local/bin/tool hook` (unquoted)
enum HookCommandPath {
    private static let quotes: Set<Character> = ["\"", "'"]

    static func extract(from command: String) -> String? {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return nil }
        if quotes.contains(first) {
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: first) else { return nil }
            return String(rest[rest.startIndex..<end])
        }
        // Unquoted: take the first token and strip any leftover paired quotes
        return trimmed.components(separatedBy: " ").first.map { token in
            String(token.drop(while: { quotes.contains($0) })
                .reversed().drop(while: { quotes.contains($0) }).reversed())
        }
    }

    /// Display short name: only the last path component, so the full (possibly long) command isn't
    /// pasted into the UI
    static func shortName(of command: String) -> String? {
        guard let path = extract(from: command) else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
}
