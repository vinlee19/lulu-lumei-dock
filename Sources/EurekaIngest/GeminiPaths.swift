import Foundation

/// Gemini CLI local data paths (default `~/.gemini`, surveyed on v0.51).
/// Layout: `tmp/<project slug>/chats/session-<ts>-<id8>.jsonl` (sessions), `projects.json`
/// (absolute path → slug map, used to resolve a session's cwd), `skills/<name>/SKILL.md`
/// (same shape as Claude), and global memory `GEMINI.md`. The GUI does not inherit the shell
/// env; tests/migration override with EUREKA_GEMINI_HOME.
public enum GeminiPaths {
    /// Config home (env `EUREKA_GEMINI_HOME` > `~/.gemini`)
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    /// Session root `<home>/tmp` (one slug subdirectory per project)
    public static func tmpRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("tmp", isDirectory: true)
    }

    /// Project map `<home>/projects.json` ({"projects": {"/abs/path": "slug"}})
    public static func projectsFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("projects.json")
    }

    /// Skill root `<home>/skills` (SKILL.md format same as Claude)
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }

    /// Global memory `<home>/GEMINI.md`
    public static func globalGeminiMd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("GEMINI.md")
    }

    /// Reads the projects.json reverse lookup: slug → absolute project path
    public static func slugToProject(
        projectsFile: URL
    ) -> [String: String] {
        guard let data = try? Data(contentsOf: projectsFile),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [String: String]
        else { return [:] }
        var reversed: [String: String] = [:]
        for (path, slug) in projects { reversed[slug] = path }
        return reversed
    }
}
