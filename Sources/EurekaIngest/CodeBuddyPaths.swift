import Foundation

/// Local data paths for the CodeBuddy CLI (default `~/.codebuddy`). Layout:
/// `projects/<cwd-slug>/<sessionId>.jsonl` (slug = cwd with `/` → `-`), subagents in the same-named
/// dir `<sessionId>/subagents/agent-*.jsonl`; live session registry `sessions/<pid>.json`; global
/// memory `memery/` (that's the official spelling, see below). Warning: `settings.json` /
/// `mcp.json` may hold API keys / tokens and must never be included in any backup/upload.
public enum CodeBuddyPaths {
    /// Config home (env `EUREKA_CODEBUDDY_HOME` > `CODEBUDDY_CONFIG_DIR` > `~/.codebuddy`)
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

    /// Session root `<home>/projects` (one cwd-slug directory per project)
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Live session registry `<home>/sessions` (`<pid>.json`: sessionId + lastHeartbeat)
    public static func liveSessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Global memory dir `<home>/memery` (the official spelling really is memery, not memory --
    /// don't "fix" it)
    /// Skills root `<home>/skills` (SKILL.md has the same shape as Claude's; surveyed 23 real
    /// directories, not symlinks)
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
