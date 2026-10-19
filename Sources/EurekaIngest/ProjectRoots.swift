import Foundation

/// Working directories of recent sessions (reused by project-level skill / project-level agent
/// discovery). Reuses the session indexes of all 13 agent sources to get the **real cwd** from
/// transcript heads — directory names like `~/.claude/projects/<encoded>` encode the cwd lossily
/// (both `/` and `.` become `-`) and cannot be reversed, so the cwd parsed by the indexers must
/// be used.
public enum ProjectRoots {
    /// Deduplicated recent session cwds (most recently active first), aggregated over all 13 sources:
    /// Claude / Codex / opencode / hermes / Kimi / Gemini / Qwen / Grok / CodeBuddy / Qoder /
    /// Antigravity / Cursor / Trae. Only this way do repos used solely with sources such as
    /// kimi/qoder/codebuddy get their project-level skills/memory/agents/plans scanned.
    /// Cursor's cwd is not in the session; it is resolved via workspaceStorage's workspace.json
    /// (see CursorSessionIndexer).
    /// hermes goes through `includeHermes` (reads `~/.hermes/state.db`; there is no explicit root to
    /// pass): users of Hermes alone would otherwise get no repo root at all, and `<repo>/.hermes/plans`
    /// — the default location of Hermes plans — would never be scanned.
    /// Antigravity's cwd is found by raw-scanning session db bytes for `file://` URIs (the protobuf
    /// has no public schema, so best-effort; a miss just means one cwd fewer and does not affect
    /// other sources).
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
        // trae: cwd can only be resolved from the folder in workspace.json (memory library
        // directory names are lossy and cannot be reversed), and a miss means no cwd — so it goes
        // through recentDirectories instead of being merged into sessions
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
