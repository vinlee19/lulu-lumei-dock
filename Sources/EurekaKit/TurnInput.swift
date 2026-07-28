import Foundation

/// 一个 agent「轮次」的原始素材：一次提问 → 若干思考/工具 → 一次回答。
///
/// 这是**血缘图引擎的唯一输入**。放 EurekaKit 而不是 EurekaIngest，是因为
/// 依赖方向只能是 `EurekaIngest → EurekaKit`：引擎（`TurnGraphBuilder`/`TurnGraphLayout`）
/// 是纯函数、要能脱离任何 IO 单测，所以输入类型必须落在叶子模块里。
/// 由 `EurekaIngest.TurnSlicer` 从 `[TranscriptMessage]` 切出来填充。
///
/// **思考正文按源分级**（本机实勘）：Codex（`agent_reasoning`）/ Kimi（`think`）/
/// Qwen（`thought`）有明文；Claude 落盘时被剥离（只剩加密签名）→ `thinkingTexts` 恒空，
/// 引擎那侧改用「并行批次」推断分叉，**绝不伪造思考节点**。
public struct TurnInput: Equatable, Sendable {
    /// 轮内一步操作。字段刻意只保留「画图与诊断需要的」，不驻留输出正文。
    public struct Step: Equatable, Sendable {
        public var kind: ToolKind
        /// 展示用工具名（Read / exec_command / server.tool / 子代理类型…）
        public var name: String
        /// 关键参数摘要（解析期已截断）
        public var detail: String
        public var isError: Bool
        /// 同一次模型输出里的批次号。**同批 = 真并行**（Claude 是同一 assistant 消息的
        /// content 数组，Codex 是同一 turn 内相邻的一组）；跨批 = 串行。
        public var batch: Int
        /// 工具调用 id（Claude `tool_use.id` / Codex `call_id`）
        public var callId: String?
        /// 承载这一步的消息 id（= `TranscriptMessage.id` 文件内序号），点节点跳消息用
        public var messageId: Int
        /// 在本轮步骤序列里的下标（0 起）
        public var stepIndex: Int
        /// 子代理内部的步骤（仅 `.agent` 步非空）。父子边由
        /// `agent-<id>.meta.json` 的 `toolUseId` 精确给出，不是靠时间窗猜的。
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

    /// 轮序号（0 起，按会话内出现顺序）
    public var turnIndex: Int
    /// 提问消息 id（跳转锚点）；无提问的首轮（会话恢复）为 nil
    public var promptMessageId: Int?
    public var promptText: String
    /// 明文思考（Codex/Kimi/Qwen 有，Claude 恒空）
    public var thinkingTexts: [String]
    public var steps: [Step]
    /// 回答消息 id 列表（一轮可能分多段输出）
    public var answerMessageIds: [Int]
    public var answerText: String
    /// 本轮的错误消息（API 错误等，与 step.isError 不是一回事）
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

    /// 轮耗时（无时间戳的源返回 nil，不要拿 0 冒充）
    public var duration: TimeInterval? {
        guard let startedAt, let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}
