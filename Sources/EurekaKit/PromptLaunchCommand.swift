import Foundation

/// Builds the command for "start a new session in the terminal with this prompt". Pure string
/// function, unit-testable.
///
/// The v1 allowlist is only claude / codex: both are verified to accept a positional prompt
/// (`claude '...'` / `codex '...'`). Whether other sources' CLIs accept a positional prompt hasn't
/// been verified, so they return nil and the UI hides the action (copying the prompt text still
/// works).
public enum PromptLaunchCommand {
    public static func cliExecutable(for source: AgentSource) -> String? {
        switch source {
        case .claude: return "claude"
        case .codex: return "codex"
        default: return nil
        }
    }

    /// `cd '<cwd>' && <cli> '<prompt>'`; the prefix is omitted without a cwd
    public static func build(cli: String, cwd: String?, prompt: String) -> String {
        let quoted = shellSingleQuote(prompt)
        if let cwd, !cwd.isEmpty {
            return "cd \(shellSingleQuote(cwd)) && \(cli) \(quoted)"
        }
        return "\(cli) \(quoted)"
    }

    /// POSIX single-quote escaping: everything inside quotes is literal, `'` → `'\''`. Newlines are
    /// handled separately as `'$'\n''` concatenation (both zsh and bash accept it). Not for the
    /// shell, but for the AppleScript layer above: the string literal in `do script "..."` can't
    /// hold a bare newline, so converting to $'\n' keeps the whole command on one line. \r is
    /// dropped.
    public static func shellSingleQuote(_ raw: String) -> String {
        var body = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "'", with: "'\\''")
        body = body.replacingOccurrences(of: "\n", with: "'$'\\n''")
        return "'\(body)'"
    }
}
