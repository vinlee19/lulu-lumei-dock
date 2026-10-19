import Foundation
import EurekaKit

/// Decodes a Claude Code hook stdin payload into a domain event. Lenient decoding: missing fields /
/// unknown events return nil, never throw.
///
/// **Trae CN reuses the same decoding path**: its hooks are a deliberate Claude-compatible
/// implementation -- the stdin keys (`hook_event_name` / `session_id` / `cwd` / `tool_input` /
/// `tool_response`) and the output contract (`hookSpecificOutput` / `permissionDecision` /
/// `additionalContext` / `stopReason`) all match, and the binary even carries
/// `import_claude_folders` / `CLAUDE_PROJECT_DIR`. There are only three differences, absorbed
/// naturally by the `source` parameter and `default: return nil`:
/// - Trae has no `SessionEnd` / `Notification` (→ waiting-for-permission is never visible for
///   Trae);
/// - Trae adds a `PostCompact` (Claude has none);
/// - Trae sends no `transcript_path` (the session DB is encrypted; there is no plaintext
///   transcript).
public enum ClaudeHookDecoder {
    public static func decode(
        payload: [String: Any], receivedAt: Date, source: AgentSource = .claude
    ) -> TaskEvent? {
        guard
            let name = payload["hook_event_name"] as? String,
            let sessionId = payload["session_id"] as? String
        else { return nil }

        let kind: TaskEvent.Kind
        switch name {
        case "UserPromptSubmit":
            let title = (payload["prompt"] as? String).flatMap { summarizeTitle($0) }
            kind = .taskStarted(title: title)
        case "Stop":
            kind = .taskFinished(outcome: .success, title: nil, detail: nil)
        case "Notification":
            let message = payload["message"] as? String
            guard let reason = waitReason(
                type: payload["notification_type"] as? String,
                message: message
            ) else { return nil }  // auth_success / elicitation etc. don't count as waiting
            kind = .waiting(reason: reason, message: message)
        case "PreToolUse":
            guard let tool = payload["tool_name"] as? String, !tool.isEmpty else { return nil }
            // Reuse ToolStepExtractor (= AuditExtractor + the existing 160-char truncation rule)
            // instead of a second parser. Command-like tools keep only the first line; detail goes
            // to the UI only, never the history DB (tool_input may hold credentials).
            let step = ToolStepExtractor.claude(
                name: tool, input: payload["tool_input"] as? [String: Any])
            kind = .toolPending(
                tool: step.name, detail: step.detail.isEmpty ? nil : step.detail)
        case "PreCompact":
            kind = .compacting
        case "PostCompact":
            // Trae only. Compaction finished → emit a heartbeat with no tool name: `TaskStore`'s
            // `.activity` branch already resets isCompacting on any activity, so no new case is
            // needed.
            kind = .activity(tool: nil)
        case "PostToolUse":
            kind = .activity(tool: payload["tool_name"] as? String)
        case "SessionStart":
            kind = .sessionStarted
        case "SessionEnd":
            kind = .sessionEnded(reason: payload["reason"] as? String)
        default:
            return nil
        }

        return TaskEvent(
            source: source,
            sessionId: sessionId,
            kind: kind,
            timestamp: receivedAt,
            cwd: payload["cwd"] as? String,
            transcriptPath: payload["transcript_path"] as? String
        )
    }

    /// notification_type wins; older versions without the field fall back to a heuristic on the
    /// message text
    static func waitReason(type: String?, message: String?) -> WaitReason? {
        switch type {
        case "permission_prompt": return .permission
        case "idle_prompt": return .idle
        case .some: return nil  // Known types unrelated to waiting
        case nil:
            guard let message = message?.lowercased() else { return nil }
            if message.contains("permission") || message.contains("approval") {
                return .permission
            }
            if message.contains("waiting for your input") || message.contains("idle") {
                return .idle
            }
            return nil
        }
    }
}
