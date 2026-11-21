import Foundation
import EurekaKit

/// Parses CodeBuddy CLI session lines (`projects/<cwd-slug>/<sessionId>.jsonl`, a JSONL event log).
/// Schema verified against real sessions (2026-07, ~/.codebuddy): every line carries
/// id/parentId/timestamp(epoch ms)/sessionId/cwd, and `type` is one of:
/// - `message` role=user: `content:[{type:"input_text",text}]`; `providerData.skipRun:true` marks
///   meta lines such as local command echoes, not real prompts
/// - `message` role=assistant: `status:"completed"`, `content:[{type:"output_text",text}]`
/// - `function_call`: `{callId, name, arguments:<JSON string>}`; tokens live in
///   `providerData.usage` / `message.usage` (observed as camelCase: inputTokens/outputTokens/
///   inputTokensDetails[0].cached_tokens; snake_case input_tokens etc. as fallback), model in
///   `providerData.model`
/// - `function_call_result` / `reasoning` / `file-history-snapshot`: not part of the event stream
/// - `summary`: `{summary:"<first user prompt>"}` (fallback title)
/// - `ai-title`: `{aiTitle:"..."}` (AI-generated session title)
/// Unknown types are ignored, never thrown. The caller supplies session id / cwd from the path and
/// line fields.
///
/// WorkBuddy embeds the same engine and writes the same family under `~/.workbuddy`, plus
/// `session-meta` (title timeline) and `credit-usage` lines. Where the two read differently (turn
/// start/end, prompt text, usage lines, subagent tools) the rule comes from `CodeBuddyDialect`;
/// every entry point defaults to `.codebuddyCode`, which keeps CodeBuddy's 2026-07 behaviour.
public enum CodeBuddyTranscriptDecoder {
    // MARK: - Lifecycle decoding

