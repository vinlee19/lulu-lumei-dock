import EurekaKit
import Foundation

/// Decodes one line of a Qoder CLI session JSONL (`~/.qoder-cn/projects/<slug>/<sessionId>.jsonl`,
/// Claude-style envelope). Schema verified against real local sessions (v1.1.5, 2026-07):
/// - `workspace-directories` (always the first line, directories=[cwd], no timestamp)
/// - `runtime-config` (model etc., timestamp is an epoch-ms number) → ignored
/// - `custom-title` / `ai-title` / `last-prompt` (title / last-turn prompt, no timestamp)
/// - `user`: real input only when origin.kind=="human" and not isMeta; commands (/plan etc.) have
///   no origin; content is a string, or [{type:"tool_result"}] (tool output fed back, not a prompt)
/// - `assistant`: message.content=[{type:"thinking"|"text"|"tool_use"}],
///   text ends a turn; tool_use is an intermediate step; thinking is only a heartbeat
/// - `system` / `file-history-snapshot` / unknown types → ignored
/// Timestamps are ISO-8601 strings (with fractional seconds), unlike kimi's epoch-ms. Unknown or
/// missing fields are tolerated, never thrown. The caller supplies session id / cwd from the path
/// and line fields.
public enum QoderTranscriptDecoder {
    // MARK: - Lifecycle decoding

    /// Decode one line → domain events (0 or 1)
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return nil }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    /// Decode an already-parsed line (the tailer parses JSON once and shares it with side-channel
    /// extraction)
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard let type = root["type"] as? String else { return nil }
        let ts = timestamp(root) ?? Date()

        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .qoder, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)
        }

        switch type {
        case "user":
            // origin.kind=="human", not isMeta, with a body = a real new turn; command injection
            // (no origin) / local-command caveats (isMeta) / tool_result feedback don't count
            guard let text = userPromptText(root) else { return nil }
            return event(.taskStarted(title: summarizeTitle(text)))

        case "assistant":
            guard let message = root["message"] as? [String: Any] else { return nil }
            let (text, tool) = assistantPayload(message)
            if text != nil {
                // Visible body = end of turn
                return event(.taskFinished(outcome: .success, title: nil, detail: nil))
            }
            if let tool {
                return event(.activity(tool: tool))
            }
            // Thinking only: in-turn heartbeat (refreshes activity, doesn't change state semantics)
            return event(.activity(tool: nil))

        case "custom-title":
            guard let title = (root["customTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            return event(.titleUpdate(title: title))

        case "ai-title":
            guard let title = (root["aiTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            return event(.titleUpdate(title: title))

        // runtime-config / workspace-directories / last-prompt / system /
        // file-history-snapshot / unknown types: emit no task-state events
        default:
            return nil
        }
    }

    // MARK: - Side-channel extraction (shared by tailer/indexer; all tolerate missing fields)

    /// Real user input body (origin.kind=="human", not isMeta, non-empty text); otherwise nil
    public static func userPromptText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "user",
              (root["origin"] as? [String: Any])?["kind"] as? String == "human",
              (root["isMeta"] as? Bool) != true,
              let message = root["message"] as? [String: Any]
        else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// (visible body, first tool name) of an assistant message: text parts joined; tool_use
    /// contributes its name
    static func assistantPayload(_ message: [String: Any]) -> (text: String?, tool: String?) {
        if let string = message["content"] as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, nil)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return (nil, nil) }
        var texts: [String] = []
        var tool: String?
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let piece = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty {
                    texts.append(piece)
                }
            case "tool_use":
                if tool == nil, let name = block["name"] as? String, !name.isEmpty {
                    tool = name
                }
            default:  // thinking etc.: not part of the body
                continue
            }
        }
        return (texts.isEmpty ? nil : texts.joined(separator: "\n"), tool)
    }

    /// (is user-defined, title) of a title line (custom-title / ai-title); nil for other types
    public static func titleLine(_ root: [String: Any]) -> (isCustom: Bool, title: String)? {
        let type = root["type"] as? String
        let key = type == "custom-title" ? "customTitle" : type == "ai-title" ? "aiTitle" : nil
        guard let key,
              let title = (root[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return (key == "customTitle", title)
    }

    /// Body of a last-prompt line; nil for other types
    public static func lastPrompt(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "last-prompt",
              let prompt = (root["lastPrompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
        else { return nil }
        return prompt
    }

    /// Line cwd: directories[0] of workspace-directories, or the cwd field of an ordinary line
    public static func cwd(_ root: [String: Any]) -> String? {
        if root["type"] as? String == "workspace-directories",
           let directories = root["directories"] as? [String],
           let first = directories.first, !first.isEmpty {
            return first
        }
        return root["cwd"] as? String
    }

    /// Event time: `timestamp` is an ISO-8601 string (with/without fractional seconds); an epoch-ms
    /// number is the fallback
    public static func timestamp(_ root: [String: Any]) -> Date? {
        if let string = root["timestamp"] as? String {
            return KimiWireDecoder.parseISO(string)
        }
        if let number = root["timestamp"] as? Double {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return nil
    }
}
