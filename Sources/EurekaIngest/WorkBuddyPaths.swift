import Foundation

/// Local data paths of the WorkBuddy desktop app (Tencent, `/Applications/WorkBuddy.app`). Its
/// agent is the CodeBuddy Code engine run with `CODEBUDDY_CONFIG_DIR=WORKBUDDY_CONFIG_DIR=
/// ~/.workbuddy`, so the layout mirrors `CodeBuddyPaths` under a different home:
/// `projects/<slug>/<sessionId>.jsonl` transcripts, `skills/`, `memory/<userId>_memory.md`,
/// `tasks/<sessionId>/<N>.json` todos, `audit-log/YYYY-MM-DD.jsonl` permission and sandbox events,
/// and `workbuddy.db` (plain SQLite in WAL mode; sessions, titles, automation runs).
///
/// Never read, back up or upload anything else under this home without checking it first. These
/// hold credentials or device identity: `keyblob`, `login-device-nonce`, `device-id*`,
/// `security/`, `cli-env/`, `connectors/**/.credentials*`, `connectors/**/.master.key`,
/// `app/session/` (Electron cookies and storage), `app/connector-keys/`, `local_storage/`,
/// `remote-state/`, `plugin-account-state/`, `wbipc/`, plus `~/.workbuddy-key-fallback` next to
/// it. `mcp.json` (both copies), `models.json` and `settings.json` carry API keys and headers: read
/// key names only, never copy them raw.
public enum WorkBuddyPaths {
    /// Config home (env `EUREKA_WORKBUDDY_HOME` > `WORKBUDDY_CONFIG_DIR` > `~/.workbuddy`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_WORKBUDDY_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = environment["WORKBUDDY_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".workbuddy", isDirectory: true)
    }

    /// Transcript root `<home>/projects` (one cwd-slug directory per working folder)
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("projects", isDirectory: true)
    }

    /// `<home>/workbuddy.db`: WorkBuddy's own session list. Open read-only only
    /// (`WorkBuddySessionCatalog`), never with `immutable=1`: the app holds it open in WAL mode.
    public static func database(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("workbuddy.db")
    }

    /// `<home>/audit-log`: hash-chained daily `YYYY-MM-DD.jsonl` files; the only place a pending
    /// permission prompt is written down (`file-safety.needs-approval`)
    public static func auditLogRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("audit-log", isDirectory: true)
    }

    /// User skills `<home>/skills` (SKILL.md, Claude shape; some entries are symlinks into
    /// `~/.agents/skills`)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }

    /// Skills that come with WorkBuddy's built-in "buddies"
    /// (`buddy-skill-store/cb_*/builtin--skill_<id>/skill_<id>/SKILL.md`); read-only
    public static func buddySkillStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("buddy-skill-store", isDirectory: true)
    }

    /// Every `cb_*/builtin--skill_<id>` directory of the buddy store: each holds one skill
    /// directory (`skill_<id>/SKILL.md`), so each is a skill root one level deep
    public static func buddySkillRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let fm = FileManager.default
        let store = buddySkillStore(environment: environment)
        let buddies = (try? fm.contentsOfDirectory(atPath: store.path)) ?? []
        return buddies.sorted().filter { !$0.hasPrefix(".") }.flatMap { buddy -> [URL] in
            let dir = store.appendingPathComponent(buddy, isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            return entries.sorted().filter { !$0.hasPrefix(".") }
                .map { dir.appendingPathComponent($0, isDirectory: true) }
        }
    }

    /// User memory `<home>/memory/<userId>_memory.md` (+ a `.bak` WorkBuddy keeps beside it)
    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("memory", isDirectory: true)
    }

    /// Todo lists `<home>/tasks/<sessionId>/<N>.json`
    public static func tasksRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("tasks", isDirectory: true)
    }

    /// User rules `<home>/rules/**/*.md` (the engine also reads `<cwd>/.workbuddy/rules`)
    public static func rulesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("rules", isDirectory: true)
    }

    /// Agent definitions `<home>/agents/*.md` (the engine also reads `<cwd>/.workbuddy/agents`)
    public static func agentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("agents", isDirectory: true)
    }

    /// Plugin root `<home>/plugins` (`installed_plugins.json` + `cache/`), Claude Code's layout
    public static func pluginsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("plugins", isDirectory: true)
    }

    /// `<home>/mcp.json`: the user's MCP servers. WorkBuddy hands each session its own generated
    /// config (`--strict-mcp-config`), so this file is shown, never edited. Holds credentials in
    /// `env` / `headers`.
    public static func mcpConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("mcp.json")
    }

    /// Persona workspaces `<home>/user-<userId>-personal/` (`SOUL.md`, `IDENTITY.md`, `USER.md`,
    /// `BOOTSTRAP.md` are the persona's instructions; `MEMORY.md` is its long-term memory)
    public static func personaRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let home = configHome(environment: environment)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        return names
            .filter { $0.hasPrefix("user-") && $0.hasSuffix("-personal") }
            .sorted()
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// Root of the per-task working folders WorkBuddy creates (`~/WorkBuddy/<YYYY-MM-DD-HH-MM-SS>`,
    /// each a session cwd). Env `EUREKA_WORKBUDDY_WORKSPACE` overrides it for tests.
    public static func workspaceRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_WORKBUDDY_WORKSPACE"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("WorkBuddy", isDirectory: true)
    }

    /// Every working folder's memory directory (`<folder>/.workbuddy/memory`: daily logs
    /// `YYYY-MM-DD.md` and `automations/<id>/memory.md`) that exists
    public static func workspaceMemoryRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        let root = workspaceRoot(environment: environment)
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap { name in
            guard !name.hasPrefix(".") else { return nil }
            let memory = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(".workbuddy/memory", isDirectory: true)
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: memory.path, isDirectory: &isDirectory)
                && isDirectory.boolValue ? memory : nil
        }
    }

    /// The installed app (version for the CLI tools page; WorkBuddy has no CLI on PATH)
    public static let appBundle = URL(fileURLWithPath: "/Applications/WorkBuddy.app")
}
