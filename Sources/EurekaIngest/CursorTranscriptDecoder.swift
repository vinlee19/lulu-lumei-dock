import EurekaKit
import Foundation

/// Cursor transcript line (`agent-transcripts/<id>/<id>.jsonl`) → `TaskEvent`.
///
/// The envelope is Claude-style, and **so is the tool vocabulary** (observed `Read` / `Glob` /
/// `Grep` / `Shell`), which is **not the same thing** as the DB's private Cursor names (`read_file`
/// / `glob_file_search` / `run_terminal_cmd`). So `CursorToolNames` is not applied here -- that one
/// is for the DB side.
///
/// The three line kinds observed:
///   `{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>"}]}}`
///   `{"role":"assistant","message":{"content":[{"type":"text",…},{"type":"tool_use","name":"Read","input":{…}}]}}`
///   `{"type":"turn_ended","status":"success"}`
public enum CursorTranscriptDecoder {
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> TaskEvent? {
        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .cursor, sessionId: sessionId, kind: kind, timestamp: Date(),
                cwd: cwd)
        }

        if root["type"] as? String == "turn_ended" {
            return event(.taskFinished(
                outcome: outcome(status: root["status"] as? String), title: nil, detail: nil))
        }

        switch root["role"] as? String {
        case "user":
            guard let text = userQuery(root), !text.isEmpty else { return nil }
            return event(.taskStarted(title: summarizeTitle(text)))
        case "assistant":
            // A line may hold several tool_use entries; take the last as "what it's doing now"
            if let tool = lastToolName(root) {
                return event(.activity(tool: tool))
            }
            // Plain text lines (final answer or intermediate narration) count as heartbeats so long
            // turns aren't taken by the 4h reaper
            return hasText(root) ? event(.activity(tool: nil)) : nil
        default:
            return nil
        }
    }

    /// User input is wrapped in `<user_query>…</user_query>`, with another `<timestamp>` layer
    /// around it; if the tag can't be found, fall back to the whole text (so a Cursor wrapper
    /// change doesn't drop the entire entry).
    public static func userQuery(_ root: [String: Any]) -> String? {
        guard let raw = joinedText(root) else { return nil }
        guard let start = raw.range(of: "<user_query>"),
            let end = raw.range(of: "</user_query>", range: start.upperBound..<raw.endIndex)
        else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(raw[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Name of the line's last `tool_use` (Claude vocabulary: Read / Glob / Grep / Shell …)
    public static func lastToolName(_ root: [String: Any]) -> String? {
        content(root)
            .filter { $0["type"] as? String == "tool_use" }
            .compactMap { $0["name"] as? String }
            .last { !$0.isEmpty }
    }

    public static func hasText(_ root: [String: Any]) -> Bool {
        (joinedText(root)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    static func joinedText(_ root: [String: Any]) -> String? {
        let pieces = content(root)
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    static func content(_ root: [String: Any]) -> [[String: Any]] {
        (root["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// `turn_ended.status`: only `success` has been observed; anything else is loosely classified
    /// by keyword, and anything unrecognised counts as a normal finish (better to under-report
    /// errors than show the user a false red dot).
    static func outcome(status: String?) -> TaskOutcome {
        let text = (status ?? "").lowercased()
        func mentions(_ tokens: [String]) -> Bool { tokens.contains { text.contains($0) } }
        if mentions(["error", "fail", "crash"]) { return .error }
        if mentions(["abort", "cancel", "interrupt", "stop"]) { return .interrupted }
        return .success
    }
}
