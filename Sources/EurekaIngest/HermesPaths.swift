import Foundation

/// Local data paths for Hermes Agent (Nous Research, surveyed on v0.19), default `~/.hermes`.
///
/// The biggest difference from other CLIs: **sessions / messages / tokens / cost all live in a
/// single SQLite `state.db`** (schema v23, WAL); `~/.hermes/sessions/` is an empty directory, not
/// the storage location. Knowledge side: skills `skills/<category>/<name>/SKILL.md` (plus
/// `<category>/<subcategory>/<name>/` and uncategorized top-level — three depths), memory is only
/// the global `memories/{MEMORY.md,USER.md}`, the global persona is `SOUL.md`, and plans are
/// written by the `plan` skill **inside the project** at `<repo>/.hermes/plans/` (profile-level
/// `~/.hermes/plans/` is optional).
///
/// ⚠️ `.env` / `auth.json` are credential files and `config.yaml` may contain a provider base_url:
/// no backup / upload may ever include these three, nor `state.db`.
public enum HermesPaths {
    /// Config home (env `EUREKA_HERMES_HOME` > `HERMES_HOME` > `~/.hermes`). `HERMES_HOME` is
    /// Hermes's own override variable; following it keeps us aligned with the actual install.
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

    /// Session / message / usage db `<home>/state.db` (opened read-only, WAL-aware)
    public static func stateDB(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("state.db")
    }

    /// Skill root `<home>/skills` (has category directory levels; needs a recursive scan)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Global memory directory `<home>/memories` (only MEMORY.md and USER.md)
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// Global persona / identity file `<home>/SOUL.md` (takes the first system-prompt slot,
    /// equivalent to a user-level CLAUDE.md)
    public static func soulFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("SOUL.md")
    }

    /// Profile-level plan directory `<home>/plans` (often absent; for in-project plans see
    /// `projectPlansDir`)
    public static func plansRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// Config file `<home>/config.yaml` (skill enable/disable `skills.disabled` lives here)
    public static func configFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("config.yaml")
    }

    /// Skill usage sidecar `<home>/skills/.usage.json` (use_count / last_used_at, real hit data)
    public static func skillUsageFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        skillsRoot(environment: environment).appendingPathComponent(".usage.json")
    }

    /// In-project plan directory `<repo>/.hermes/plans` (where the `plan` skill writes)
    public static func projectPlansDir(repoRoot: URL) -> URL {
        repoRoot
            .appendingPathComponent(".hermes", isDirectory: true)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// Every HERMES_HOME: the default home + `profiles/<name>/` (each profile is a full clone with
    /// its own state.db / config.yaml / skills / memories / SOUL.md).
    /// Multi-profile users would lose whole swaths of data if only the default home were read, so
    /// the indexers all go through here.
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

    /// state.db under each home (only those that actually exist)
    public static func allStateDBs(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        allHomes(environment: environment)
            .map { $0.appendingPathComponent("state.db") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
