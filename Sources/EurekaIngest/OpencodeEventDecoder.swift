import EurekaKit
import Foundation

/// Decodes one row of the opencode.db `event` table into domain events (source `.opencode`).
/// Event families (every `data` has a top-level `sessionID`):
///   session.created.1 → {sessionID, info{id,directory,title,parentID?,time{created}}}
///   message.updated.1 → {sessionID, info{role,time{created,completed},finish,...}}
///   message.part.updated.1 → {sessionID, part{type,tool,...}}
public enum OpencodeEventDecoder {
    /// Decodes one event row. A child-session (subagent) session.created returns empty (no separate
    /// task).
    public static func decode(type: String, data: [String: Any]) -> [TaskEvent] {
        guard let sessionID = data["sessionID"] as? String, !sessionID.isEmpty else { return [] }
        switch type {
        case "session.created.1":
            guard let info = data["info"] as? [String: Any] else { return [] }
            if let parent = info["parentID"] as? String, !parent.isEmpty { return [] }  // subagent
            let cwd = info["directory"] as? String
            let started = msDate((info["time"] as? [String: Any])?["created"])
            return [event(sessionID, .sessionStarted, cwd: cwd,
                          at: started ?? Date(), sessionStartedAt: started)]

        case "message.updated.1":
            guard let info = data["info"] as? [String: Any] else { return [] }
            let time = info["time"] as? [String: Any]
            switch info["role"] as? String {
            case "user":
                return [event(sessionID, .taskStarted(title: nil),
                              at: msDate(time?["created"]) ?? Date())]
            case "assistant":
                guard time?["completed"] != nil else { return [] }  // in progress, wait for completion
                // One opencode turn produces several assistant messages: intermediate tool rounds
                // have finish=="tool-calls", and only the last round is stop/length. Ignoring
                // finish would pop a task-complete card on every tool round.
                let finish = info["finish"] as? String
                if finish == "tool-calls" || finish == "tool_use" { return [] }  // intermediate round, not a completion
                return [event(sessionID, .taskFinished(outcome: .success, title: nil, detail: nil),
                              at: msDate(time?["completed"]) ?? Date())]
            default:
                return []
            }

        case "message.part.updated.1":
            guard let part = data["part"] as? [String: Any],
                  part["type"] as? String == "tool" else { return [] }
            return [event(sessionID, .activity(tool: part["tool"] as? String), at: Date())]

        default:
            return []
        }
    }

    /// If the row creates a child session (subagent), returns its id (so the tailer can record it
    /// and filter its later message events)
    public static func childSession(type: String, data: [String: Any]) -> String? {
        guard type == "session.created.1",
              let info = data["info"] as? [String: Any],
              let parent = info["parentID"] as? String, !parent.isEmpty,
              let id = info["id"] as? String else { return nil }
        return id
    }

    private static func event(
        _ sessionID: String, _ kind: TaskEvent.Kind, cwd: String? = nil,
        at timestamp: Date, sessionStartedAt: Date? = nil
    ) -> TaskEvent {
        TaskEvent(source: .opencode, sessionId: sessionID, kind: kind,
                  timestamp: timestamp, cwd: cwd, sessionStartedAt: sessionStartedAt)
    }

    private static func msDate(_ value: Any?) -> Date? {
        guard let ms = (value as? NSNumber)?.doubleValue, ms > 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
