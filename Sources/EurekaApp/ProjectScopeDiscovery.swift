import EurekaIngest
import EurekaUsage
import Foundation

/// 近期会话 cwd → 去重的项目仓库根（含项目名）。
/// 供「项目级技能」「项目级 agent」发现共用：技能扫 `<root>/.claude|.codex/skills`，
/// agent 扫 `<root>/.claude/agents`。仓库根解析走 ProjectResolver（向上找 .git）。
enum ProjectScopeDiscovery {
    static func repoRoots(resolver: ProjectResolver) -> [(root: URL, name: String)] {
        let cwds = ProjectRoots.recentCwds(
            claudeProjectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
            codexSessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
            opencodeDbPath: OpencodePaths.db())
        var seen = Set<String>()
        var roots: [(root: URL, name: String)] = []
        for cwd in cwds {
            guard let root = resolver.projectRoot(forCwd: cwd) else { continue }
            if seen.insert(root.path).inserted {
                roots.append((root, root.lastPathComponent))
            }
        }
        return roots
    }
}
