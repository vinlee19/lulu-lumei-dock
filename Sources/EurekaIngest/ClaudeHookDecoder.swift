import Foundation
import EurekaKit

/// 把 Claude Code hook stdin payload 解码为领域事件。
/// 宽松解码：缺字段/不认识的事件返回 nil，绝不抛错。
public enum ClaudeHookDecoder {
    public static func decode(payload: [String: Any], receivedAt: Date) -> TaskEvent? {
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
            ) else { return nil }  // auth_success / elicitation 等不构成等待
            kind = .waiting(reason: reason, message: message)
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
            source: .claude,
            sessionId: sessionId,
            kind: kind,
            timestamp: receivedAt,
            cwd: payload["cwd"] as? String,
            transcriptPath: payload["transcript_path"] as? String
        )
    }

    /// notification_type 优先；老版本没有该字段时按 message 文案启发式判断
    static func waitReason(type: String?, message: String?) -> WaitReason? {
        switch type {
        case "permission_prompt": return .permission
        case "idle_prompt": return .idle
        case .some: return nil  // 已知但与等待无关的类型
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
