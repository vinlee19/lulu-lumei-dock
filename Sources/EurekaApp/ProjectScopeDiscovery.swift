import EurekaIngest
import EurekaUsage
import Foundation

/// 近期会话 cwd → 去重的项目仓库根（含项目名）。
/// 供「项目级技能」「项目级 agent」发现共用：技能扫 `<root>/.claude|.codex/skills`，
/// agent 扫 `<root>/.claude/agents`。仓库根解析走 ProjectResolver（向上找 .git）。
enum ProjectScopeDiscovery {
    private static func recentCwds() -> [String] {
        ProjectRoots.recentCwds(
            claudeProjectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
            codexSessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
            opencodeDbPath: OpencodePaths.db())
    }

    static func repoRoots(resolver: ProjectResolver) -> [(root: URL, name: String)] {
        var seen = Set<String>()
        var roots: [(root: URL, name: String)] = []
        for cwd in recentCwds() {
            guard let root = resolver.projectRoot(forCwd: cwd) else { continue }
            if seen.insert(root.path).inserted {
                roots.append((root, root.lastPathComponent))
            }
        }
        return roots
    }

    /// Codex 对每个近期 cwd 按项目根 → cwd 逐级查找 AGENTS.override.md / AGENTS.md。
    static func codexInstructionScopes(
        resolver: ProjectResolver
    ) -> [(directory: URL, projectName: String, scope: String)] {
        var seen = Set<String>()
        var result: [(directory: URL, projectName: String, scope: String)] = []
        for cwd in recentCwds() {
            guard let root = resolver.projectRoot(forCwd: cwd) else { continue }
            let normalizedRoot = root.standardizedFileURL
            let normalizedCwd = URL(fileURLWithPath: cwd).standardizedFileURL
            let rootPath = normalizedRoot.path
            let cwdPath = normalizedCwd.path
            let projectName = normalizedRoot.lastPathComponent
            guard cwdPath == rootPath || cwdPath.hasPrefix(rootPath + "/") else { continue }

            var directories = [normalizedRoot]
            if cwdPath != rootPath {
                let relative = String(cwdPath.dropFirst(rootPath.count + 1))
                var current = normalizedRoot
                for component in relative.split(separator: "/") {
                    current.appendPathComponent(String(component), isDirectory: true)
                    directories.append(current)
                }
            }
            for directory in directories where seen.insert(directory.path).inserted {
                let relative = directory.path == rootPath
                    ? ""
                    : String(directory.path.dropFirst(rootPath.count + 1))
                result.append((
                    directory: directory,
                    projectName: projectName,
                    scope: relative.isEmpty ? projectName : "\(projectName)/\(relative)"
                ))
            }
        }
        return result
    }
}
