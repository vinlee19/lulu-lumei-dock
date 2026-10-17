import Foundation

/// Kimi Code CLI local data paths (default `~/.kimi-code`). Kimi officially allows relocating the
/// data directory via `KIMI_CODE_HOME` (the docs say "never assume ~/.kimi-code"), so resolution
/// order is: `EUREKA_KIMI_HOME` (unit tests / explicit override) > `KIMI_CODE_HOME` (follows a CLI
/// relocation) > default. The GUI app does not inherit the shell env — users who relocated
/// KIMI_CODE_HOME in their shell must say so explicitly with EUREKA_KIMI_HOME. Session layout:
/// `sessions/<wd_name_12hex>/<session_uuid>/{state.json, agents/<agentId>/wire.jsonl}`; the old
/// python CLI's `~/.kimi` is obsolete (migrated automatically upstream), so there is no fallback.
public enum KimiPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Config home (env `EUREKA_KIMI_HOME` > `KIMI_CODE_HOME` > `~/.kimi-code`)
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

    /// Session root `<home>/sessions` (overridden by env `EUREKA_KIMI_SESSIONS`)
    public static func sessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_KIMI_SESSIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Main config `<home>/config.toml` (default_model + per-model max_context_size, source of the
    /// ctx% denominator)
    public static func configToml(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("config.toml")
    }

    /// Global memory `<home>/AGENTS.md` (Kimi's only global memory file; the binary's collect()
    /// confirms it is read)
    public static func globalAgentsMd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("AGENTS.md")
    }

    /// System-level skill root `<home>/skills` (overridden by env `EUREKA_KIMI_SKILLS`; SKILL.md
    /// format same as Claude)
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
