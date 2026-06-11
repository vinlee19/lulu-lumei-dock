import Foundation

/// 一次 API 调用的 token 用量（两家统一后的记账单位）
public struct UsageRecord: Equatable, Sendable {
    public var source: AgentSource
    public var model: String
    /// 项目名（仓库根归组），按项目统计用
    public var project: String?
    /// 会话 id，会话级费用统计用
    public var sessionId: String?
    public var timestamp: Date
    public var inputTokens: Int
    public var outputTokens: Int
    /// 写入缓存的 token 总量（Claude cache_creation_input_tokens）
    public var cacheCreationTokens: Int
    /// 其中 1h TTL 部分（定价 2x；5m 部分 = 总量 - 1h 部分，定价 1.25x）
    public var cacheCreation1hTokens: Int
    /// 缓存读取（Claude cache_read / Codex cached_input）
    public var cacheReadTokens: Int

    public init(
        source: AgentSource,
        model: String,
        project: String? = nil,
        sessionId: String? = nil,
        timestamp: Date,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        cacheReadTokens: Int = 0
    ) {
        self.source = source
        self.model = model
        self.project = project
        self.sessionId = sessionId
        self.timestamp = timestamp
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.cacheReadTokens = cacheReadTokens
    }
}
