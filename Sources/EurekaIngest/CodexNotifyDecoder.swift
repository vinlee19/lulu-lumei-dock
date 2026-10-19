import Foundation
import EurekaKit

/// Decodes the JSON received by the Codex notify program (external notify currently only sends
/// agent-turn-complete). Field names accept both kebab-case and snake_case (they differ across
/// versions).
public enum CodexNotifyDecoder {
    public static func decode(payload: [String: Any], receivedAt: Date) -> TaskEvent? {
        guard field(payload, "type") as? String == "agent-turn-complete" else { return nil }

        let sessionId = (field(payload, "thread-id") as? String) ?? "codex-unknown"
        let turnId = field(payload, "turn-id") as? String
        let inputMessages = field(payload, "input-messages") as? [Any]
        let title = (inputMessages?.first as? String).flatMap { summarizeTitle($0) }
        let lastMessage = (field(payload, "last-assistant-message") as? String)
            .flatMap { summarizeTitle($0, maxLength: 120) }

        return TaskEvent(
            source: .codex,
            sessionId: sessionId,
            kind: .taskFinished(outcome: .success, title: title, detail: lastMessage),
            timestamp: receivedAt,
            cwd: field(payload, "cwd") as? String,
            turnId: turnId
        )
    }

    /// Try both kebab-case and snake_case key names
    private static func field(_ payload: [String: Any], _ kebabKey: String) -> Any? {
        payload[kebabKey] ?? payload[kebabKey.replacingOccurrences(of: "-", with: "_")]
    }
}
