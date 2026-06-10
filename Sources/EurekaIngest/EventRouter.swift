import Foundation
import EurekaKit

/// 按信封 channel 路由到对应解码器
public enum EventRouter {
    public static func route(_ raw: RawEvent) -> [TaskEvent] {
        switch raw.channel {
        case "claude-hook":
            return ClaudeHookDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        case "codex-notify":
            return CodexNotifyDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        default:
            return []
        }
    }
}
