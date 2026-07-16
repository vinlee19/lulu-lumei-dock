import Foundation
import EurekaKit

/// 解析 grok `events.jsonl` 单行（`{"ts":ISO8601,"type":...}`）。
/// events.jsonl 是 grok 的主生命周期源：turn_started/turn_ended、phase_changed 心跳、
/// tool_started、permission_requested/resolved（→ 等待权限）齐全。
/// session id / cwd 由调用方（tailer）从同目录 summary.json / 目录名带入。
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

    /// 单行解码 → 领域事件（0 或 1 个）
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

        // 权限：请求 → 等待用户确认；解决 → 复位为运行（心跳）
        // 自动放行（yolo/规则命中）时两者相邻到达，等待态转瞬即逝；
        // 真正阻塞在用户时 permission_resolved 会晚若干轮询才来，等待卡如实停留。
        case "permission_requested":
            return event(.waiting(reason: .permission, message: root["tool_name"] as? String))

        case "permission_resolved":
            return event(.activity(tool: root["tool_name"] as? String))

        case "tool_started":
            return event(.activity(tool: root["tool_name"] as? String))

        // 流式/推理阶段与首 token：纯心跳，刷新活跃时间、把等待复位
        case "phase_changed", "first_token", "loop_started", "tool_completed":
            return event(.activity(tool: nil))

        default:
            return []  // mcp_* / yolo_toggled 等不影响任务状态
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
            return .success  // "completed" 及未知都按成功
        }
    }
}
