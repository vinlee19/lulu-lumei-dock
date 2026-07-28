import Foundation

/// 索引用的会话发现：扫各源默认根路径 → `[AgentSessionInfo]`。
///
/// 抽出来是因为**发现本身就是主要成本**：实测 267 个会话、逐文件解析文件头约 60s，
/// 而全文索引与逐轮指标索引原本各自调一遍同样的 8 个 indexer —— 每分钟白付两次。
/// 现在由调用方（`UsageService`）发现一次、两个消费者共用。
///
/// 不含共享库的源（opencode / hermes / cursor）与 antigravity：
/// 前者以 `transcriptPath` 为主键会互相整片覆盖，后者是 protobuf 解不出内容。
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
