import EurekaKit
import Foundation

/// Decodes one row of the opencode 2.x `session_message` table into domain events
/// (source `.opencode`).
///
/// opencode 2.x (including OpenChamber's bundled `opencode serve`) no longer writes the `event` /
/// `message` tables; sessions moved to `session_v2` and messages to `session_message` (`type`
/// column + `data` JSON, all times in epoch milliseconds):
///   user      → {time{created}, text, files?}            turn start (appended steering is user too)
///   assistant → {time{created,completed?}, model{id,providerID}, content[{type:text|reasoning|tool}],
///                finish, tokens{input,output,reasoning,cache{read,write}}}
///   idle      → {time{created}, outcome: succeeded|failed|interrupted, error?}   turn-end marker
///   synthetic / system / compaction / agent-switched / model-switched →
///     injection or switch, not a turn boundary
public enum OpencodeSessionMessageDecoder {
    public static func decode(
        sessionID: String, type: String, data: [String: Any], cwd: String?
    ) -> [TaskEvent] {
        let created = msDate((data["time"] as? [String: Any])?["created"]) ?? Date()
        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .opencode, sessionId: sessionID, kind: kind,
                      timestamp: created, cwd: cwd)
        }
        switch type {
        case "user":
            let title = (data["text"] as? String).flatMap { summarizeTitle($0) }
            return [event(.taskStarted(title: title))]

        case "assistant":
            // Each reasoning step inserts a row: used as a heartbeat; the tool name comes from the
            // last tool part written so far in that step
            let content = data["content"] as? [[String: Any]] ?? []
            let tool = content.last { $0["type"] as? String == "tool" }?["name"] as? String
            return [event(.activity(tool: tool))]

        case "idle":
            switch data["outcome"] as? String {
            case "failed":
                let error = data["error"] as? [String: Any]
                let detail = (error?["message"] as? String) ?? (error?["type"] as? String)
                return [event(.taskFinished(outcome: .error, title: nil, detail: detail))]
            case "interrupted":
                return [event(.taskFinished(outcome: .interrupted, title: nil, detail: L10n.text("Interrupted", zhHans: "已中断")))]
            default:
                return [event(.taskFinished(outcome: .success, title: nil, detail: nil))]
            }

        default:
            return []
        }
    }

    private static func msDate(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
