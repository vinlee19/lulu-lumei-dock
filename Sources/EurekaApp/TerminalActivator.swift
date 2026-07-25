import AppKit
import EurekaKit
import Foundation

/// 把会话所在的终端**应用**调到前台。
///
/// 刻意只做到「应用级」：
/// - 不用 AppleScript / Apple Events → 不触发「自动化」权限弹窗
/// - 不读辅助功能树 → 不需要 Accessibility 权限
///
/// 代价是无法选中具体标签页：多标签场景下只能把终端应用带到前台，你仍要自己找那一个标签。
/// 要做到标签级需要按终端各写一套（iTerm 按 session GUID、Terminal 按 tty，其余各有 CLI），
/// 并额外采集 `ITERM_SESSION_ID` / `KITTY_WINDOW_ID` —— 留待后续，见方案「明确不做」。
enum TerminalActivator {
    /// 绑定对应的终端应用当前是否在运行。用于把跳转按钮置灰而不是点了没反应。
    static func isRunning(_ binding: TerminalBinding) -> Bool {
        resolve(binding) != nil
    }

    /// 该会话所在的终端**应用**当前是否在前台。
    ///
    /// **只到应用级** —— 分不清是哪个标签页。所以调用方（智能静音）必须假定：
    /// 你开了 5 个 iTerm 标签、任意一个在前台，这里都会返回 true。
    /// 标签级判断需要 AppleScript / 辅助功能树，见方案「明确不做」。
    static func isFrontmost(_ binding: TerminalBinding) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleId = binding.bundleId, !bundleId.isEmpty {
            // 只认 bundle id：Warp 的 TERM_PROGRAM 会伪报成 Apple_Terminal，
            // 退化到名字匹配会把"Terminal 在前台"错判成"Warp 在前台"
            return front.bundleIdentifier == bundleId
        }
        guard let app = binding.app, !app.isEmpty, let name = front.localizedName else {
            return false
        }
        return normalized(name) == normalized(app)
    }

    /// 激活终端应用；成功返回 true。应用已退出 / 认不出来 → false，调用方据此给出提示。
    @discardableResult
    static func activate(_ binding: TerminalBinding) -> Bool {
        guard let app = resolve(binding) else { return false }
        if app.isHidden { app.unhide() }
        return app.activate(options: [])
    }

    /// 从绑定找到运行中的终端应用。优先 bundle id（精确），退化到 TERM_PROGRAM 名字匹配。
    private static func resolve(_ binding: TerminalBinding) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let bundleId = binding.bundleId, !bundleId.isEmpty {
            // bundle id 精确可靠，命中就用，不再往下退化
            // （Warp 的 TERM_PROGRAM 会伪报成 Apple_Terminal，退化匹配会认错人）
            return running.first { $0.bundleIdentifier == bundleId }
        }
        guard let app = binding.app, !app.isEmpty else { return nil }
        let wanted = normalized(app)
        return running.first { candidate in
            guard let name = candidate.localizedName else { return false }
            return normalized(name) == wanted
        }
    }

    /// "iTerm.app" / "Apple_Terminal" / "Terminal" 归一到同一个可比较的形式
    private static func normalized(_ name: String) -> String {
        var value = name.lowercased()
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        if value.hasPrefix("apple_") { value = String(value.dropFirst(6)) }
        return value
    }
}
