import Foundation

/// ZCode CLI 的本地数据路径（`~/.zcode`，CLI 随 /Applications/ZCode.app 分发）。
/// env `EUREKA_ZCODE_*` 覆盖，便于单测。
///
/// 磁盘约定（实勘 2026-08，~/.zcode/cli）：
/// - `db/db.sqlite`：会话库（session/message/part/todo 表，schema 与 opencode 同源）
/// - `rollout/model-io-sess_<id>.jsonl`：模型 IO 流水（append-only，含 per-request usage）
/// - `agents/<sess>/agent_<id>/`：子代理目录（metadata.json + transcript.jsonl）
/// - 技能根是共享的 `~/.agents/skills`（非 ~/.zcode 内）
/// ⚠️ `~/.zcode/v2`（含 credentials.json）绝不能进同步/扫描白名单。
public enum ZcodePaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// 主目录 `~/.zcode`（env `EUREKA_ZCODE_HOME`）
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".zcode", isDirectory: true)
    }

    /// CLI 数据根 `~/.zcode/cli`（env `EUREKA_ZCODE_CLI_ROOT`）
    public static func cliRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_CLI_ROOT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return root(environment: environment).appendingPathComponent("cli", isDirectory: true)
    }

    /// 会话库 `~/.zcode/cli/db/db.sqlite`（env `EUREKA_ZCODE_DB`）
    public static func db(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_DB"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("db/db.sqlite")
    }

    /// 模型 IO 流水根 `~/.zcode/cli/rollout`（env `EUREKA_ZCODE_ROLLOUT`）
    public static func rolloutRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_ROLLOUT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("rollout", isDirectory: true)
    }

    /// 子代理根 `~/.zcode/cli/agents`（env `EUREKA_ZCODE_AGENTS`）
    public static func agentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_AGENTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// 系统级技能根 `~/.agents/skills`（env `EUREKA_ZCODE_SKILLS`）。
    /// ZCode 的技能装在共享的 ~/.agents 下（与 ZCode CLI 桌面版共用），不在 ~/.zcode 内。
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".agents/skills", isDirectory: true)
    }
}
