import Foundation

/// Gemini CLI 的本地数据路径（默认 `~/.gemini`，v0.51 实勘）。
/// 布局：`tmp/<项目slug>/chats/session-<ts>-<id8>.jsonl`（会话）、`projects.json`
/// （绝对路径 → slug 映射，反查会话 cwd）、`skills/<name>/SKILL.md`（与 Claude 同构）、
/// 全局记忆 `GEMINI.md`。GUI 不继承 shell env，测试/迁移用 EUREKA_GEMINI_HOME 覆盖。
public enum GeminiPaths {
    /// 配置主目录（env `EUREKA_GEMINI_HOME` > `~/.gemini`）
    public static func configHome(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_GEMINI_HOME"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".gemini", isDirectory: true)
    }

    /// 会话根 `<home>/tmp`（每项目一个 slug 子目录）
    public static func tmpRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("tmp", isDirectory: true)
    }

    /// 项目映射 `<home>/projects.json`（{"projects": {"/abs/path": "slug"}}）
    public static func projectsFile(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("projects.json")
    }

    /// 技能根 `<home>/skills`（SKILL.md 格式与 Claude 同构）
    public static func skillsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("skills", isDirectory: true)
    }

    /// 全局记忆 `<home>/GEMINI.md`
    public static func globalGeminiMd(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        configHome(environment: environment).appendingPathComponent("GEMINI.md")
    }

    /// 读取 projects.json 反查表：slug → 项目绝对路径
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
