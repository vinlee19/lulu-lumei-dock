import Foundation
import EurekaKit

/// 按信封 channel 路由到对应解码器
public enum EventRouter {
    public static func route(_ raw: RawEvent) -> [TaskEvent] {
        let events: [TaskEvent]
        switch raw.channel {
        case "claude-hook":
            events = ClaudeHookDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        case "codex-hook":
            events = CodexHookDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        case "codex-notify":
            events = CodexNotifyDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        default:
            return []
        }
        // 终端归属来自信封而非 payload，故在此统一贴上：各解码器保持"纯 payload 解析"，
        // 两个 channel 也不必各写一遍。
        guard let terminal = raw.terminal else { return events }
        return events.map { event in
            var copy = event
            copy.terminal = terminal
            return copy
        }
    }
}
