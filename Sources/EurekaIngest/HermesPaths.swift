import Foundation

/// Hermes Agent（Nous Research，v0.19 实勘）的本地数据路径，默认 `~/.hermes`。
///
/// 与其它 CLI 最大的不同：**会话 / 消息 / token / 成本全部在单个 SQLite `state.db` 里**
/// （schema v23，WAL），`~/.hermes/sessions/` 是空目录、不是存储位置。知识库侧：
/// 技能 `skills/<分类>/<名>/SKILL.md`（还有 `<分类>/<子类>/<名>/` 与顶层无分类三种深度），
/// 记忆只有全局 `memories/{MEMORY.md,USER.md}`，全局人格 `SOUL.md`，计划由 `plan` 技能
/// 写到**项目内** `<repo>/.hermes/plans/`（profile 级 `~/.hermes/plans/` 可选）。
///
/// ⚠️ `.env` / `auth.json` 是凭证文件，`config.yaml` 可能含 provider base_url：
/// 任何备份 / 上传都不得纳入这三者，也不得纳入 `state.db`。
public enum HermesPaths {
    /// 配置主目录（env `EUREKA_HERMES_HOME` > `HERMES_HOME` > `~/.hermes`）。
    /// `HERMES_HOME` 是 Hermes 自己认的覆盖变量，跟随它才能和用户实际安装对齐。
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        for key in ["EUREKA_HERMES_HOME", "HERMES_HOME"] {
            if let custom = environment[key], !custom.isEmpty {
                return URL(fileURLWithPath: custom, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes", isDirectory: true)
    }

    /// 会话 / 消息 / 用量库 `<home>/state.db`（只读打开，WAL 感知）
    public static func stateDB(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("state.db")
    }

    /// 技能根 `<home>/skills`（带分类目录层级，需递归扫描）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// 全局记忆目录 `<home>/memories`（只有 MEMORY.md 与 USER.md）
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// 全局人格 / 身份文件 `<home>/SOUL.md`（占系统提示第一槽，等价于用户级 CLAUDE.md）
    public static func soulFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("SOUL.md")
    }

    /// profile 级计划目录 `<home>/plans`（常不存在；项目内计划见 `projectPlansDir`）
    public static func plansRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// 配置文件 `<home>/config.yaml`（技能启停 `skills.disabled` 就在这里）
    public static func configFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("config.yaml")
    }

    /// 技能用量 sidecar `<home>/skills/.usage.json`（use_count / last_used_at，真实命中数据）
    public static func skillUsageFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        skillsRoot(environment: environment).appendingPathComponent(".usage.json")
    }

    /// 项目内计划目录 `<repo>/.hermes/plans`（`plan` 技能的落盘位置）
    public static func projectPlansDir(repoRoot: URL) -> URL {
        repoRoot
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// 全部 HERMES_HOME：默认 home + `profiles/<name>/`（每个 profile 是完整克隆，
    /// 各有自己的 state.db / config.yaml / skills / memories / SOUL.md）。
    /// 多 profile 用户若只读默认 home 会整段漏数据，故索引器统一走这里。
    public static func allHomes(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let root = configHome(environment: environment)
        var homes = [root]
        let profiles = root.appendingPathComponent("profiles", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: profiles, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
            if isDir == true { homes.append(entry) }
        }
        return homes
    }

    /// 每个 home 下的 state.db（只保留真实存在的）
    public static func allStateDBs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        allHomes(environment: environment)
            .map { $0.appendingPathComponent("state.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
