import Foundation

/// Runs a shell command in a new Terminal window (osascript `do script`).
///
/// A shared version of the same technique as `MCPService.openInTerminal` / `SessionBrowserService.resumeInTerminal` /
/// `CLIToolsService.runInTerminal`; currently only new code uses it, and migrating
/// the three old call sites is handled separately (to keep regressions out of scope).
///
/// Constraint: the command must not contain bare newlines -- an AppleScript string literal can't hold them; multi-line content must be
/// converted by the caller into `$'\n'` concatenation first (`PromptLaunchCommand.shellSingleQuote` already guarantees this).
enum TerminalRunner {
    private static let queue = DispatchQueue(
        label: "com.vinlee.eureka.terminal-runner", qos: .userInitiated)

    static func run(command: String) {
        // AppleScript string escaping: backslashes first (the escaping order must not change)
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
