import EurekaKit
import Foundation

/// 把 opencode 2.x `session_message` 表一行解码为领域事件（source `.opencode`）。
///
/// opencode 2.x（含 OpenChamber 自带的 `opencode serve`）不再写 `event` / `message` 表，
/// 会话改存 `session_v2`，消息改存 `session_message`（`type` 列 + `data` JSON，时间均为 epoch 毫秒）：
///   user      → {time{created}, text, files?}            一个 turn 的开始（追加引导也是 user）
///   assistant → {time{created,completed?}, model{id,providerID}, content[{type:text|reasoning|tool}],
///                finish, tokens{input,output,reasoning,cache{read,write}}}
///   idle      → {time{created}, outcome: succeeded|failed|interrupted, error?}   turn 结束标记
///   synthetic / system / compaction / agent-switched / model-switched → 注入或切换，不是 turn 边界
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
            // 每个推理步插入一行：当心跳用；工具名取该步已写入的最后一个 tool 分片
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
                return [event(.taskFinished(outcome: .interrupted, title: nil, detail: "已中断"))]
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
