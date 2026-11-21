import Foundation

/// The CodeBuddy Code engine writes one transcript family (`projects/<slug>/<sessionId>.jsonl`,
/// OpenAI-Responses-style `message` / `function_call` / `function_call_result` lines) for two
/// products, and they read it differently. The rules that differ live here so the ingest side
/// (decoder, tailer, indexer, transcript reader) and the usage side (EurekaUsage cannot import
/// EurekaIngest) apply the same ones.
///
/// - `codebuddyCode`: the CodeBuddy Code CLI under `~/.codebuddy`, as verified in 2026-07. Its
///   rules are kept exactly as they were.
/// - `workbuddy`: WorkBuddy 5.x, which embeds CodeBuddy Code 2.176 (`@genie/agent-cli`) under
///   `~/.workbuddy`. Verified on 154 local sessions / 300 turns (2026-11). A newer CodeBuddy CLI
///   very likely writes the WorkBuddy shape too, but no CodeBuddy data of that age was available
///   to check; switch `codebuddyCode` to these rules only after verifying them on such data.
public enum CodeBuddyDialect: String, Sendable, CaseIterable {
    case codebuddyCode
    case workbuddy

    public var source: AgentSource {
        switch self {
        case .codebuddyCode: return .codebuddy
        case .workbuddy: return .workbuddy
        }
    }

    /// Model name stored when a usage line carries none
    public var unknownModel: String { "\(source.rawValue)/unknown" }

    // MARK: - Turns

    /// Whether a line is a user prompt that starts a new turn (also what the prompt count counts).
    /// - codebuddyCode: any user message with text that is not a `skipRun` meta line.
    /// - workbuddy: only `providerData.startsNewUserRequest == true`. Compaction summaries (no
    ///   flag, and they quote two dozen earlier `<user_query>` blocks) and mid-turn "steer"
    ///   messages (flag false) are user lines too, but they don't start a turn.
    public func startsTurn(_ root: [String: Any]) -> Bool {
        guard root["type"] as? String == "message", root["role"] as? String == "user"
        else { return false }
        let providerData = root["providerData"] as? [String: Any]
        switch self {
        case .codebuddyCode:
            return providerData?["skipRun"] as? Bool != true && Self.inputText(root) != nil
        case .workbuddy:
            return providerData?["startsNewUserRequest"] as? Bool == true
        }
    }

