import Foundation

/// 各源的评价能力档位。轮内诊断依赖 turnTrail 的完整步骤（kind/batch/callId），
/// 只有三个源产出；toolNote 源只剩步数与时长；无步的源只剩轮后纠偏层；
/// antigravity/trae 的转录是固定说明行（会切出带假步的 nil-prompt 轮），显式排除。
public enum PromptEvalCapability: Equatable, Sendable {
    /// 完整：轮内诊断 + 轨迹计量 + 纠偏层（claude/codex/qoder）
    case full
    /// 仅轨迹计量（步数/时长/结局）+ 纠偏层（toolNote 源）
    case trajectory
    /// 仅纠偏层与结局（无工具步骤的源）
    case followupOnly
    /// 不评价（转录不可得，固定说明行会污染切轮）
    case excluded

    public static func level(for source: AgentSource) -> PromptEvalCapability {
        switch source {
        case .claude, .codex, .qoder:
            return .full
        case .opencode, .zcode, .kimi, .qwen, .hermes, .cursor, .codebuddy:
            return .trajectory
        case .gemini, .grok:
            return .followupOnly
        case .antigravity, .trae:
            return .excluded
        }
    }
}

/// 一条 prompt 的评价结果（与 prompt_eval 表列一一对应；全部由 transcript 重算可得）。
/// 不打综合分：severity 三档 + rule_ids 证据 + 各计量原值，UI 负责翻译成人话。
public struct PromptEval: Equatable, Sendable {
    public var promptId: String
    public var severity: TurnDiagnostics.Severity
    /// 命中的规则 id（TurnDiagnostics 7 规则 + corrective/reformulated/outcome-error）
    public var ruleIds: [String]
    public var stepCount: Int
    public var errorSteps: Int
    public var duration: TimeInterval?
    public var reformulated: PromptFollowupSignal.Reformulation
    public var corrective: Bool
    /// "clean" / "error"（本轮以 API 错误收尾）
    public var outcome: String
    public var structureFlags: PromptStructure.Flags

    public init(
        promptId: String, severity: TurnDiagnostics.Severity, ruleIds: [String],
        stepCount: Int, errorSteps: Int, duration: TimeInterval?,
        reformulated: PromptFollowupSignal.Reformulation, corrective: Bool,
        outcome: String, structureFlags: PromptStructure.Flags
    ) {
        self.promptId = promptId
        self.severity = severity
        self.ruleIds = ruleIds
        self.stepCount = stepCount
        self.errorSteps = errorSteps
        self.duration = duration
        self.reformulated = reformulated
        self.corrective = corrective
        self.outcome = outcome
        self.structureFlags = structureFlags
    }
}

/// 评价聚合器：四层信号 → 一条 PromptEval。纯函数，`f(prompt, 执行后果) -> 证据`。
public enum PromptEvaluator {
    /// 升级规则（定死，见 docs/superpowers/plans/2026-08-24-prompt-evaluation.md Step 3）：
    /// - 基线 = 轮内诊断 severity（无诊断则 clean）
    /// - 纠偏命中 → 至少 notice；挣扎型重述 → 至少 notice
    /// - 纠偏+挣扎同现，或 纠偏+error 结局 → bad
    /// - 探索型重述不升级；静态结构 flags 不参与升级（弱先验只作提示）
    public static func evaluate(
        promptId: String,
        turn: TurnInput,
        diagnostics: TurnDiagnostics?,
        nextPromptText: String?,
        capability: PromptEvalCapability
    ) -> PromptEval? {
        guard capability != .excluded else { return nil }

        let corrective = nextPromptText.map(PromptFollowupSignal.isCorrective) ?? false
        let reformulated = nextPromptText.map {
            PromptFollowupSignal.reformulation(prev: turn.promptText, next: $0)
        } ?? PromptFollowupSignal.Reformulation.none
        let outcomeError = !turn.errorTexts.isEmpty

        var severity = diagnostics?.severity ?? .clean
        var rules = diagnostics?.signals.map(\.rule) ?? []
        if corrective {
            severity = max(severity, .notice)
            rules.append("corrective")
        }
        if reformulated == .struggle {
            severity = max(severity, .notice)
            rules.append("reformulated")
        }
        if corrective && (reformulated == .struggle || outcomeError) {
            severity = .bad
        }
        if outcomeError {
            rules.append("outcome-error")
        }

        let duration: TimeInterval? = {
            guard let start = turn.startedAt, let end = turn.endedAt, end > start
            else { return nil }
            return end.timeIntervalSince(start)
        }()
        return PromptEval(
            promptId: promptId,
            severity: severity,
            ruleIds: rules,
            stepCount: turn.steps.count,
            errorSteps: turn.steps.filter(\.isError).count,
            duration: duration,
            reformulated: reformulated,
            corrective: corrective,
            outcome: outcomeError ? "error" : "clean",
            structureFlags: PromptStructure.detect(turn.promptText))
    }
}
