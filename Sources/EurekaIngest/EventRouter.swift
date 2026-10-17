import Foundation
import EurekaKit

/// Routes to the matching decoder by envelope channel
public enum EventRouter {
    public static func route(_ raw: RawEvent) -> [TaskEvent] {
        let events: [TaskEvent]
        switch raw.channel {
        case "claude-hook":
            events = ClaudeHookDecoder.decode(payload: raw.payload, receivedAt: raw.receivedAt)
                .map { [$0] } ?? []
        case "trae-hook":
            // Trae CN's hooks are a Claude-compatible implementation → same decoder, only the
            // source differs
            events = ClaudeHookDecoder.decode(
                payload: raw.payload, receivedAt: raw.receivedAt, source: .trae)
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
        // Terminal attribution comes from the envelope, not the payload, so it's attached here in
        // one place: decoders stay "pure payload parsing", and the two channels don't each have to
        // repeat it.
        guard let terminal = raw.terminal else { return events }
        return events.map { event in
            var copy = event
            copy.terminal = terminal
            return copy
        }
    }
}
