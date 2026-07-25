import Foundation

/// 一次「会话 ↔ 终端」绑定：这个 session 在哪个终端里跑过。
///
/// 来源有两条，精度不同，由 `origin` 区分：
/// - `.hook`：relay 从自己继承的环境里读到的（`TERM_PROGRAM` / `__CFBundleIdentifier` /
///   `TMUX_PANE` / `ttyname`）—— 准确，因为 hook 就是那个终端的后代进程。
/// - `.probe`：app 事后按 cwd 匹配运行中的进程、再沿父进程链上溯推出来的 —— 覆盖没装
///   hook 的源，但拿不到 tmux pane，且 tty 可能是 CLI 自己的而不是终端的。
public struct TerminalBinding: Equatable, Sendable, Codable {
    /// 采集来源，决定可信度
    public enum Origin: String, Sendable, Codable {
        case hook
        case probe
    }

    /// `TERM_PROGRAM` 原值，如 "iTerm.app" / "Apple_Terminal" / "ghostty"
    public var app: String?
    /// `__CFBundleIdentifier`，如 "com.googlecode.iterm2"。激活终端应用只认这个
    public var bundleId: String?
    /// 控制终端设备路径，如 "/dev/ttys004"
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

    /// 什么都没采到 —— 调用方据此决定不落库（免得留一堆空行）
    public var isEmpty: Bool {
        app == nil && bundleId == nil && tty == nil && tmuxPane == nil
    }

    /// 人读的终端名：优先把已知 bundle id 翻成正式名，其次清理 `TERM_PROGRAM`。
    /// 都没有就退到 tty，最后兜底"未知终端"。
    public var terminalName: String {
        if let bundleId, let known = Self.knownTerminals[Self.canonicalBundleId(bundleId)] {
            return known
        }
        if let app, !app.isEmpty {
            // "iTerm.app" → "iTerm"，"Apple_Terminal" → "Terminal"
            if app == "Apple_Terminal" { return "Terminal" }
            return app.hasSuffix(".app") ? String(app.dropLast(4)) : app
        }
        if let bundleId, !bundleId.isEmpty {
            // 未收录的 bundle id：取最后一段总比整串好看（com.foo.bar → bar）
            let canonical = Self.canonicalBundleId(bundleId)
            return canonical.split(separator: ".").last.map(String.init) ?? canonical
        }
        if tty != nil { return "终端" }
        return "未知终端"
    }

    /// tty 的短名：`/dev/ttys004` → `ttys004`
    public var shortTTY: String? {
        tty.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 列表里一行展示用："iTerm2 · ttys004"；tmux 会话额外标出 pane
    public var displayName: String {
        var parts = [terminalName]
        if let shortTTY { parts.append(shortTTY) }
        if let tmuxPane, !tmuxPane.isEmpty { parts.append("tmux \(tmuxPane)") }
        return parts.joined(separator: " · ")
    }

    /// 归一 bundle id：剥掉 JetBrains 的预览版后缀（`com.jetbrains.intellij-EAP` →
    /// `com.jetbrains.intellij`），免得逐个枚举各 IDE 的 EAP / Preview 变体。
    static func canonicalBundleId(_ bundleId: String) -> String {
        for suffix in ["-EAP", "-eap", "-Preview", "-preview"] where bundleId.hasSuffix(suffix) {
            return String(bundleId.dropLast(suffix.count))
        }
        return bundleId
    }

    /// bundle id → 正式名。只收录常见 macOS 终端；未收录不影响功能（退到 TERM_PROGRAM）
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
