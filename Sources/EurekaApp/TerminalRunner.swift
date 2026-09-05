import Foundation

/// 在 Terminal 新窗口执行一条 shell 命令（osascript `do script`）。
///
/// 与 `MCPService.openInTerminal` / `SessionBrowserService.resumeInTerminal` /
/// `CLIToolsService.runInTerminal` 是同一手法的共享版本；当前只有新代码使用，
/// 旧三处的迁移另行处理（避免混入回归面）。
///
/// 约束：命令内不得含裸换行 —— AppleScript 字符串字面量放不下；多行内容须由
/// 调用方先转成 `$'\n'` 拼接（`PromptLaunchCommand.shellSingleQuote` 已保证）。
enum TerminalRunner {
    private static let queue = DispatchQueue(
        label: "com.vinlee.eureka.terminal-runner", qos: .userInitiated)

    static func run(command: String) {
        // AppleScript 字符串转义：反斜杠先行（转义顺序不可换）
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }
}
