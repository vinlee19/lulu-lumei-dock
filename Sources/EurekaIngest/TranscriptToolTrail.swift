import Foundation
import EurekaKit

/// One tool/retrieval trail step (for the session detail's per-turn aggregate view).
///
/// **Plaintext thinking availability varies by source** (verified locally; don't go back to the
/// old comment's "never available locally"):
///  - Claude: unavailable. The `thinking` block's `thinking` field is an empty string; only the
///    encrypted `signature` remains.
///  - Codex: available. `event_msg/agent_reasoning.text` is plaintext (`response_item/reasoning`
///    is the encrypted one).
///  - Kimi: available via `part.type == "think"`; Qwen: available via
///    `parts:[{text, thought:true}]`.
/// So for Claude the trail is still the only stand-in for "what this turn did"; the other sources
/// have real thinking text (carried by `TranscriptMessage.role == .thinking`).
public struct ToolStep: Equatable, Sendable {
    /// Tool category. Moved up to EurekaKit (`ToolKind`) to share with audit; the typealias
    /// stays for source compatibility.
    public typealias Kind = ToolKind

    public var kind: Kind
    public var name: String    // display tool name (Read / exec_command / server.tool / subagent type…)
    public var detail: String  // key-argument summary (truncated at parse time; commands keep the first line)
    public var isError: Bool
    /// Batch number within one model output (Claude = the content array of one assistant message,
    /// Codex = an adjacent group under one `turn_id`). **The lineage graph uses it to tell
    /// parallel forks from serial chains**; without it, "thinking forked into two branches" is
    /// guesswork.
    public var batch: Int
    /// Tool call id (Claude `tool_use.id` / Codex `call_id`), used to pair with result lines
    public var callId: String?
    /// Steps inside a subagent (non-empty only for `.agent` steps). The parent-child edge comes
    /// exactly from `toolUseId` in `agent-<id>.meta.json`, not from a time-window guess.
    public var subSteps: [ToolStep]

    public init(
        kind: Kind, name: String, detail: String, isError: Bool = false,
        batch: Int = 0, callId: String? = nil, subSteps: [ToolStep] = []
    ) {
        self.kind = kind
        self.name = name
        self.detail = detail
        self.isError = isError
        self.batch = batch
        self.callId = callId
        self.subSteps = subSteps
    }
}

/// Categorizes tool_use / function_call → ToolStep and summarizes arguments (for UI display; it
/// truncates the full-fidelity AuditExtractor result).
public enum ToolStepExtractor {
    /// detail summary limit (truncated at parse time so huge commands/patches don't stay in memory)
    static let detailLimit = 160

    // MARK: - Claude (tool_use blocks in assistant content)

    public static func claude(name: String, input: [String: Any]?) -> ToolStep {
        clip(AuditExtractor.claude(name: name, input: input))
    }

    // MARK: - Codex (response_item function_call; arguments is a JSON string)

    public static func codex(name: String, argumentsJSON: String?) -> ToolStep {
        clip(AuditExtractor.codex(name: name, argumentsJSON: argumentsJSON))
    }

    // MARK: - Codex custom tool channel (custom_tool_call; input is JS source or a patch body)

    public static func codexCustomTool(name: String, input: String?) -> ToolStep {
        clip(AuditExtractor.codexCustomTool(name: name, input: input))
    }

    /// Full-fidelity operation → display ToolStep: commands keep only the first line, everything
    /// else is truncated as a whole
    private static func clip(_ op: AuditExtractor.Operation) -> ToolStep {
        let detail = op.kind == .command ? clipFirstLine(op.detail) : clip(op.detail)
        return ToolStep(kind: op.kind, name: op.name, detail: detail)
    }

    /// First String value (reused by TranscriptReader's mcp arguments summary)
    static func firstString(in input: [String: Any]?) -> String {
        AuditExtractor.firstString(in: input)
    }

    // MARK: - Summary helpers

    /// Truncates to detailLimit (huge arguments don't stay in memory)
    static func clip(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return "" }
        return raw.count <= detailLimit ? raw : String(raw.prefix(detailLimit)) + "…"
    }

    /// Command summary: first line only, then truncated
    static func clipFirstLine(_ raw: String?) -> String {
        guard let raw else { return "" }
        let firstLine = raw.split(separator: "\n", maxSplits: 1,
                                  omittingEmptySubsequences: false).first.map(String.init) ?? raw
        let clipped = clip(firstLine)
        // Mark multi-line commands with an ellipsis (clip won't add one if the first line fits)
        if raw.contains("\n"), !clipped.hasSuffix("…") { return clipped + " …" }
        return clipped
    }

    /// Plain-text rendering of the trail (the text of a turnTrail message, so in-session search
    /// and the export fallback can match it)
    public static func plainText(_ steps: [ToolStep]) -> String {
        var lines = [L10n.format("Turn activity (%@ steps)", zhHans: "本轮轨迹（%@ 步）", String(steps.count))]
        for step in steps {
            let flag = step.isError ? L10n.text(" (failed)", zhHans: "（失败）") : ""
            let detail = step.detail.isEmpty ? "" : " \(step.detail)"
            lines.append("[\(step.kind.label)] \(step.name)\(flag)\(detail)")
        }
        return lines.joined(separator: "\n")
    }
}
