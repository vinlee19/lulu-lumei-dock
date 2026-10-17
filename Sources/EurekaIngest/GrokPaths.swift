import Foundation

/// grok CLI local data paths (`~/.grok`). Overridable via env `EUREKA_GROK_*` for unit tests.
/// grok stores each session as a directory: `sessions/<url-encoded-cwd>/<session-uuid>/`,
/// containing `events.jsonl` (lifecycle), `summary.json` (metadata), `updates.jsonl` (includes
/// context tokens) and `chat_history.jsonl` (messages). Skills/agents are on-disk directories,
/// same shape as Claude.
public enum GrokPaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Config home `~/.grok` (env `EUREKA_GROK_HOME`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".grok", isDirectory: true)
    }

    /// Session root `~/.grok/sessions` (env `EUREKA_GROK_SESSIONS`)
    public static func sessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_SESSIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("sessions", isDirectory: true)
    }

    /// Active session list `~/.grok/active_sessions.json`
    public static func activeSessions(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("active_sessions.json")
    }

    /// Model catalog cache `~/.grok/models_cache.json` (context_window is the ctx% denominator)
    public static func modelsCache(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("models_cache.json")
    }

    /// Unified log `~/.grok/logs/unified.jsonl` (includes `billing: fetched credits config` quota
    /// snapshots). Overridable via env `EUREKA_GROK_UNIFIED_LOG` for unit tests.
    public static func unifiedLog(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_UNIFIED_LOG"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return configHome(environment: environment)
            .appendingPathComponent("logs/unified.jsonl")
    }

    /// System-level skill root `~/.grok/skills` (env `EUREKA_GROK_SKILLS`)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Built-in/bundled skill root `~/.grok/bundled/skills` (shipped with the grok CLI, read-only)
    public static func bundledSkillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("bundled/skills", isDirectory: true)
    }

    /// System-level agent roots: user `~/.grok/agents` + built-in `~/.grok/bundled/agents`.
    /// When env `EUREKA_GROK_AGENTS` overrides, only that single root is used.
    public static func agentsRoots(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let custom = environment["EUREKA_GROK_AGENTS"], !custom.isEmpty {
            return [URL(fileURLWithPath: custom, isDirectory: true)]
        }
        let base = configHome(environment: environment)
        return [
            base.appendingPathComponent("agents", isDirectory: true),
            base.appendingPathComponent("bundled/agents", isDirectory: true),
        ]
    }

    /// Cross-session memory root `~/.grok/memory` (env `EUREKA_GROK_MEMORY`; experimental, may not
    /// exist)
    public static func memoryRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GROK_MEMORY"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment)
            .appendingPathComponent("memory", isDirectory: true)
    }
}
