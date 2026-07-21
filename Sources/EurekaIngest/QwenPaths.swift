import Foundation

/// Qwen Code CLI 的本地数据路径（默认 `~/.qwen`，v0.20 实勘）。
/// 布局为混血格式：`projects/<Claude式编码cwd>/chats/<uuid>.jsonl`（Claude 式信封 +
/// Gemini 式 parts payload）+ 伴随 `<uuid>.runtime.json`；全局记忆 `memories/*.md`；
/// 技能 `skills/<name>/SKILL.md`。⚠️ `settings.json` 含 API key，任何备份/上传都不得纳入。
public enum QwenPaths {
    /// 配置主目录（env `EUREKA_QWEN_HOME` > `~/.qwen`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_QWEN_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qwen", isDirectory: true)
    }

    /// 会话根 `<home>/projects`（每项目一个 Claude 式编码目录）
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// 技能根 `<home>/skills`（SKILL.md 格式与 Claude 同构）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// 全局记忆目录 `<home>/memories`（*.md）
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }
}
