import Foundation
import EurekaKit

/// 把 Claude Code hook stdin payload 解码为领域事件。
/// 宽松解码：缺字段/不认识的事件返回 nil，绝不抛错。
///
/// **Trae CN 复用同一条解码路径**：它的 hooks 是刻意做的 Claude 兼容实现——stdin 键
/// (`hook_event_name` / `session_id` / `cwd` / `tool_input` / `tool_response`) 与输出契约
/// (`hookSpecificOutput` / `permissionDecision` / `additionalContext` / `stopReason`) 都一致，
/// 二进制里还带着 `import_claude_folders` / `CLAUDE_PROJECT_DIR`。差异只有三处，靠
/// `source` 参数与 `default: return nil` 自然吸收：
/// - Trae 没有 `SessionEnd` / `Notification`（→ 「等待授权」对 Trae 永远不可见）；
/// - Trae 多一个 `PostCompact`（Claude 没有）；
/// - Trae 不给 `transcript_path`（会话库加密，没有明文转录）。
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
            ) else { return nil }  // auth_success / elicitation 等不构成等待
            kind = .waiting(reason: reason, message: message)
        case "PreToolUse":
            guard let tool = payload["tool_name"] as? String, !tool.isEmpty else { return nil }
            // 复用 ToolStepExtractor（= AuditExtractor + 既有 160 字裁剪口径），不另写一套解析。
            // 命令类只取首行；detail 只进 UI、不落历史库（tool_input 可能含凭据）。
            let step = ToolStepExtractor.claude(
                name: tool, input: payload["tool_input"] as? [String: Any])
            kind = .toolPending(
                tool: step.name, detail: step.detail.isEmpty ? nil : step.detail)
        case "PreCompact":
            kind = .compacting
        case "PostCompact":
            // 仅 Trae 有。压缩结束 → 走无工具名的心跳：`TaskStore` 的 `.activity` 分支
            // 本来就会在「有动静」时把 isCompacting 复位，不必新增 case。
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
