import Foundation
import EurekaKit

/// Decodes one line of ZCode CLI `model-io-sess_<id>.jsonl` -> domain events / usage.
/// Schema verified against real local sessions (2026-08, ~/.zcode/cli/rollout):
/// - each line is `type:"model_io"`, one per model request; `querySource` includes
///   main_turn / subagent etc.
/// - `startedAt`/`completedAt`: ISO8601; `completedAt` null = request still in flight
/// - `model.modelId`: e.g. "glm-5.3" (response.modelId is the lowercase form)
/// - `response.finishReason`: tool-calls = intermediate step, stop = final turn
/// - `response.usage`: {inputTokens,outputTokens,totalTokens,cacheReadTokens,cacheWriteTokens}
///   (error lines may carry an empty object {}). **OpenAI semantics** (verified against all
///   55 observed usage lines): `cacheReadTokens ⊆ inputTokens` (inputTokens is the full input
///   side, cache reads included), `totalTokens = inputTokens + outputTokens`,
///   cacheWriteTokens is always 0.
/// - non-empty `error` = the request failed (e.g. "v4 session stopped")
/// The session id comes from the file name (`model-io-sess_<id>.jsonl` -> `sess_<id>`);
/// cwd is passed in by the caller from the db's session table. Unknown shapes are ignored,
/// never thrown.
public enum ZcodeRolloutDecoder {
    /// Normalized usage (the real fields of response.usage)
    public struct Usage: Equatable {
        public var input: Int          // inputTokens (full input side, cacheRead included - OpenAI semantics)
        public var output: Int         // outputTokens
        public var cacheRead: Int      // cacheReadTokens (subset of input; never add it to input)
        public var cacheWrite: Int     // cacheWriteTokens (always 0 in practice)
        /// = the file's own totalTokens; numerator of ctx% (same basis as the official
        /// "context capacity")
        public var total: Int { input + output }

        public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// Session id from a rollout file name: `model-io-sess_xxx.jsonl` -> `sess_xxx`;
    /// returns nil on no match (defensive)
    public static func sessionId(fileName: String) -> String? {
        guard fileName.hasPrefix("model-io-"), fileName.hasSuffix(".jsonl") else { return nil }
        let body = String(fileName.dropFirst("model-io-".count).dropLast(".jsonl".count))
        return body.isEmpty ? nil : body
    }

    /// Top-level usage and model name (response.usage + response.modelId; without the latter,
    /// falls back to model.modelId lowercased).
    /// All-zero / empty objects return nil (error lines and in-flight lines carry no usage).
    public static func usageRecord(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "model_io",
              let response = root["response"] as? [String: Any],
              let dict = response["usage"] as? [String: Any]
        else { return nil }
        let usage = Usage(
            input: dict["inputTokens"] as? Int ?? 0,
            output: dict["outputTokens"] as? Int ?? 0,
            cacheRead: dict["cacheReadTokens"] as? Int ?? 0,
            cacheWrite: dict["cacheWriteTokens"] as? Int ?? 0)
        guard usage.total > 0 else { return nil }
        let model = (response["modelId"] as? String)
            ?? (root["model"] as? [String: Any])?["modelId"] as? String
        return (model?.lowercased(), usage)
    }

    /// Whether the request has completed (completedAt non-null).
    public static func isCompleted(_ root: [String: Any]) -> Bool {
        root["completedAt"] != nil
    }

    /// Decodes one line -> domain events (zero or more).
    /// Completed requests: finishReason=stop -> taskFinished; tool-calls -> activity
    /// (intermediate step); non-empty error -> finish with failure. In-flight requests emit
    /// nothing (wait for activity / finish).
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard root["type"] as? String == "model_io",
              isCompleted(root),
              let ts = parseISO(root["completedAt"] as? String)
        else { return [] }

        let toolNames = toolCalls(root)
        func event(_ kind: TaskEvent.Kind) -> [TaskEvent] {
            [TaskEvent(source: .zcode, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)]
        }

        // Non-empty error: the request ended abnormally (e.g. user stop, "v4 session stopped").
        // Probe both shapes: top-level error and response.error.
        let errorObject = root["error"] as? [String: Any]
            ?? (root["response"] as? [String: Any])?["error"] as? [String: Any]
        if let errorObject {
            let detail = errorObject["message"] as? String
            return event(.taskFinished(outcome: .interrupted, title: nil, detail: detail))
        }

        let response = root["response"] as? [String: Any] ?? [:]
        switch response["finishReason"] as? String {
        case "stop", "end_turn", "stop_sequence":
            return event(.taskFinished(outcome: .success, title: nil, detail: nil))
        case "tool-calls", "tool_use", "length":
            // Intermediate step: carry the tool just called (the island shows "Bash", "Edit …")
            return event(.activity(tool: toolNames.last))
        default:
            // Missing finishReason (write race) counts as an intermediate step; wait for the
            // final turn to finish
            return event(.activity(tool: toolNames.last))
        }
    }

    /// Tool names from response.toolCalls ([{name,input}])
    static func toolCalls(_ root: [String: Any]) -> [String] {
        guard let response = root["response"] as? [String: Any],
              let calls = response["toolCalls"] as? [[String: Any]]
        else { return [] }
        return calls.compactMap { $0["name"] as? String }
    }

    /// Title material for a new user turn: the first user text in the request messages (used
    /// by the tailer to emit taskStarted)
    public static func userPromptText(_ root: [String: Any]) -> String? {
        guard let request = root["request"] as? [String: Any],
              let body = request["body"] as? [String: Any],
              let messages = body["messages"] as? [[String: Any]]
        else { return nil }
        for message in messages {
            guard message["role"] as? String == "user" else { continue }
            if let text = message["content"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    // MARK: - Basic helpers

    /// ISO8601 (with fractional milliseconds) -> Date
    public static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = isoWithFraction.date(from: string) { return date }
        return isoPlain.date(from: string)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
