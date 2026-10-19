import Foundation

// Pure models for AI session summaries (issue #12). No IO: the snapshot builder lives in
// EurekaIngest, persistence in EurekaStore, process execution in EurekaSummary.

/// Local CLI that writes the summary. Independent of the summarized session's own source:
/// Claude Code may summarize an OpenCode session and vice versa.
public enum SummaryExecutorKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex
    case opencode

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        }
    }

    /// Executable name resolved through the login shell (a constant, never user input)
    public var commandName: String {
        switch self {
        case .claude: return "claude"
        case .codex: return "codex"
        case .opencode: return "opencode"
        }
    }

    /// Same brand icon as the matching session source
    public var source: AgentSource {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        }
    }
}

/// Run lifecycle. The first eight are progress stages; the last three are terminal failures.
public enum SummaryStage: String, Codable, Sendable, CaseIterable {
    case queued
    case reading
    case preparing
    case launching
    case waiting
    case summarizing
    case merging
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: return true
        default: return false
        }
    }

    public var isActive: Bool { !isTerminal }

    public var label: String {
        switch self {
        case .queued: return L10n.text("Queued", zhHans: "排队中")
        case .reading: return L10n.text("Reading the conversation", zhHans: "读取对话")
        case .preparing: return L10n.text("Preparing input", zhHans: "准备输入")
        case .launching: return L10n.text("Starting the CLI", zhHans: "启动 CLI")
        case .waiting: return L10n.text("Waiting for the response", zhHans: "等待响应")
        case .summarizing: return L10n.text("Summarizing", zhHans: "正在总结")
        case .merging: return L10n.text("Merging parts", zhHans: "合并分段")
        case .completed: return L10n.text("Completed", zhHans: "已完成")
        case .failed: return L10n.text("Failed", zhHans: "失败")
        case .cancelled: return L10n.text("Cancelled", zhHans: "已取消")
        case .interrupted: return L10n.text("Interrupted", zhHans: "已中断")
        }
    }
}

/// Why a run did not produce a summary. Each kind maps to an actionable hint.
public enum SummaryFailureKind: String, Codable, Sendable, CaseIterable {
    case unsupportedSource
    case readFailed
    case emptyConversation
    case executorUnavailable
    case launchFailed
    case authentication
    case executorError
    case malformedOutput
    case emptyOutput
    case nonzeroExit
    case timeout
    case cancelled
    case interrupted

    public var label: String {
        switch self {
        case .unsupportedSource: return L10n.text("This source can't be summarized", zhHans: "该来源无法总结")
        case .readFailed: return L10n.text("The conversation could not be read", zhHans: "无法读取对话")
        case .emptyConversation: return L10n.text("The conversation has no readable messages", zhHans: "对话没有可读的消息")
        case .executorUnavailable: return L10n.text("The selected CLI is not available", zhHans: "所选 CLI 不可用")
        case .launchFailed: return L10n.text("The CLI could not be started", zhHans: "无法启动 CLI")
        case .authentication: return L10n.text("The CLI is not signed in", zhHans: "CLI 未登录或鉴权失败")
        case .executorError: return L10n.text("The CLI reported an error", zhHans: "CLI 返回了错误")
        case .malformedOutput: return L10n.text("The CLI output could not be understood", zhHans: "无法解析 CLI 输出")
        case .emptyOutput: return L10n.text("The CLI returned an empty summary", zhHans: "CLI 返回了空总结")
        case .nonzeroExit: return L10n.text("The CLI exited with an error", zhHans: "CLI 异常退出")
        case .timeout: return L10n.text("The CLI timed out", zhHans: "CLI 超时")
        case .cancelled: return L10n.text("Cancelled", zhHans: "已取消")
        case .interrupted: return L10n.text("Interrupted when the app quit", zhHans: "应用退出时被中断")
        }
    }

    public var recoveryHint: String {
        switch self {
        case .unsupportedSource, .emptyConversation:
            return L10n.text("Nothing to summarize for this session.", zhHans: "这个会话没有可总结的内容。")
        case .readFailed:
            return L10n.text("Check that the session file still exists, then retry.", zhHans: "确认会话文件仍然存在后重试。")
        case .executorUnavailable, .launchFailed:
            return L10n.text("Install the CLI or pick another one, then retry.", zhHans: "安装该 CLI 或换一个执行器后重试。")
        case .authentication:
            return L10n.text("Run the CLI once in Terminal and sign in, then retry.", zhHans: "在终端里运行一次该 CLI 并完成登录后重试。")
        case .executorError, .nonzeroExit, .malformedOutput, .emptyOutput:
            return L10n.text("Retry, or choose another CLI or model.", zhHans: "重试，或换一个 CLI / 模型。")
        case .timeout:
            return L10n.text("The session may be very long; retry or choose a faster model.", zhHans: "会话可能很长；重试或换一个更快的模型。")
        case .cancelled, .interrupted:
            return L10n.text("Start it again when you're ready.", zhHans: "需要时重新开始即可。")
        }
    }
}

