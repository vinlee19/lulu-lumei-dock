import Foundation

/// 近期会话的项目工作目录集合（供「项目级技能 / 项目级 agent」发现复用）。
/// 复用全部 13 个 agent 源的会话索引，从 transcript 头部拿到**真实 cwd**——
/// `~/.claude/projects/<encoded>` 这类目录名对 cwd 编码有损（`/` 和 `.` 都变 `-`），不可反解，
/// 必须走索引器解析出的 cwd。
public enum ProjectRoots {
    /// 去重后的近期会话 cwd（保持最近活跃在前的顺序），聚合全部 13 个源：
    /// Claude / Codex / opencode / hermes / Kimi / Gemini / Qwen / Grok / CodeBuddy / Qoder /
    /// Antigravity / Cursor / Trae。只用 kimi/qoder/codebuddy 等源的仓库，项目级技能/记忆/agent/计划才扫得到。
    /// Cursor 的 cwd 不在会话里，要经 workspaceStorage 的 workspace.json 反查（见 CursorSessionIndexer）。
    /// hermes 走 `includeHermes`（读 `~/.hermes/state.db`，无显式根可传）：只用 Hermes 的用户
    /// 否则拿不到任何 repo 根，`<repo>/.hermes/plans`——Hermes 计划的默认落点——就永远扫不到。
    /// Antigravity 的 cwd 从会话 db 字节里裸扫 `file://` URI（protobuf 无公开 schema，best-effort，
    /// 扫不到就只是少一个 cwd，不影响其它源）。
    public static func recentCwds(
        claudeProjectsRoot: URL,
        codexSessionsRoot: URL,
        opencodeDbPath: URL? = nil,
        includeHermes: Bool = false,
        kimiSessionsRoot: URL = KimiPaths.sessionsRoot(),
        geminiTmpRoot: URL = GeminiPaths.tmpRoot(),
        geminiProjectsFile: URL = GeminiPaths.projectsFile(),
        qwenProjectsRoot: URL = QwenPaths.projectsRoot(),
        grokSessionsRoot: URL = GrokPaths.sessionsRoot(),
        codeBuddyProjectsRoot: URL = CodeBuddyPaths.projectsRoot(),
        qoderProjectsRoot: URL = QoderPaths.projectsRoot(),
        antigravityConversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        cursorStateDB: URL = CursorPaths.globalStateDB(),
        cursorWorkspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        traeMemoryProjectsRoot: URL = TraePaths.memoryProjectsRoot(),
        traeWorkspaceStorageRoots: [URL] = TraePaths.workspaceStorageRoots(),
        maxSessions: Int = 300
    ) -> [String] {
        var sessions = ClaudeSessionIndexer.index(
            projectsRoot: claudeProjectsRoot, maxSessions: maxSessions)
        sessions += CodexSessionIndexer.index(
            sessionsRoot: codexSessionsRoot, maxSessions: maxSessions)
        sessions += KimiSessionIndexer.index(
            sessionsRoot: kimiSessionsRoot, maxSessions: maxSessions)
        sessions += GeminiSessionIndexer.index(
            tmpRoot: geminiTmpRoot, projectsFile: geminiProjectsFile, maxSessions: maxSessions)
        sessions += QwenSessionIndexer.index(
            projectsRoot: qwenProjectsRoot, maxSessions: maxSessions)
        sessions += GrokSessionIndexer.index(
            sessionsRoot: grokSessionsRoot, maxSessions: maxSessions)
        sessions += CodeBuddySessionIndexer.index(
            projectsRoot: codeBuddyProjectsRoot, maxSessions: maxSessions)
        sessions += QoderSessionIndexer.index(
            projectsRoot: qoderProjectsRoot, maxSessions: maxSessions)
        sessions += AntigravitySessionIndexer.index(
            conversationsRoot: antigravityConversationsRoot, maxSessions: maxSessions)
        sessions += CursorSessionIndexer.index(
            dbPath: cursorStateDB, workspaceStorageRoot: cursorWorkspaceStorageRoot,
            maxSessions: maxSessions)
        var cwds = sessions.compactMap(\.cwd)
        // trae：cwd 只能从 workspace.json 的 folder 反查（记忆库目录名有损不可反解），
        // 反查不中就没有 cwd —— 所以走 recentDirectories 而不是并进 sessions
        cwds += TraeSessionIndexer.recentDirectories(
            memoryProjectsRoot: traeMemoryProjectsRoot,
            workspaceStorageRoots: traeWorkspaceStorageRoots,
            maxSessions: maxSessions)
        if let opencodeDbPath {
            cwds += OpencodeSessionIndexer.recentDirectories(
                dbPath: opencodeDbPath, maxSessions: maxSessions)
        }
        if includeHermes {
            cwds += HermesSessionIndexer.recentDirectories(maxSessions: maxSessions)
        }
        var seen = Set<String>()
        var result: [String] = []
        for cwd in cwds where !cwd.isEmpty {
            if seen.insert(cwd).inserted { result.append(cwd) }
        }
        return result
    }
}
