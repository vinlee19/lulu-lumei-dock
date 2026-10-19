import Foundation

/// Raw material of one agent "turn": one question → some thinking/tool steps → one answer.
///
/// This is the **sole input of the lineage-graph engine**. It lives in EurekaKit rather than EurekaIngest because
/// the dependency direction can only be `EurekaIngest → EurekaKit`: the engine (`TurnGraphBuilder`/`TurnGraphLayout`)
/// is pure and must be unit-testable without any IO, so its input type has to live in the leaf module.
/// Filled in by `EurekaIngest.TurnSlicer`, which slices it out of `[TranscriptMessage]`.
///
/// **Thinking text varies by source** (surveyed locally): Codex (`agent_reasoning`) / Kimi
/// (`think`) / Qwen (`thought`) have plaintext; Claude strips it when writing to disk (only an
/// encrypted signature remains) → `thinkingTexts` is always empty, and the engine instead infers
/// forks from "parallel batches"; it **never fabricates thinking nodes**.
public struct TurnInput: Equatable, Sendable {
    /// One step within a turn. Fields deliberately keep only what drawing and diagnostics need;
    /// output bodies are not retained.
    public struct Step: Equatable, Sendable {
        public var kind: ToolKind
        /// Display tool name (Read / exec_command / server.tool / subagent type…)
        public var name: String
        /// Summary of key arguments (already truncated at parse time)
        public var detail: String
        public var isError: Bool
        /// Batch number within one model output. **Same batch = truly parallel** (for Claude, the
        /// content array of one assistant message; for Codex, an adjacent group within one turn);
        /// different batches = sequential.
        public var batch: Int
        /// Tool call id (Claude `tool_use.id` / Codex `call_id`)
        public var callId: String?
        /// Id of the message carrying this step (= `TranscriptMessage.id`, the in-file ordinal);
        /// used to jump to the message from a node
        public var messageId: Int
        /// Index within this turn's step sequence (0-based)
        public var stepIndex: Int
        /// Steps inside a subagent (non-empty only for `.agent` steps). The parent-child edge comes
        /// exactly from `toolUseId` in `agent-<id>.meta.json`, not guessed from a time window.
        public var subSteps: [Step]

        public init(
            kind: ToolKind, name: String, detail: String, isError: Bool = false,
            batch: Int = 0, callId: String? = nil, messageId: Int = 0, stepIndex: Int = 0,
            subSteps: [Step] = []
        ) {
            self.kind = kind
            self.name = name
            self.detail = detail
            self.isError = isError
            self.batch = batch
            self.callId = callId
            self.messageId = messageId
            self.stepIndex = stepIndex
            self.subSteps = subSteps
        }
    }

    /// Turn ordinal (0-based, in order of appearance within the session)
    public var turnIndex: Int
    /// Question message id (jump anchor); nil for a first turn with no question (session resume)
    public var promptMessageId: Int?
    public var promptText: String
    /// Plaintext thinking (present for Codex/Kimi/Qwen, always empty for Claude)
    public var thinkingTexts: [String]
    public var steps: [Step]
    /// Answer message ids (one turn may produce output in several segments)
    public var answerMessageIds: [Int]
    public var answerText: String
    /// This turn's error messages (API errors etc., not the same thing as step.isError)
    public var errorTexts: [String]
    public var startedAt: Date?
    public var endedAt: Date?

    public init(
        turnIndex: Int, promptMessageId: Int? = nil, promptText: String = "",
        thinkingTexts: [String] = [], steps: [Step] = [],
        answerMessageIds: [Int] = [], answerText: String = "", errorTexts: [String] = [],
        startedAt: Date? = nil, endedAt: Date? = nil
    ) {
        self.turnIndex = turnIndex
        self.promptMessageId = promptMessageId
        self.promptText = promptText
        self.thinkingTexts = thinkingTexts
        self.steps = steps
        self.answerMessageIds = answerMessageIds
        self.answerText = answerText
        self.errorTexts = errorTexts
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    /// Turn duration (nil for sources without timestamps; never pass 0 off as a value)
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
