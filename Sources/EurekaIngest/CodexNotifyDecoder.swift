import Foundation
import EurekaKit

/// 解码 Codex notify 程序收到的 JSON（外部 notify 目前仅 agent-turn-complete）。
/// 字段名兼容 kebab-case 与 snake_case（版本间有差异）。
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

    /// 同时尝试 kebab-case 与 snake_case 键名
    private static func field(_ payload: [String: Any], _ kebabKey: String) -> Any? {
        payload[kebabKey] ?? payload[kebabKey.replacingOccurrences(of: "-", with: "_")]
    }
}
