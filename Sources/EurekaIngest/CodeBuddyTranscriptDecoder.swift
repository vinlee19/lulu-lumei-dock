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
public enum CodeBuddyTranscriptDecoder {
    // MARK: - Lifecycle decoding

    /// Decodes one line → domain event (0 or 1)
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return nil }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    /// Decodes an already-parsed line (shared with side-channel extraction after the tailer's
    /// single JSON parse)
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard let type = root["type"] as? String else { return nil }
        let ts = timestamp(root) ?? Date()
        let lineCwd = (root["cwd"] as? String) ?? cwd

        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .codebuddy, sessionId: sessionId, kind: kind,
                      timestamp: ts, cwd: lineCwd)
        }

        switch type {
        case "message":
            switch root["role"] as? String {
            case "user":
                // skipRun = a local command echo / system-injected meta line, not a real new turn
                if (root["providerData"] as? [String: Any])?["skipRun"] as? Bool == true {
                    return nil
                }
                guard let text = userText(root) else { return nil }
                return event(.taskStarted(title: summarizeTitle(text)))
            case "assistant":
                guard root["status"] as? String == "completed" else { return nil }
                return event(.taskFinished(outcome: .success, title: nil, detail: nil))
            default:
                return nil
            }

        case "function_call":
            return event(.activity(tool: root["name"] as? String))

        case "ai-title", "summary":
            // titleUpdate only retitles an existing task (TaskStore never creates one for it),
            // so it is safe for unknown sessions and never creates phantom tasks
            guard let title = title(root) else { return nil }
            return event(.titleUpdate(title: title))

        default:
            // reasoning / function_call_result / file-history-snapshot / unknown: ignored
            return nil
        }
    }

    // MARK: - Side-channel extraction (reused by tailer/scanner/indexer; all tolerate missing fields)

    /// Body of a message+user line (concatenated content input_text); nil for skipRun/empty body
    public static func userText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "message",
              root["role"] as? String == "user",
              (root["providerData"] as? [String: Any])?["skipRun"] as? Bool != true,
              let blocks = root["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
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

    /// Title text of an ai-title / summary line; nil for other types
    public static func title(_ root: [String: Any]) -> String? {
        switch root["type"] as? String {
        case "ai-title":
            return (root["aiTitle"] as? String).flatMap { summarizeTitle($0) }
        case "summary":
            return (root["summary"] as? String).flatMap { summarizeTitle($0) }
        default:
            return nil
        }
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

    /// Normalized usage carried by a function_call line; nil when there is no usage or it is all
    /// zero. The observed main format is camelCase (inputTokens includes the cached part → input =
    /// inputTokens − cached, cacheRead = cached); snake_case (input_tokens etc., Claude-style
    /// excluding cache → no subtraction) is the fallback.
    public static func usage(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "function_call" else { return nil }
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
        // camelCase: cache reads in inputTokensDetails[0].cached_tokens;
        // snake_case: flat cache_read_input_tokens / cached_tokens
        var cached = int(dict, ["cache_read_input_tokens", "cached_tokens"])
        if cached == 0,
           let details = dict["inputTokensDetails"] as? [[String: Any]] {
            cached = details.reduce(0) { $0 + int($1, ["cached_tokens"]) }
        }
        // camelCase inputTokens includes cache reads (OpenAI convention); snake_case does not
        // (Claude convention)
        let includesCache = dict["inputTokens"] != nil
        let input = includesCache ? max(0, rawInput - cached) : rawInput
        let usage = Usage(input: input, output: output, cacheRead: cached)
        guard usage.total > 0 else { return nil }
        return (model, usage)
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
