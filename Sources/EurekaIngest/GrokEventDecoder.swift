import Foundation
import EurekaKit

/// Parses one line of grok `events.jsonl` (`{"ts":ISO8601,"type":...}`).
/// events.jsonl is grok's primary lifecycle source: turn_started/turn_ended, phase_changed
/// heartbeats, tool_started and permission_requested/resolved (→ waiting for permission) are
/// all present. session id / cwd are supplied by the caller (the tailer) from the sibling
/// summary.json / directory name.
public enum GrokEventDecoder {
    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }

    /// Decodes one line → domain events (0 or 1)
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            let type = root["type"] as? String
        else { return [] }
        let timestamp = parseDate(root["ts"] as? String) ?? Date()

        func event(_ kind: TaskEvent.Kind) -> [TaskEvent] {
            [TaskEvent(
                source: .grok,
                sessionId: sessionId,
                kind: kind,
                timestamp: timestamp,
                cwd: cwd
            )]
        }

        switch type {
        case "turn_started":
            return event(.taskStarted(title: nil))

        case "turn_ended":
            return event(.taskFinished(
                outcome: outcome(root["outcome"] as? String),
                title: nil,
                detail: nil))

        // Permission: requested → waiting for user confirmation; resolved → back to running
        // (heartbeat). On auto-approval (yolo / rule match) the two arrive back to back and the
        // waiting state is momentary; when truly blocked on the user, permission_resolved arrives
        // several polls later and the waiting card stays up accordingly.
        case "permission_requested":
            return event(.waiting(reason: .permission, message: root["tool_name"] as? String))

        case "permission_resolved":
            return event(.activity(tool: root["tool_name"] as? String))

        case "tool_started":
            return event(.activity(tool: root["tool_name"] as? String))

        // Streaming/reasoning phases and first token: pure heartbeat, refreshes activity time and
        // resets waiting
        case "phase_changed", "first_token", "loop_started", "tool_completed":
            return event(.activity(tool: nil))

        default:
            return []  // mcp_* / yolo_toggled etc. do not affect task state
        }
    }

    /// turn_ended.outcome → TaskOutcome
    static func outcome(_ raw: String?) -> TaskOutcome {
        switch raw {
        case "aborted", "cancelled", "canceled", "interrupted":
            return .interrupted
        case "error", "failed":
            return .error
        default:
            return .success  // "completed" and anything unknown count as success
        }
    }
}
