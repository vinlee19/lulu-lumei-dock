import EurekaIngest
import EurekaUsage
import Foundation

/// 近期会话 cwd（全部 11 个 agent 源，见 ProjectRoots.recentCwds）→ 去重的项目仓库根（含项目名）。
/// 供「项目级技能」「项目级 agent」发现共用：技能扫 `<root>/.claude|.codex|.opencode|.grok|
/// .gemini|.kimi-code|.qwen/skills`，agent 扫 `<root>/.claude|.opencode|.grok/agents`。
/// 仓库根解析走 ProjectResolver（向上找 .git）。
enum ProjectScopeDiscovery {
    /// 近期 cwd 的短期缓存。
    ///
    /// **为什么需要**：启动预热会连着付 4 次同样的 IO —— `SkillMemoryService` 一次 refresh 里就调两次
    /// （`repoRoots` + `codexInstructionScopes`），`PlansService`、`AgentConfigService` 各一次。
    /// 这份发现要遍历 12 个源的会话并逐个读文件头，修完 Codex 索引器后仍需约 6 s，×4 就是 24 s
    /// 的纯重复。索引侧早就共享过一次发现（见 `AgentSessionDiscovery.forIndexing` 的注释），
    /// 知识库这侧一直没有。
    ///
    /// TTL 取 60 s：预热的四次调用集中在启动后几秒内，够覆盖；用户点「刷新」时也不会拿到隔夜数据。
    private static let cacheTTL: TimeInterval = 60
    private static let cacheLock = NSLock()
    private static var cachedCwds: (value: [String], at: Date)?

    private static func recentCwds() -> [String] {
        cacheLock.lock()
        if let cached = cachedCwds, Date().timeIntervalSince(cached.at) < cacheTTL {
            cacheLock.unlock()
            return cached.value
        }
        cacheLock.unlock()

        // 锁外做慢活：这函数要几秒，持锁会把并发的服务线程全串起来。
        // 代价是极端情况下可能有两个线程同时算一遍 —— 结果相同、幂等，比串行等待划算。
        let fresh = ProjectRoots.recentCwds(
            claudeProjectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
            codexSessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
            opencodeDbPath: OpencodePaths.db(),
            includeHermes: true)
        cacheLock.lock()
        cachedCwds = (fresh, Date())
        cacheLock.unlock()
        return fresh
    }

    /// 用户点「强制刷新」时丢弃缓存（否则 60 s 内点刷新拿到的还是旧发现）。
    static func invalidateCache() {
        cacheLock.lock()
        cachedCwds = nil
        cacheLock.unlock()
    }

    static func repoRoots(resolver: ProjectResolver) -> [(root: URL, name: String)] {
        // home 自身不是项目：ProjectResolver 找不到 .git 时回退 cwd，若会话就在 ~ 里跑过，
        // 回退值即 home——那样 ~/.claude/skills 等系统根会被当成「项目级」再扫一遍，
        // 同一文件产出两条同 path 条目（计数翻倍 + SwiftUI 网格因重复 id 出现空洞）。
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var seen = Set<String>()
        var roots: [(root: URL, name: String)] = []
        for cwd in recentCwds() {
            guard let root = resolver.projectRoot(forCwd: cwd) else { continue }
            let path = root.standardizedFileURL.path
            guard path != home, path != "/" else { continue }
            if seen.insert(path).inserted {
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
