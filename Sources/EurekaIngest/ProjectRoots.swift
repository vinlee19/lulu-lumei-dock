import Foundation

/// 近期会话的项目工作目录集合（供「项目级技能 / 项目级 agent」发现复用）。
/// 复用 Claude/Codex 会话索引，从 transcript 头部拿到**真实 cwd**——
/// `~/.claude/projects/<encoded>` 目录名对 cwd 编码有损（`/` 和 `.` 都变 `-`），不可反解，
/// 必须走索引器解析出的 cwd。
public enum ProjectRoots {
    /// 去重后的近期会话 cwd（保持最近活跃在前的顺序）。含 Claude / Codex / opencode 三源。
    public static func recentCwds(
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        opencodeDbPath: URL? = nil,
        maxSessions: Int = 300
    ) -> [String] {
        var sessions = ClaudeSessionIndexer.index(
            projectsRoot: claudeProjectsRoot, maxSessions: maxSessions)
        sessions += CodexSessionIndexer.index(
            sessionsRoot: codexSessionsRoot, maxSessions: maxSessions)
        var cwds = sessions.compactMap(\.cwd)
        if let opencodeDbPath {
            cwds += OpencodeSessionIndexer.recentDirectories(
                dbPath: opencodeDbPath, maxSessions: maxSessions)
        }
        var seen = Set<String>()
        var result: [String] = []
        for cwd in cwds where !cwd.isEmpty {
            if seen.insert(cwd).inserted { result.append(cwd) }
        }
        return result
    }
}
