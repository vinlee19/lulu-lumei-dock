import Foundation

/// opencode 的本地数据路径（XDG 约定，非 ~/Library）。env `EUREKA_OPENCODE_*` 覆盖，便于单测。
/// opencode 把会话/消息/事件全存在单个 SQLite 库里；技能/agent 是磁盘上的目录。
public enum OpencodePaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 主数据库 `~/.local/share/opencode/opencode.db`（env `EUREKA_OPENCODE_DB`）
    public static func db(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_DB"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home().appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// 系统级技能根 `~/.config/opencode/skills`（env `EUREKA_OPENCODE_SKILLS`）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }

    /// 系统级 agent 根：`agents`（文档复数）+ `agent`（历史单数），两者都扫。
    /// env `EUREKA_OPENCODE_AGENTS` 覆盖时只用该单一根。
    public static func agentsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let custom = environment["EUREKA_OPENCODE_AGENTS"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        let base = configHome(environment: environment)
        return [
            base.appendingPathComponent("agents", isDirectory: true),
            base.appendingPathComponent("agent", isDirectory: true),
        ]
    }

    /// 配置主目录 `~/.config/opencode`（env `EUREKA_OPENCODE_HOME`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".config/opencode", isDirectory: true)
    }
}
