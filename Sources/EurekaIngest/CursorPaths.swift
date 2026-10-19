import Foundation

/// Local data paths for Cursor (the IDE, verified on 3.13.10).
///
/// Unlike every other source, Cursor has **no transcript files**: all sessions live in
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`
/// this one SQLite database (WAL, held open by the resident Cursor process; this app always opens
/// it read-only):
///   - `composerHeaders(composerId, workspaceId, recency, isSubagent, value)`
///     — session index for open workspaces; `value` holds the title / ctx% / pending-permission
///     flag;
///   - `cursorDiskKV['composerData:<id>']` — one full session (status, in-progress bubble, ctx
///     tokens);
///   - `cursorDiskKV['bubbleId:<composerId>:<bubbleId>']` — one message (tool calls, tokens).
/// cwd has to be looked up via `workspaceStorage/<wsId>/workspace.json` (see
/// `CursorWorkspaceIndex`).
///
/// ⚠️ The `ItemTable` of the same `state.vscdb` stores `cursorAuth/accessToken` and
/// `cursorAuth/refreshToken`. **This database must never be backed up/synced**; for Cursor only
/// `~/.cursor/skills` may be included (see `SyncSourceCatalog`).
public enum CursorPaths {
    /// App data home (env `EUREKA_CURSOR_HOME` > `~/Library/Application Support/Cursor`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CURSOR_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
    }

    /// Global state database `<home>/User/globalStorage/state.vscdb` (sessions and messages all
    /// live here)
    public static func globalStateDB(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("User/globalStorage/state.vscdb", isDirectory: false)
    }

    /// Workspace storage root `<home>/User/workspaceStorage` (one hash directory per workspace,
    /// whose `workspace.json` folder field = cwd)
    public static func workspaceStorageRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("User/workspaceStorage", isDirectory: true)
    }

    /// User skill root `~/.cursor/skills/<name>/SKILL.md` (Claude-style layout).
    /// Note it isn't under `configHome`: CLI-side config lives in `~/.cursor`, IDE state in
    /// Application Support.
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Built-in skill root `~/.cursor/skills-cursor` (distributed by Cursor itself, updated with
    /// the client). Its bundled `create-skill` skill says outright "never create skills here" →
    /// this app only displays it read-only.
    public static func bundledSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("skills-cursor", isDirectory: true)
    }

    /// User-level subagent definition root `~/.cursor/agents/<name>.md` (YAML frontmatter + body as
    /// the system prompt). The project level is `<repo>/.cursor/agents/`, discovered by
    /// ProjectScopeDiscovery.
    public static func agentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        cliHome(environment: environment)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// CLI-side config directory `~/.cursor` (skills, rules, subagents, MCP config)
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
