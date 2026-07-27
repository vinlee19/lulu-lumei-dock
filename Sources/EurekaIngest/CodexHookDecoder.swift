import EurekaKit
import Foundation

/// 把 Codex hook stdin payload 解码为领域事件（Codex 0.145.0 实勘）。
///
/// Codex 的 hooks 配置在 `~/.codex/hooks.json`，支持 4 个事件：
/// `UserPromptSubmit` / `Stop` / `SessionStart` / **`PermissionRequest`**。
/// 载荷与 Claude 一样走 stdin JSON，但**不带事件名** —— 事件名由 relay 按安装时写进
/// 命令行的参数补进 `hook_event_name`（见 eureka-relay 的 `codex-hook` 分支）。
///
/// 会话 id 有两种落法（实勘旁证：同机 Otty 的 codex 钩子脚本同时兼容两者）：
/// 顶层 `session_id`，或嵌在 `payload.id` 下。`cwd` 在顶层。
///
/// **`PermissionRequest` 是这条通道存在的主要理由**：Codex 的 rollout 不落授权事件，
/// 所以在装 hooks 之前，「等待授权」对 Codex 完全不可见（README 的已知限制里写着这条）。
/// 顺带收益：relay 的信封带 `terminal`，Codex 因此也能拿到**精确**终端归属，
/// 不再只靠 notify + 进程 cwd 近似匹配。
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
            // 工具名字段名未实勘穷尽（Codex 未公开 schema）→ 多键探测，取不到也照样出等待卡：
            // 「在等你点确认」本身就是要传达的信息，工具名只是锦上添花。
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

    /// 顶层 `session_id`，或 `payload.id`（两种都实勘存在）
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
