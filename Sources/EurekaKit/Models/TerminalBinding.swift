import Foundation

/// One session <-> terminal binding: which terminal this session ran in.
///
/// There are two sources with different precision, told apart by `origin`:
/// - `.hook`: read by the relay from the environment it inherited (`TERM_PROGRAM` /
///   `__CFBundleIdentifier` / `TMUX_PANE` / `ttyname`). Accurate, because the hook is a descendant
///   process of that terminal.
/// - `.probe`: inferred by the app after the fact by matching running processes on cwd and walking
///   up the parent chain. Covers sources without hooks, but can't get the tmux pane, and the tty
///   may be the CLI's own rather than the terminal's.
public struct TerminalBinding: Equatable, Sendable, Codable {
    /// Where it was collected from; determines trustworthiness
    public enum Origin: String, Sendable, Codable {
        case hook
        case probe
    }

    /// Raw `TERM_PROGRAM`, e.g. "iTerm.app" / "Apple_Terminal" / "ghostty"
    public var app: String?
    /// `__CFBundleIdentifier`, e.g. "com.googlecode.iterm2". Activating the terminal app only
    /// trusts this
    public var bundleId: String?
    /// Controlling terminal device path, e.g. "/dev/ttys004"
    public var tty: String?
    public var tmuxPane: String?
    public var origin: Origin

    public init(
        app: String? = nil,
        bundleId: String? = nil,
        tty: String? = nil,
        tmuxPane: String? = nil,
        origin: Origin = .hook
    ) {
        self.app = app
        self.bundleId = bundleId
        self.tty = tty
        self.tmuxPane = tmuxPane
        self.origin = origin
    }

    /// Nothing was collected; callers use this to skip persisting (avoids piling up empty rows)
    public var isEmpty: Bool {
        app == nil && bundleId == nil && tty == nil && tmuxPane == nil
    }

    /// Human-readable terminal name: prefer mapping a known bundle id to its proper name, then a
    /// cleaned-up `TERM_PROGRAM`. With neither, fall back to the tty, and finally to "unknown
    /// terminal".
    public var terminalName: String {
        if let bundleId, let known = Self.knownTerminals[Self.canonicalBundleId(bundleId)] {
            return known
        }
        if let app, !app.isEmpty {
            // "iTerm.app" → "iTerm", "Apple_Terminal" → "Terminal"
            if app == "Apple_Terminal" { return "Terminal" }
            return app.hasSuffix(".app") ? String(app.dropLast(4)) : app
        }
        if let bundleId, !bundleId.isEmpty {
            // unlisted bundle id: the last segment beats the whole string (com.foo.bar → bar)
            let canonical = Self.canonicalBundleId(bundleId)
            return canonical.split(separator: ".").last.map(String.init) ?? canonical
        }
        if tty != nil { return L10n.text("Terminal", zhHans: "终端") }
        return L10n.text("Unknown terminal", zhHans: "未知终端")
    }

    /// Short tty name: `/dev/ttys004` → `ttys004`
    public var shortTTY: String? {
        tty.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// One-line display for lists: "iTerm2 · ttys004"; tmux sessions also show the pane
    public var displayName: String {
        var parts = [terminalName]
        if let shortTTY { parts.append(shortTTY) }
        if let tmuxPane, !tmuxPane.isEmpty { parts.append("tmux \(tmuxPane)") }
        return parts.joined(separator: " · ")
    }

    /// Normalize the bundle id: strip JetBrains preview suffixes (`com.jetbrains.intellij-EAP` →
    /// `com.jetbrains.intellij`) so we don't have to enumerate every IDE's EAP / Preview variant.
    static func canonicalBundleId(_ bundleId: String) -> String {
        for suffix in ["-EAP", "-eap", "-Preview", "-preview"] where bundleId.hasSuffix(suffix) {
            return String(bundleId.dropLast(suffix.count))
        }
        return bundleId
    }

    /// bundle id → proper name. Only common macOS terminals are listed; unlisted ones still work
    /// (fall back to TERM_PROGRAM)
    static let knownTerminals: [String: String] = [
        "com.googlecode.iterm2": "iTerm2",
        "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty",
        "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "dev.warp.Warp-Stable": "Warp",
        "co.zeit.hyper": "Hyper",
        "com.microsoft.VSCode": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "dev.zed.Zed": "Zed",
        "com.jetbrains.intellij": "IntelliJ IDEA",
        "com.jetbrains.pycharm": "PyCharm",
        "com.jetbrains.WebStorm": "WebStorm",
        "com.jetbrains.goland": "GoLand",
        "com.apple.dt.Xcode": "Xcode",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.exafunction.windsurf": "Windsurf",
    ]
}
