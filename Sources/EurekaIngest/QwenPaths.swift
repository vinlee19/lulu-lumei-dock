import Foundation

/// Local data paths of the Qwen Code CLI (default `~/.qwen`, surveyed on v0.20). Hybrid layout:
/// `projects/<Claude-style encoded cwd>/chats/<uuid>.jsonl` (Claude-style envelope + Gemini-style
/// parts payload) + a companion `<uuid>.runtime.json`; global memory `memories/*.md`; skills
/// `skills/<name>/SKILL.md`. `settings.json` holds API keys and must never be included in any
/// backup/upload.
public enum QwenPaths {
    /// Config home (env `EUREKA_QWEN_HOME` > `~/.qwen`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_QWEN_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen", isDirectory: true)
    }

    /// Sessions root `<home>/projects` (one Claude-style encoded directory per project)
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Skills root `<home>/skills` (SKILL.md format identical to Claude's)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Global memory directory `<home>/memories` (*.md)
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }
}
