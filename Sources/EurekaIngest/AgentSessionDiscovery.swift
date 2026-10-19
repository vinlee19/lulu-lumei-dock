import Foundation

/// Session discovery for indexing: scan each source's default root → `[AgentSessionInfo]`.
///
/// Factored out because **discovery itself is the main cost**: measured at 267 sessions, parsing
/// each file's head takes ~60s, and the full-text index and the per-turn metrics index each used to
/// call the same 8 indexers on their own -- paying twice a minute for nothing. Now the caller
/// (`UsageService`) discovers once and both consumers share the result.
///
/// Excludes shared-library sources (opencode / hermes / cursor / trae / zcode) and antigravity:
/// the former key on `transcriptPath` and would overwrite each other wholesale; the latter is
/// protobuf whose content can't be decoded. Trae has one more layer: its session DB is
/// SQLCipher-encrypted, so there is no indexable body at all (see `TraeSessionIndexer`).
public enum AgentSessionDiscovery {
    public static func forIndexing() -> [AgentSessionInfo] {
        var sessions = ClaudeSessionIndexer.index(
            projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot())
        sessions += CodexSessionIndexer.index(
            sessionsRoot: CodexRolloutTailer.defaultSessionsRoot())
        sessions += GrokSessionIndexer.index(sessionsRoot: GrokPaths.sessionsRoot())
        sessions += KimiSessionIndexer.index(sessionsRoot: KimiPaths.sessionsRoot())
        sessions += GeminiSessionIndexer.index(
            tmpRoot: GeminiPaths.tmpRoot(), projectsFile: GeminiPaths.projectsFile())
        sessions += QwenSessionIndexer.index(projectsRoot: QwenPaths.projectsRoot())
        sessions += CodeBuddySessionIndexer.index(projectsRoot: CodeBuddyPaths.projectsRoot())
        sessions += QoderSessionIndexer.index(projectsRoot: QoderPaths.projectsRoot())
        return sessions
    }
}
