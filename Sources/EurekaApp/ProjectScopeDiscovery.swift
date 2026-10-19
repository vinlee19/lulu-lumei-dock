import EurekaIngest
import EurekaUsage
import Foundation

/// Recent session cwds (all 11 agent sources, see ProjectRoots.recentCwds) → deduped project repo
/// roots (with project names).
/// Shared by "project-level skills" and "project-level agents" discovery: skills scan
/// `<root>/.claude|.codex|.opencode|.grok|
/// .gemini|.kimi-code|.qwen/skills`, agents scan `<root>/.claude|.opencode|.grok/agents`.
/// Repo roots are resolved via ProjectResolver (walks up looking for .git).
enum ProjectScopeDiscovery {
    /// Short-lived cache of recent cwds.
    ///
    /// **Why it exists**: startup warm-up pays for the same IO 4 times in a row:
    /// `SkillMemoryService` calls it twice in a single refresh (`repoRoots` +
    /// `codexInstructionScopes`), and `PlansService` and `AgentConfigService` once each. This
    /// discovery walks the sessions of 12 sources and reads each file's head; even after the Codex
    /// indexer fix it still takes about 6 s, so ×4 is 24 s of pure repetition. The indexing side
    /// has long shared a single discovery (see the comment on `AgentSessionDiscovery.forIndexing`);
    /// the knowledge side never did.
    ///
    /// TTL is 60 s: the four warm-up calls cluster within a few seconds of launch, so that covers them;
    /// a user hitting "Refresh" won't get day-old data either.
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

        // Do the slow work outside the lock: this function takes seconds, and holding the lock
        // would serialize every concurrent service thread. The cost is that in the extreme case two
        // threads may compute it at the same time; the result is identical and idempotent, which
        // beats waiting in line.
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

    /// Drops the cache when the user hits "Force Refresh" (otherwise a refresh within 60 s would
    /// still return the old discovery).
    static func invalidateCache() {
        cacheLock.lock()
        cachedCwds = nil
        cacheLock.unlock()
    }

    static func repoRoots(resolver: ProjectResolver) -> [(root: URL, name: String)] {
        // home itself is not a project: ProjectResolver falls back to cwd when it finds no .git, so
        // if a session ever ran in ~, the fallback is home, and system roots like ~/.claude/skills
        // would be scanned a second time as "project-level", yielding two entries with the same
        // path for one file (doubled counts + holes in the SwiftUI grid from duplicate ids).
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

    /// For each recent cwd, Codex looks for AGENTS.override.md / AGENTS.md level by level from the
    /// project root → cwd.
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
