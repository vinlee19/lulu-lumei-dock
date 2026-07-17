import Foundation

/// Kimi Code CLI 的本地数据路径（默认 `~/.kimi-code`）。
/// Kimi 官方允许用 `KIMI_CODE_HOME` 迁移数据目录（文档明言"never assume ~/.kimi-code"），
/// 故解析优先级：`EUREKA_KIMI_HOME`（单测/显式覆盖）> `KIMI_CODE_HOME`（跟随 CLI 迁移）> 默认。
/// 注意 GUI 应用不继承 shell env——用户若在 shell 里迁了 KIMI_CODE_HOME，需用 EUREKA_KIMI_HOME 显式告知。
/// 会话布局：`sessions/<wd_名_12hex>/<session_uuid>/{state.json, agents/<agentId>/wire.jsonl}`；
/// 旧版 python CLI 的 `~/.kimi` 已废弃（官方自动迁移），不做回退。
public enum KimiPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 配置主目录（env `EUREKA_KIMI_HOME` > `KIMI_CODE_HOME` > `~/.kimi-code`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_KIMI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let cli = environment["KIMI_CODE_HOME"], !cli.isEmpty {
            return URL(fileURLWithPath: cli, isDirectory: true)
        }
        return home().appendingPathComponent(".kimi-code", isDirectory: true)
    }

    /// 会话根 `<home>/sessions`（env `EUREKA_KIMI_SESSIONS` 覆盖）
    public static func sessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_KIMI_SESSIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// 主配置 `<home>/config.toml`（default_model + per-model max_context_size，ctx% 分母来源）
    public static func configToml(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("config.toml")
    }

    /// 系统级技能根 `<home>/skills`（env `EUREKA_KIMI_SKILLS` 覆盖；SKILL.md 格式与 Claude 同构）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_KIMI_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }
}
