import Foundation

/// Qoder CLI (CN edition) local data paths (default `~/.qoder-cn`, surveyed on v1.1.5).
/// Claude-style layout: `projects/<encoded cwd>/<sessionId>.jsonl` (Claude-style envelope,
/// slug = cwd with `/` replaced by `-`) + companion `<sessionId>/subagents/agent-*.jsonl`;
/// plans `plans/<slug>.md`; memory `memories/<user-hash>/global/<category>/`.
/// CLI binary `bin/qoderclicn/qoderclicn-<version>` (the version is in the file name).
/// ⚠️ `.auth/` holds credentials and `settings.json` contains API keys; neither may ever be
/// included in any backup/upload.
public enum QoderPaths {
    /// Config home (env `EUREKA_QODER_HOME` > `QODER_CONFIG_DIR` > `~/.qoder-cn`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_QODER_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let custom = environment["QODER_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".qoder-cn", isDirectory: true)
    }

    /// Session root `<home>/projects` (one encoded-cwd directory per project)
    public static func projectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// Skill root `<home>/skills` (same shape as CodeBuddy; ⚠️ Qoder is not installed locally, not
    /// surveyed)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("skills", isDirectory: true)
    }

    /// Plan document root `<home>/plans` (plan mode's <slug>.md)
    public static func plansRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("plans", isDirectory: true)
    }

    /// Memory root `<home>/memories` (<user-hash>/global/<category>/)
    public static func memoriesRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment)
            .appendingPathComponent("memories", isDirectory: true)
    }

    /// CLI binary `<home>/bin/qoderclicn/qoderclicn-<version>`; the version is in the file name, so
    /// glob and take the highest semantic version; nil if none found
    public static func cliBinary(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        let dir = configHome(environment: environment)
            .appendingPathComponent("bin/qoderclicn", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let prefix = "qoderclicn-"
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .max { lhs, rhs in
                compareVersions(
                    String(lhs.lastPathComponent.dropFirst(prefix.count)),
                    String(rhs.lastPathComponent.dropFirst(prefix.count))) == .orderedAscending
            }
    }

    /// Semantic version comparison (numeric segments compared one by one; non-numeric segments fall
    /// back to lexicographic order)
    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = lhs.split(separator: ".", omittingEmptySubsequences: false)
        let b = rhs.split(separator: ".", omittingEmptySubsequences: false)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : "0"
            let y = i < b.count ? b[i] : "0"
            if let xi = Int(x), let yi = Int(y), xi != yi {
                return xi < yi ? .orderedAscending : .orderedDescending
            }
            if Int(x) == nil || Int(y) == nil, x != y {
                return String(x).compare(String(y))
            }
        }
        return .orderedSame
    }
}
