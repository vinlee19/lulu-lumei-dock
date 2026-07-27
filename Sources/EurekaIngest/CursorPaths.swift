import Foundation

/// Cursor（IDE，3.13.10 实勘）的本地数据路径。
///
/// 与其余来源不同，Cursor **没有 transcript 文件**：全部会话都在
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// 这一个 SQLite 库里（WAL，Cursor 进程常驻持有，本 app 一律只读打开）：
///   - `composerHeaders(composerId, workspaceId, recency, isSubagent, value)`
///     — 已打开 workspace 的会话索引，`value` 里有标题 / ctx% / 待授权标记；
///   - `cursorDiskKV['composerData:<id>']` — 单会话全量（状态、生成中气泡、ctx token）；
///   - `cursorDiskKV['bubbleId:<composerId>:<bubbleId>']` — 单条消息（工具调用、token）。
/// cwd 要经 `workspaceStorage/<wsId>/workspace.json` 反查（见 `CursorWorkspaceIndex`）。
///
/// ⚠️ 同一个 `state.vscdb` 的 `ItemTable` 里存着 `cursorAuth/accessToken`、
/// `cursorAuth/refreshToken`。**这个库绝不能进备份/同步**，Cursor 只有
/// `~/.cursor/skills` 可以纳入（见 `SyncSourceCatalog`）。
public enum CursorPaths {
    /// 应用数据主目录（env `EUREKA_CURSOR_HOME` > `~/Library/Application Support/Cursor`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CURSOR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    }

    /// 全局状态库 `<home>/User/globalStorage/state.vscdb`（会话与消息都在这里）
    public static func globalStateDB(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("User/globalStorage/state.vscdb", isDirectory: false)
    }

    /// 工作区存储根 `<home>/User/workspaceStorage`（每 workspace 一个 hash 目录，
    /// 内含 `workspace.json` 的 folder 字段 = cwd）
    public static func workspaceStorageRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    /// 用户技能根 `~/.cursor/skills/<name>/SKILL.md`（Claude 式布局）。
    /// 注意它不在 `configHome` 下：CLI 侧配置走 `~/.cursor`，IDE 状态走 Application Support。
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// 内置技能根 `~/.cursor/skills-cursor`（Cursor 官方分发、随客户端更新）。
    /// 它自带的 `create-skill` 技能里明写「绝不要在这里创建技能」→ 本 app 只读展示。
    public static func bundledSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("skills-cursor", isDirectory: true)
    }

    /// 用户级子代理定义根 `~/.cursor/agents/<name>.md`（YAML frontmatter + 正文即系统提示）。
    /// 项目级是 `<repo>/.cursor/agents/`，由 ProjectScopeDiscovery 发现。
    public static func agentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// CLI 侧配置目录 `~/.cursor`（技能、规则、子代理、MCP 配置）
    public static func cliHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CURSOR_CLI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor", isDirectory: true)
    }
}
