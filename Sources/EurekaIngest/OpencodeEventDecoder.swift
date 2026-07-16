import EurekaKit
import Foundation

/// 把 opencode.db `event` 表一行解码为领域事件（source `.opencode`）。
/// 事件族（`data` 均含顶层 `sessionID`）：
///   session.created.1 → {sessionID, info{id,directory,title,parentID?,time{created}}}
///   message.updated.1 → {sessionID, info{role,time{created,completed},finish,...}}
///   message.part.updated.1 → {sessionID, part{type,tool,...}}
public enum OpencodeEventDecoder {
    /// 解码一行事件。子会话（subagent）的 session.created 返回空（不建独立任务）。
    public static func decode(type: String, data: [String: Any]) -> [TaskEvent] {
        guard let sessionID = data["sessionID"] as? String, !sessionID.isEmpty else { return [] }
        switch type {
        case "session.created.1":
            guard let info = data["info"] as? [String: Any] else { return [] }
            if let parent = info["parentID"] as? String, !parent.isEmpty { return [] }  // 子 agent
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
                guard time?["completed"] != nil else { return [] }  // 进行中，等完成
                // opencode 一个 turn 会产生多条 assistant 消息：中间的工具轮 finish=="tool-calls"，
                // 只有最后一轮才是 stop/length。若不看 finish，就会每个工具轮都弹「任务完成」。
                let finish = info["finish"] as? String
                if finish == "tool-calls" || finish == "tool_use" { return [] }  // 中间轮，非完成
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

    /// 若该行是子会话（subagent）的创建，返回子会话 id（供 tailer 记录后过滤其后续消息事件）
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
