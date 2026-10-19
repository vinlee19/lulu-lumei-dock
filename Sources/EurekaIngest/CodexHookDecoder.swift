import EurekaKit
import Foundation

/// Decodes a Codex hook stdin payload into a domain event (surveyed on Codex 0.145.0).
///
/// Codex's hooks config lives in `~/.codex/hooks.json` and supports 4 events:
/// `UserPromptSubmit` / `Stop` / `SessionStart` / **`PermissionRequest`**. The payload arrives as
/// stdin JSON like Claude's, but **without the event name** -- the relay fills `hook_event_name`
/// from the command-line argument written at install time (see eureka-relay's `codex-hook` branch).
///
/// The session id comes in two placements (corroborated locally: Otty's codex hook script on the
/// same machine handles both):
/// top-level `session_id`, or nested under `payload.id`. `cwd` is top-level.
///
/// **`PermissionRequest` is the main reason this channel exists**: Codex's rollout records no
/// permission events, so before hooks are installed, waiting-for-permission is completely invisible
/// for Codex (listed in the README's known limitations). Side benefit: the relay envelope carries
/// `terminal`, so Codex also gets **exact** terminal attribution instead of relying only on notify
/// + an approximate process-cwd match.
public enum CodexHookDecoder {
    public static func decode(payload: [String: Any], receivedAt: Date) -> TaskEvent? {
        guard let name = payload["hook_event_name"] as? String,
            let sessionId = sessionId(payload)
        else { return nil }

        let kind: TaskEvent.Kind
        switch name {
        case "UserPromptSubmit":
            let title = (payload["prompt"] as? String ?? payload["message"] as? String)
                .flatMap { summarizeTitle($0) }
            kind = .taskStarted(title: title)
        case "Stop":
            kind = .taskFinished(outcome: .success, title: nil, detail: nil)
        case "PermissionRequest":
            // The tool-name field hasn't been exhaustively surveyed (Codex publishes no schema) →
            // probe several keys; still show the waiting card if none match:
            // "waiting for you to confirm" is itself the message to convey; the tool name is just a
            // bonus.
            let tool = firstString(payload, keys: ["tool_name", "tool", "name", "command"])
            kind = .waiting(reason: .permission, message: tool)
        case "SessionStart":
            kind = .sessionStarted
        default:
            return nil
        }

        return TaskEvent(
            source: .codex,
            sessionId: sessionId,
            kind: kind,
            timestamp: receivedAt,
            cwd: payload["cwd"] as? String)
    }

    /// Top-level `session_id`, or `payload.id` (both observed in the wild)
    static func sessionId(_ payload: [String: Any]) -> String? {
        if let id = payload["session_id"] as? String, !id.isEmpty { return id }
        if let nested = payload["payload"] as? [String: Any],
            let id = nested["id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    private static func firstString(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }
}
