import Foundation

/// CodeBuddy CLI 的本地数据路径（默认 `~/.codebuddy`）。
/// 布局：`projects/<cwd-slug>/<sessionId>.jsonl`（slug = cwd 的 `/` → `-`），
/// 子代理在同名目录 `<sessionId>/subagents/agent-*.jsonl`；活会话注册表 `sessions/<pid>.json`；
/// 全局记忆 `memery/`（官方拼写如此，见下）。⚠️ `settings.json` / `mcp.json` 可能含
/// API key / token，任何备份/上传都不得纳入。
public enum CodeBuddyPaths {
    /// 配置主目录（env `EUREKA_CODEBUDDY_HOME` > `CODEBUDDY_CONFIG_DIR` > `~/.codebuddy`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEBUDDY_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = environment["CODEBUDDY_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codebuddy", isDirectory: true)
    }

    /// 会话根 `<home>/projects`（每项目一个 cwd-slug 目录）
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 活会话注册表 `<home>/sessions`（`<pid>.json`：sessionId + lastHeartbeat）
    public static func liveSessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 全局记忆目录 `<home>/memery`（官方拼写就是 memery，不是 memory，勿"修正"）
    /// 技能根 `<home>/skills`（SKILL.md 与 Claude 同构；实勘 23 个真目录，非软链）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memery", isDirectory: true)
    }
}