    /// Text the person typed, for titles, the transcript view and the prompt library; nil for
    /// lines that are not human input.
    /// - codebuddyCode: the joined `input_text` of a non-`skipRun` user message.
    /// - workbuddy: turn starts and steer messages only. Their raw text is a stack of
    ///   `<system-reminder>` context blocks around one `<user_query>…</user_query>`; only the query
    ///   is returned.
    public func userText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "message", root["role"] as? String == "user"
        else { return nil }
        let providerData = root["providerData"] as? [String: Any]
        switch self {
        case .codebuddyCode:
            guard providerData?["skipRun"] as? Bool != true else { return nil }
            return Self.inputText(root)
        case .workbuddy:
            let clientMeta = (providerData?["clientMeta"] as? [String: Any])?["codebuddy.ai"]
                as? [String: Any]
            let isSteer = clientMeta?["queueOrigin"] as? String == "steer"
            guard startsTurn(root) || isSteer, let raw = Self.inputText(root) else { return nil }
            return Self.userQuery(in: raw)
        }
    }

    /// How a turn ends when this line ends it; nil when the line doesn't end a turn.
    /// - codebuddyCode: every completed assistant message (the 2026-07 behaviour).
    /// - workbuddy: a turn has many completed assistant messages between tool calls, so that rule
    ///   fired in 244 of 300 turns before the turn was over. The real end is the assistant message
    ///   that carries the step's `providerData.usage` (the final step has no tool call to hold it),
    ///   or an `incomplete` assistant message with `providerData.error` (quota 429s, server errors,
    ///   and "Interrupted by user" with a null code). Together these explain all 300 turns.
    public func turnEnd(_ root: [String: Any]) -> (outcome: TaskOutcome, detail: String?)? {
        guard root["type"] as? String == "message", root["role"] as? String == "assistant"
        else { return nil }
        let status = root["status"] as? String
        switch self {
        case .codebuddyCode:
            return status == "completed" ? (.success, nil) : nil
        case .workbuddy:
            let providerData = root["providerData"] as? [String: Any]
            if status == "incomplete", let error = providerData?["error"] as? [String: Any] {
                let message = (error["message"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if message == "Interrupted by user" { return (.interrupted, nil) }
                let code = (error["code"] as? NSNumber).map { "\($0)" }
                let detail = [code, message].compactMap { $0 }.filter { !$0.isEmpty }
                    .joined(separator: " ")
                return (.error, detail.isEmpty ? nil : String(detail.prefix(200)))
            }
            if status == "completed", providerData?["usage"] is [String: Any] {
                return (.success, nil)
            }
            return nil
        }
    }

    // MARK: - Tools

    /// `function_call` names that spawn a subagent. In WorkBuddy `TaskCreate` / `TaskUpdate` are
    /// the todo list (`{subject, description, activeForm}` → `~/.workbuddy/tasks/<sid>/<N>.json`),
    /// not subagents.
    public var subagentTools: Set<String> {
        switch self {
        case .codebuddyCode: return ["TaskCreate", "Agent", "AgentSwarm"]
        case .workbuddy: return ["Agent", "AgentSwarm"]
        }
    }

    /// The tool a call really runs: WorkBuddy wraps media generation, some MCP tools and TaskStop
    /// in `DeferExecuteTool{toolName, params}`
    public func effectiveToolName(name: String, args: [String: Any]) -> String {
        if self == .workbuddy, name == "DeferExecuteTool",
           let inner = args["toolName"] as? String, !inner.isEmpty {
            return inner
        }
        return name
    }

    // MARK: - Usage

    /// Per-step token usage of a line, normalized (input excludes cache reads; there is no
    /// cache-write concept). nil when the line carries none or it is all zero.
    /// - codebuddyCode: `function_call` lines only, as before.
    /// - workbuddy: any line with usage. The engine writes each step's usage exactly once (2,390 of
    ///   2,390 `providerData.messageId`s): on the step's first `function_call`, or on the final
    ///   assistant message when the step calls no tool (about 12% of steps, which the
    ///   function_call-only rule dropped).
    /// `providerData.usage` (camelCase) is the main shape: `inputTokens` includes cache reads.
    /// `message.usage` (snake_case) is the fallback: Claude-style (excluding cache) for
    /// codebuddyCode, but WorkBuddy's mirror includes cache reads like the camelCase one.
    public func usage(_ root: [String: Any]) -> CodeBuddyStepUsage? {
        let type = root["type"] as? String
        switch self {
        case .codebuddyCode: guard type == "function_call" else { return nil }
        case .workbuddy: guard type == "function_call" || type == "message" else { return nil }
        }
        let providerData = root["providerData"] as? [String: Any]
        let message = root["message"] as? [String: Any]
        guard let dict = (providerData?["usage"] ?? message?["usage"]) as? [String: Any]
        else { return nil }
        let model = (providerData?["model"] ?? message?["model"]) as? String

        func int(_ dict: [String: Any], _ keys: [String]) -> Int {
            for key in keys {
                if let number = dict[key] as? NSNumber { return number.intValue }
            }
            return 0
        }

        let rawInput = int(dict, ["inputTokens", "input_tokens"])
        let output = int(dict, ["outputTokens", "output_tokens"])
        var cached = int(dict, ["cache_read_input_tokens", "cached_tokens"])
        if cached == 0, let details = dict["inputTokensDetails"] as? [[String: Any]] {
            cached = details.reduce(0) { $0 + int($1, ["cached_tokens"]) }
        }
        let includesCache = dict["inputTokens"] != nil || self == .workbuddy
        let input = includesCache ? max(0, rawInput - cached) : rawInput
        guard input + output + cached > 0 else { return nil }
        return CodeBuddyStepUsage(
            model: model, messageId: providerData?["messageId"] as? String,
            input: input, output: output, cacheRead: cached)
    }

    // MARK: - WorkBuddy session kinds

    /// Prompt marker of a WorkBuddy scheduled automation run. The database flag
    /// (`sessions.is_background_automation`) is the primary signal; this is the fallback when the
    /// database can't be read.
    public static let automationPromptMarker = "<automation_system_reminder>"

    /// Session ids WorkBuddy's own runtime uses for its host and warm-up processes; never a
    /// conversation
    public static func isWorkBuddyInternalSession(_ sessionId: String) -> Bool {
        sessionId.hasPrefix("__workbuddy_cli_host__") || sessionId.hasPrefix("wb-warm-")
    }

    // MARK: - Helpers

    /// Joined `input_text` of a user message, trimmed; nil when empty
    public static func inputText(_ root: [String: Any]) -> String? {
        guard let blocks = root["content"] as? [[String: Any]] else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// The `<user_query>` body of a WorkBuddy prompt. Without one, the `<system-reminder …>`
    /// blocks are dropped and the rest is returned; nil when nothing is left.
    public static func userQuery(in raw: String) -> String? {
        if let start = raw.range(of: "<user_query>"),
           let end = raw.range(of: "</user_query>", range: start.upperBound..<raw.endIndex) {
            let query = raw[start.upperBound..<end.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return query.isEmpty ? nil : query
        }
        var rest = raw
        while let open = rest.range(of: "<system-reminder"),
              let close = rest.range(of: "</system-reminder>", range: open.upperBound..<rest.endIndex) {
            rest.removeSubrange(open.lowerBound..<close.upperBound)
        }
        let trimmed = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One model step's token usage from a CodeBuddy-family transcript line
public struct CodeBuddyStepUsage: Equatable, Sendable {
    public var model: String?
    /// `providerData.messageId`: one per model step, so it identifies the step's usage
    public var messageId: String?
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var total: Int { input + output + cacheRead }

    public init(model: String?, messageId: String?, input: Int, output: Int, cacheRead: Int) {
        self.model = model
        self.messageId = messageId
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
    }
}