    /// Decodes one line → domain event (0 or 1)
    public static func decode(
        line: Data, sessionId: String, cwd: String?,
        dialect: CodeBuddyDialect = .codebuddyCode
    ) -> TaskEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return nil }
        return decode(root: root, sessionId: sessionId, cwd: cwd, dialect: dialect)
    }

    /// Decodes an already-parsed line (shared with side-channel extraction after the tailer's
    /// single JSON parse)
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?,
        dialect: CodeBuddyDialect = .codebuddyCode
    ) -> TaskEvent? {
        guard let type = root["type"] as? String else { return nil }
        let ts = timestamp(root) ?? Date()
        let lineCwd = (root["cwd"] as? String) ?? cwd

        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: dialect.source, sessionId: sessionId, kind: kind,
                      timestamp: ts, cwd: lineCwd)
        }

        switch type {
        case "message":
            switch root["role"] as? String {
            case "user":
                // codebuddyCode: skipRun marks a local command echo / system-injected meta line;
                // workbuddy: only startsNewUserRequest starts a turn (see CodeBuddyDialect)
                guard dialect.startsTurn(root) else { return nil }
                return event(.taskStarted(title: userText(root, dialect: dialect)
                    .flatMap { summarizeTitle($0) }))
            case "assistant":
                guard let end = dialect.turnEnd(root) else { return nil }
                return event(.taskFinished(outcome: end.outcome, title: nil, detail: end.detail))
            default:
                return nil
            }

        case "function_call":
            if dialect == .workbuddy, root["name"] as? String == "AskUserQuestion" {
                // The engine blocks until the person answers in WorkBuddy; the matching
                // function_call_result (below) resumes the task
                let question = toolCall(root).flatMap { firstQuestion($0.args) }
                return event(.waiting(reason: .idle, message: question))
            }
            guard let call = toolCall(root) else { return event(.activity(tool: nil)) }
            return event(.activity(
                tool: dialect.effectiveToolName(name: call.name, args: call.args)))

        case "function_call_result":
            // Only the question's answer matters to the lifecycle: it ends the wait
            guard dialect == .workbuddy, root["name"] as? String == "AskUserQuestion"
            else { return nil }
            return event(.activity(tool: nil))

        case "ai-title", "summary", "session-meta":
            // titleUpdate only retitles an existing task (TaskStore never creates one for it),
            // so it is safe for unknown sessions and never creates phantom tasks
            guard let title = title(root, dialect: dialect) else { return nil }
            return event(.titleUpdate(title: title))

        default:
            // reasoning / file-history-snapshot / credit-usage / unknown: ignored
            return nil
        }
    }

    /// First question text of an AskUserQuestion call (`{questions: [{question, …}]}`)
    static func firstQuestion(_ args: [String: Any]) -> String? {
        guard let questions = args["questions"] as? [[String: Any]],
              let text = (questions.first?["question"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return String(text.prefix(200))
    }

    // MARK: - Side-channel extraction (reused by tailer/scanner/indexer; all tolerate missing fields)

    /// Body of a message+user line (concatenated content input_text); nil for skipRun/empty body.
    /// WorkBuddy: only the `<user_query>` of a turn start or steer message (see CodeBuddyDialect).
    public static func userText(
        _ root: [String: Any], dialect: CodeBuddyDialect = .codebuddyCode
    ) -> String? {
        dialect.userText(root)
    }

    /// Body of a message+assistant line (concatenated content output_text); nil otherwise
    public static func assistantText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "message",
              root["role"] as? String == "assistant",
              let blocks = root["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Title text of an ai-title / summary line; nil for other types. WorkBuddy also keeps a title
    /// timeline in `session-meta.meta["codebuddy.ai/sessionTitle"]` (`[{type:"ai-title",
    /// aiTitle}]`, newest last); it writes `ai-title` lines for only a few sessions.
    public static func title(
        _ root: [String: Any], dialect: CodeBuddyDialect = .codebuddyCode
    ) -> String? {
        switch root["type"] as? String {
        case "ai-title":
            return (root["aiTitle"] as? String).flatMap { summarizeTitle($0) }
        case "summary":
            return (root["summary"] as? String).flatMap { summarizeTitle($0) }
        case "session-meta" where dialect == .workbuddy:
            let meta = root["meta"] as? [String: Any]
            let timeline = meta?["codebuddy.ai/sessionTitle"] as? [[String: Any]]
            return timeline?.last.flatMap { $0["aiTitle"] as? String }
                .flatMap { summarizeTitle($0) }
        default:
            return nil
        }
    }

    /// Title rank used when several sources compete: ai-title / session-meta (2) > summary (1);
    /// the first user text is 0 and the WorkBuddy database title outranks them all
    static func titleRank(_ root: [String: Any]) -> Int {
        root["type"] as? String == "summary" ? 1 : 2
    }

    /// (tool name, parsed arguments) of a function_call line; arguments is a JSON string
    public static func toolCall(_ root: [String: Any]) -> (name: String, args: [String: Any])? {
        guard root["type"] as? String == "function_call",
              let name = root["name"] as? String, !name.isEmpty
        else { return nil }
        var args: [String: Any] = [:]
        if let raw = root["arguments"] as? String,
           let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
            args = object as? [String: Any] ?? [:]
        }
        return (name, args)
    }

    /// Normalized usage carried by a line (codebuddyCode: function_call lines only); nil when there
    /// is no usage or it is all zero. The rules live in `CodeBuddyDialect.usage`, shared with the
    /// usage scanner.
    public static func usage(
        _ root: [String: Any], dialect: CodeBuddyDialect = .codebuddyCode
    ) -> (model: String?, usage: Usage)? {
        guard let step = dialect.usage(root) else { return nil }
        return (step.model, Usage(input: step.input, output: step.output, cacheRead: step.cacheRead))
    }

    /// Normalized token usage (CodeBuddy has no cache-creation concept)
    public struct Usage: Equatable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var total: Int { input + output + cacheRead }
    }

    /// Line time: `timestamp` in epoch milliseconds (>1e12 means milliseconds, otherwise seconds)
    public static func timestamp(_ root: [String: Any]) -> Date? {
        if let number = root["timestamp"] as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return nil
    }
}
