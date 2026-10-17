import Foundation
import EurekaKit

/// Parses one line of the Kimi Code CLI `wire.jsonl` (`{"type":..., "time":<epoch-ms>}`, an
/// event-sourced log). Schema verified against real local sessions (2026-07):
/// - `turn.prompt` (origin.kind=user, input=[{type:text,text}]) = a new user turn
/// - `context.append_loop_event` with a nested `event.type`:
///   step.begin / content.part (part.type=think|text) / tool.call (name+args) /
///   tool.result / step.end (finishReason: end_turn = final turn, tool_use = intermediate step)
/// - `usage.record`: {model, usage:{inputOther,output,inputCacheRead,inputCacheCreation}}
/// - `llm.request`: {modelAlias, maxTokens = remaining context budget}
/// Unknown types are ignored, never thrown. session id / cwd are supplied by the caller from the
/// path and state.json.
public enum KimiWireDecoder {
    // MARK: - Lifecycle decoding

    /// Decodes one line → domain events (0 or 1)
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return [] }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    /// Decodes an already-parsed line (the tailer shares one JSON parse with side-channel
    /// extraction)
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard let type = root["type"] as? String else { return [] }
        let ts = timestamp(root) ?? Date()

        func event(_ kind: TaskEvent.Kind) -> [TaskEvent] {
            [TaskEvent(source: .kimi, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)]
        }

        switch type {
        case "turn.prompt":
            // origin.kind=user (or missing) = a real new turn; other origins
            // (synthetic/continuation) count as heartbeats
            let origin = (root["origin"] as? [String: Any])?["kind"] as? String
            return (origin == nil || origin == "user")
                ? event(.taskStarted(title: nil))
                : event(.activity(tool: nil))

        case "context.append_loop_event":
            guard let inner = root["event"] as? [String: Any],
                  let innerType = inner["type"] as? String
            else { return [] }
            switch innerType {
            case "tool.call":
                return event(.activity(tool: inner["name"] as? String))
            case "step.end":
                switch inner["finishReason"] as? String {
                case "end_turn", "stop", "stop_sequence", "completed":
                    return event(.taskFinished(outcome: .success, title: nil, detail: nil))
                case "error", "failed", "aborted", "cancelled":
                    return event(.taskFinished(outcome: .error, title: nil, detail: nil))
                default:
                    // tool_use / unknown = intermediate step, keeps running
                    return event(.activity(tool: nil))
                }
            default:
                // step.begin / content.part / tool.result / unknown loop events: in-turn heartbeat
                return event(.activity(tool: nil))
            }

        // Other in-turn records: pure heartbeat (refresh activity, reset waiting). Note
        // usage.record is not among them — it follows every step.end (including the final turn),
        // and as a heartbeat it would "revive" a just-finished task as running (TaskStore registers
        // activity for an unknown session as running).
        case "llm.request", "llm.tools_snapshot", "context.append_message":
            return event(.activity(tool: nil))

        // Accounting events: do not affect task state (usage is collected by the scanner side
        // channel)
        case "usage.record":
            return []

        // Approval waits: never observed in local sessions (possibly TUI-bus only); kept
        // defensively
        case "approval.requested":
            return event(.waiting(reason: .permission, message: toolName(root)))
        case "approval.resolved", "approval.expired":
            return event(.activity(tool: nil))

        default:
            // Defensive: any *.error type with a message ends as an error
            if type.hasSuffix(".error") {
                let detail = text(root)
                return event(.taskFinished(
                    outcome: .error, title: nil, detail: detail.isEmpty ? nil : detail))
            }
            // metadata / config.update / mcp.* / tools.* / plan_mode.* and the like are ignored
            return []
        }
    }

    // MARK: - Side-channel extraction (shared by tailer/scanner/reader; tolerant of missing fields)

    /// Normalized usage from usage.record (real fields:
    /// inputOther/output/inputCacheRead/inputCacheCreation)
    public struct Usage: Equatable {
        public var input: Int          // inputOther (non-cached input)
        public var output: Int
        public var cacheRead: Int      // inputCacheRead
        public var cacheCreation: Int  // inputCacheCreation
        public var total: Int { input + output + cacheRead + cacheCreation }
    }

    /// (model, usage) for type=usage.record; nil for other types or all zeros
    public static func usageRecord(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "usage.record",
              let dict = root["usage"] as? [String: Any]
        else { return nil }
        let usage = Usage(
            input: dict["inputOther"] as? Int ?? 0,
            output: dict["output"] as? Int ?? 0,
            cacheRead: dict["inputCacheRead"] as? Int ?? 0,
            cacheCreation: dict["inputCacheCreation"] as? Int ?? 0)
        guard usage.total > 0 else { return nil }
        return (root["model"] as? String, usage)
    }

    /// (tool name, args) for type=context.append_loop_event with event.type=tool.call; nil
    /// otherwise
    public static func toolCall(_ root: [String: Any]) -> (name: String, args: [String: Any])? {
        guard root["type"] as? String == "context.append_loop_event",
              let inner = root["event"] as? [String: Any],
              inner["type"] as? String == "tool.call",
              let name = inner["name"] as? String, !name.isEmpty
        else { return nil }
        return (name, inner["args"] as? [String: Any] ?? [:])
    }

    /// User body of type=turn.prompt (input=[{type:text,text}] joined); nil for non-user turns
    public static func promptText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "turn.prompt" else { return nil }
        let origin = (root["origin"] as? [String: Any])?["kind"] as? String
        guard origin == nil || origin == "user" else { return nil }
        guard let blocks = root["input"] as? [[String: Any]] else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Assistant body part in a loop event (event.type=content.part and part.type=text); nil
    /// otherwise
    public static func assistantText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "context.append_loop_event",
              let inner = root["event"] as? [String: Any],
              inner["type"] as? String == "content.part",
              let part = inner["part"] as? [String: Any],
              part["type"] as? String == "text",
              let text = (part["text"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// **Plaintext thinking** part in a loop event (event.type=content.part and part.type=think).
    /// Kimi neither encrypts nor strips it: one surveyed wire.jsonl had 235 parts, the longest
    /// 19.5k chars.
    public static func thinkText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "context.append_loop_event",
              let inner = root["event"] as? [String: Any],
              inner["type"] as? String == "content.part",
              let part = inner["part"] as? [String: Any],
              part["type"] as? String == "think",
              let text = (part["text"] as? String ?? part["think"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// Model alias from config.update / llm.request (e.g. "kimi-code/k3")
    public static func modelAlias(_ root: [String: Any]) -> String? {
        if let alias = root["modelAlias"] as? String, !alias.isEmpty { return alias }
        if let model = root["model"] as? String, !model.isEmpty { return model }
        return nil
    }

    /// Event time: epoch ms in `time`/`created_at` (>1e12 means ms, otherwise seconds), ISO string
    /// as fallback
    public static func timestamp(_ root: [String: Any]) -> Date? {
        for key in ["time", "created_at", "createdAt", "ts", "timestamp"] {
            if let number = root[key] as? Double {
                return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
            }
            if let string = root[key] as? String, let date = parseISO(string) {
                return date
            }
        }
        return nil
    }

    /// Tool name (for the defensive approval.* path; probes several key names)
    static func toolName(_ root: [String: Any]) -> String? {
        for key in ["toolName", "tool_name", "name", "tool"] {
            if let string = root[key] as? String, !string.isEmpty { return string }
        }
        if let payload = root["payload"] as? [String: Any] {
            for key in ["toolName", "tool_name", "name", "tool"] {
                if let string = payload[key] as? String, !string.isEmpty { return string }
            }
        }
        return nil
    }

    /// Error message (for the defensive *.error path)
    static func text(_ root: [String: Any]) -> String {
        for key in ["message", "error", "detail", "content", "text"] {
            if let string = root[key] as? String, !string.isEmpty { return string }
        }
        return ""
    }

    // MARK: - Basic helpers

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// ISO time in state.json (with or without fractional seconds)
    static func parseISO(_ string: String) -> Date? {
        isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}
