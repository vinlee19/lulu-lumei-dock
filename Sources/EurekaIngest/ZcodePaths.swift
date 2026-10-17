import Foundation

/// ZCode CLI local data paths (`~/.zcode`; the CLI ships with /Applications/ZCode.app).
/// Overridable via env `EUREKA_ZCODE_*` for unit tests.
///
/// On-disk layout (observed 2026-08, ~/.zcode/cli):
/// - `db/db.sqlite`: session DB (session/message/part/todo tables, schema shared with opencode)
/// - `rollout/model-io-sess_<id>.jsonl`: model IO log (append-only, with per-request usage)
/// - `agents/<sess>/agent_<id>/`: subagent dirs (metadata.json + transcript.jsonl)
/// - the skills root is the shared `~/.agents/skills` (not inside ~/.zcode)
/// ⚠️ `~/.zcode/v2` (contains credentials.json) must never enter the sync/scan whitelist.
public enum ZcodePaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Home `~/.zcode` (env `EUREKA_ZCODE_HOME`)
    public static func root(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".zcode", isDirectory: true)
    }

    /// CLI data root `~/.zcode/cli` (env `EUREKA_ZCODE_CLI_ROOT`)
    public static func cliRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_CLI_ROOT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return root(environment: environment).appendingPathComponent("cli", isDirectory: true)
    }

    /// Session DB `~/.zcode/cli/db/db.sqlite` (env `EUREKA_ZCODE_DB`)
    public static func db(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_DB"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("db/db.sqlite")
    }

    /// Model IO log root `~/.zcode/cli/rollout` (env `EUREKA_ZCODE_ROLLOUT`)
    public static func rolloutRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_ROLLOUT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("rollout", isDirectory: true)
    }

    /// Subagent root `~/.zcode/cli/agents` (env `EUREKA_ZCODE_AGENTS`)
    public static func agentsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_AGENTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return cliRoot(environment: environment)
            .appendingPathComponent("agents", isDirectory: true)
    }

    /// System-level skills root `~/.agents/skills` (env `EUREKA_ZCODE_SKILLS`).
    /// ZCode installs skills under the shared ~/.agents (shared with the ZCode CLI desktop
    /// app), not inside ~/.zcode.
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".agents/skills", isDirectory: true)
    }

    /// Project-level plans dir `<repo>/.zcode/plans`: plan mode writes
    /// `plan-sess_<sessionId>.md`, real markdown → indexed in place like Hermes, not
    /// materialized (there is no global plans dir).
    public static func projectPlansDir(repoRoot: URL) -> URL {
        repoRoot.appendingPathComponent(".zcode/plans", isDirectory: true)
    }

    /// Project-level skills roots: both ZCode's official `<repo>/.zcode/skills` and the shared
    /// `<repo>/.agents/skills` count
    public static func projectSkillsRoots(repoRoot: URL) -> [URL] {
        [repoRoot.appendingPathComponent(".zcode/skills", isDirectory: true),
         repoRoot.appendingPathComponent(".agents/skills", isDirectory: true)]
    }

    /// Model catalog `~/.zcode/v2/config.json` (env `EUREKA_ZCODE_MODEL_CONFIG`).
    /// Each provider's models.<model>.limit.context is the authoritative ctx% denominator
    /// (GLM-5.3/5.2 = 1M, GLM-5-Turbo = 200K; ZCode maintains these itself across versions).
    /// ⚠️ The v2 dir as a whole holds credentials and never enters the sync whitelist - only
    /// this one named file is **read** here.
    public static func modelConfig(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_ZCODE_MODEL_CONFIG"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return root(environment: environment).appendingPathComponent("v2/config.json")
    }
}