/// What part of the conversation a run covered. Persisted as JSON on the run row.
public struct SummaryCoverage: Equatable, Codable, Sendable {
    /// Normalized messages in the snapshot (every one of them is sent to the executor)
    public var totalMessages: Int
    public var userMessages: Int
    public var firstMessageId: Int?
    public var lastMessageId: Int?
    /// Tool steps folded into compact activity lines (intentional reduction, not omission)
    public var compactedToolSteps: Int
    /// Thinking messages left out by policy
    public var excludedThinking: Int
    public var chunkCount: Int
    /// Messages too large for one chunk, split into consecutive parts
    public var splitMessages: Int
    public var estimatedTokens: Int
    /// Citations to source messages kept / dropped because they named no snapshot message
    public var validReferences: Int
    public var droppedReferences: Int

    public init(
        totalMessages: Int = 0, userMessages: Int = 0, firstMessageId: Int? = nil,
        lastMessageId: Int? = nil, compactedToolSteps: Int = 0, excludedThinking: Int = 0,
        chunkCount: Int = 0, splitMessages: Int = 0, estimatedTokens: Int = 0,
        validReferences: Int = 0, droppedReferences: Int = 0
    ) {
        self.totalMessages = totalMessages
        self.userMessages = userMessages
        self.firstMessageId = firstMessageId
        self.lastMessageId = lastMessageId
        self.compactedToolSteps = compactedToolSteps
        self.excludedThinking = excludedThinking
        self.chunkCount = chunkCount
        self.splitMessages = splitMessages
        self.estimatedTokens = estimatedTokens
        self.validReferences = validReferences
        self.droppedReferences = droppedReferences
    }
}

/// One persisted summary run (a row of `summary_runs`).
public struct SummaryRunRecord: Equatable, Sendable, Identifiable {
    public var id: String
    public var source: AgentSource
    public var sessionId: String
    public var status: SummaryStage
    public var executor: SummaryExecutorKind
    public var executorVersion: String?
    public var model: String?
    public var templateVersion: Int
    public var language: String
    /// Fingerprint of the normalized snapshot the run covered (empty until reading finished)
    public var fingerprint: String
    public var coverage: SummaryCoverage
    public var startedAt: Date
    public var updatedAt: Date
    public var finishedAt: Date?
    /// Final summary when completed; otherwise the partial draft, if any
    public var markdown: String?
    public var errorKind: SummaryFailureKind?
    /// Bounded, redacted diagnostic text
    public var errorMessage: String?
    public var inputTokens: Int?
    public var outputTokens: Int?

    public init(
        id: String, source: AgentSource, sessionId: String, status: SummaryStage,
        executor: SummaryExecutorKind, executorVersion: String? = nil, model: String? = nil,
        templateVersion: Int = SummaryTemplate.version, language: String,
        fingerprint: String = "", coverage: SummaryCoverage = SummaryCoverage(),
        startedAt: Date, updatedAt: Date, finishedAt: Date? = nil, markdown: String? = nil,
        errorKind: SummaryFailureKind? = nil, errorMessage: String? = nil,
        inputTokens: Int? = nil, outputTokens: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.sessionId = sessionId
        self.status = status
        self.executor = executor
        self.executorVersion = executorVersion
        self.model = model
        self.templateVersion = templateVersion
        self.language = language
        self.fingerprint = fingerprint
        self.coverage = coverage
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.finishedAt = finishedAt
        self.markdown = markdown
        self.errorKind = errorKind
        self.errorMessage = errorMessage
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var sessionKey: String { AgentTask.key(source: source, sessionId: sessionId) }

    /// Partial output of a run that did not complete
    public var draft: String? {
        guard status != .completed, let markdown, !markdown.isEmpty else { return nil }
        return markdown
    }
}

/// Live progress of the run currently attached to a session (not persisted beyond its stage).
public struct SummaryLiveState: Equatable, Sendable {
    public var runId: String
    public var sessionKey: String
    public var executor: SummaryExecutorKind
    public var stage: SummaryStage
    public var startedAt: Date
    /// Last time the executor produced any event (nil before the first one)
    public var lastEventAt: Date?
    /// Chunks finished / total (total 0 until preparing finished; 1 = single pass)
    public var chunksDone: Int
    public var chunkTotal: Int
    /// Text streamed by the current invocation (empty for executors without deltas)
    public var streamedText: String
    /// Whether the executor streams incremental text at all
    public var streams: Bool
    public var coverage: SummaryCoverage?

    public init(
        runId: String, sessionKey: String, executor: SummaryExecutorKind, stage: SummaryStage,
        startedAt: Date, lastEventAt: Date? = nil, chunksDone: Int = 0, chunkTotal: Int = 0,
        streamedText: String = "", streams: Bool = false, coverage: SummaryCoverage? = nil
    ) {
        self.runId = runId
        self.sessionKey = sessionKey
        self.executor = executor
        self.stage = stage
        self.startedAt = startedAt
        self.lastEventAt = lastEventAt
        self.chunksDone = chunksDone
        self.chunkTotal = chunkTotal
        self.streamedText = streamedText
        self.streams = streams
        self.coverage = coverage
    }
}

/// Sources whose conversation bodies can't be read, with the reason shown in the UI.
public enum SummarySourceSupport {
    public static func unsupportedReason(_ source: AgentSource) -> String? {
        switch source {
        case .trae:
            return L10n.text(
                "Trae's session database is encrypted, so there is no readable conversation to summarize.",
                zhHans: "Trae 的会话库经过加密，没有可读的对话内容可供总结。")
        case .antigravity:
            return L10n.text(
                "Antigravity stores conversations in a private binary format that can't be read yet.",
                zhHans: "Antigravity 的对话为私有二进制格式，暂时无法读取。")
        default:
            return nil
        }
    }
}
