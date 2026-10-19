import Foundation

/// opencode local data paths (XDG convention, not ~/Library). Overridable via env
/// `EUREKA_OPENCODE_*` for unit tests. opencode stores sessions/messages/events all in a single
/// SQLite db; skills/agents are on-disk directories.
public enum OpencodePaths {
    private static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    /// Main database `~/.local/share/opencode/opencode.db` (env `EUREKA_OPENCODE_DB`)
    public static func db(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_DB"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return home().appendingPathComponent(".local/share/opencode/opencode.db")
    }

    /// System-level skill root `~/.config/opencode/skills` (env `EUREKA_OPENCODE_SKILLS`)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_SKILLS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return configHome(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }

    /// System-level agent roots: `agents` (plural, per the docs) + `agent` (legacy singular); both
    /// are scanned. When env `EUREKA_OPENCODE_AGENTS` overrides, only that single root is used.
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

    /// Config home `~/.config/opencode` (env `EUREKA_OPENCODE_HOME`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_OPENCODE_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return home().appendingPathComponent(".config/opencode", isDirectory: true)
    }
}
