import Foundation

/// 「以此 prompt 在终端启动新会话」的命令拼装。纯字符串函数，可单测。
///
/// v1 白名单只有 claude / codex —— 两者已验证支持位置参数 prompt
/// （`claude '…'` / `codex '…'`）。其余源的 CLI 是否接受位置 prompt 未实勘，
/// 返回 nil，UI 隐藏该动作（复制提问原文仍可用）。
public enum PromptLaunchCommand {
    public static func cliExecutable(for source: AgentSource) -> String? {
        switch source {
        case .claude: return "claude"
        case .codex: return "codex"
        default: return nil
        }
    }

    /// `cd '<cwd>' && <cli> '<prompt>'`；无 cwd 时省略前缀
    public static func build(cli: String, cwd: String?, prompt: String) -> String {
        let quoted = shellSingleQuote(prompt)
        if let cwd, !cwd.isEmpty {
            return "cd \(shellSingleQuote(cwd)) && \(cli) \(quoted)"
        }
        return "\(cli) \(quoted)"
    }

    /// POSIX 单引号转义：引号内一切字面量，`'` → `'\''`。
    /// 换行单独处理成 `'$'\n''` 拼接（zsh/bash 均认）——不是为 shell，而是为
    /// 上层 AppleScript：`do script "…"` 的字符串字面量放不下裸换行，
    /// 转成 $'\n' 后整条命令保持单行。\r 直接丢弃。
    public static func shellSingleQuote(_ raw: String) -> String {
        var body = raw
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "'", with: "'\\''")
        body = body.replacingOccurrences(of: "\n", with: "'$'\\n''")
        return "'\(body)'"
    }
}
