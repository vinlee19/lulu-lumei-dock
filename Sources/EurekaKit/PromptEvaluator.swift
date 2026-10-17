import Foundation

/// Per-source evaluation capability tier. In-turn diagnostics need complete turnTrail steps
/// (kind/batch/callId), which only three sources produce; toolNote sources only have step count and
/// duration; step-less sources only the post-turn correction layer; antigravity/trae transcripts
/// are fixed placeholder lines (which slice into nil-prompt turns with fake steps), so they are
/// explicitly excluded.
public enum PromptEvalCapability: Equatable, Sendable {
    /// Full: in-turn diagnostics + trail metrics + correction layer (claude/codex/qoder)
    case full
    /// Trail metrics only (steps/duration/outcome) + correction layer (toolNote sources)
    case trajectory
    /// Correction layer and outcome only (sources without tool steps)
    case followupOnly
    /// Not evaluated (no transcript available; fixed placeholder lines would pollute turn slicing)
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

/// Evaluation result for one prompt (maps 1:1 to prompt_eval columns; all recomputable from the
/// transcript). No composite score: three severity tiers + rule_ids as evidence + raw metric
/// values; the UI turns them into plain language.
public struct PromptEval: Equatable, Sendable {
    public var promptId: String
    public var severity: TurnDiagnostics.Severity
    /// Matched rule ids (the 7 TurnDiagnostics rules + corrective/reformulated/outcome-error)
    public var ruleIds: [String]
    public var stepCount: Int
    public var errorSteps: Int
    public var duration: TimeInterval?
    public var reformulated: PromptFollowupSignal.Reformulation
    public var corrective: Bool
    /// "clean" / "error" (this turn ended with an API error)
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

/// Evaluation aggregator: four signal layers → one PromptEval. Pure function,
/// `f(prompt, consequences) -> evidence`.
public enum PromptEvaluator {
    /// Escalation rules (fixed; see docs/superpowers/plans/2026-08-24-prompt-evaluation.md Step 3):
    /// - baseline = in-turn diagnostics severity (clean if no diagnostics)
    /// - correction matched → at least notice; struggling restatement → at least notice
    /// - correction + struggling together, or correction + error outcome → bad
    /// - exploratory restatement doesn't escalate; static structure flags don't take part (weak
    ///   prior, hint only)
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
