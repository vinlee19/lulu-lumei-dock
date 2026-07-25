import EurekaKit
import Foundation

/// 解析 Qoder CLI 会话 JSONL 单行（`~/.qoder-cn/projects/<slug>/<sessionId>.jsonl`，
/// Claude 式信封）。schema 已对着本机真实会话核验（v1.1.5，2026-07）：
/// - `workspace-directories`（恒为首行，directories=[cwd]，无时间戳）
/// - `runtime-config`（model 等，timestamp 是 epoch-ms 数字）→ 忽略
/// - `custom-title` / `ai-title` / `last-prompt`（标题/末轮 prompt，无时间戳）
/// - `user`：origin.kind=="human" 且非 isMeta 才是真实输入；命令行（/plan 等）无 origin；
///   content 为字符串，或 [{type:"tool_result"}]（工具回灌，非 prompt）
/// - `assistant`：message.content=[{type:"thinking"|"text"|"tool_use"}]，
///   text 收尾一轮；tool_use 是中间步；thinking 仅心跳
/// - `system` / `file-history-snapshot` / 未知类型 → 忽略
/// 时间戳是 ISO-8601 字符串（带小数秒），与 kimi 的 epoch-ms 不同。
/// 未知字段一律容缺不抛错。session id / cwd 由调用方从路径与行字段带入。
public enum QoderTranscriptDecoder {
    // MARK: - 生命周期解码

    /// 单行解码 → 领域事件（0 或 1 个）
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return nil }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    /// 已解析行的解码（tailer 单次 JSON 解析后与旁路提取共用）
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard let type = root["type"] as? String else { return nil }
        let ts = timestamp(root) ?? Date()

        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .qoder, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)
        }

        switch type {
        case "user":
            // origin.kind=="human" 且非 isMeta 且有正文 = 真实新一轮；
            // 命令注入（无 origin）/ 本地命令 caveat（isMeta）/ tool_result 回灌都不算
            guard let text = userPromptText(root) else { return nil }
            return event(.taskStarted(title: summarizeTitle(text)))

        case "assistant":
            guard let message = root["message"] as? [String: Any] else { return nil }
            let (text, tool) = assistantPayload(message)
            if text != nil {
                // 可见正文 = 一轮收尾
                return event(.taskFinished(outcome: .success, title: nil, detail: nil))
            }
            if let tool {
                return event(.activity(tool: tool))
            }
            // 纯 thinking：轮内心跳（刷新活跃，不改状态语义）
            return event(.activity(tool: nil))

        case "custom-title":
            guard let title = (root["customTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            return event(.titleUpdate(title: title))

        case "ai-title":
            guard let title = (root["aiTitle"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
            else { return nil }
            return event(.titleUpdate(title: title))

        // runtime-config / workspace-directories / last-prompt / system /
        // file-history-snapshot / 未知类型：不产出任务状态事件
        default:
            return nil
        }
    }

    // MARK: - 旁路提取（tailer/indexer 复用；全部容缺）

    /// 真实用户输入正文（origin.kind=="human"、非 isMeta、text 非空）；否则 nil
    public static func userPromptText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "user",
              (root["origin"] as? [String: Any])?["kind"] as? String == "human",
              (root["isMeta"] as? Bool) != true,
              let message = root["message"] as? [String: Any]
        else { return nil }
        let text: String
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks
                .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// assistant message 的 (可见正文, 首个工具名)：text 段拼接；tool_use 取 name
    static func assistantPayload(_ message: [String: Any]) -> (text: String?, tool: String?) {
        if let string = message["content"] as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, nil)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return (nil, nil) }
        var texts: [String] = []
        var tool: String?
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let piece = (block["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !piece.isEmpty {
                    texts.append(piece)
                }
            case "tool_use":
                if tool == nil, let name = block["name"] as? String, !name.isEmpty {
                    tool = name
                }
            default:  // thinking 等：不进正文
                continue
            }
        }
        return (texts.isEmpty ? nil : texts.joined(separator: "\n"), tool)
    }

    /// 标题行（custom-title / ai-title）的 (是否用户自定义, 标题)；其它类型返回 nil
    public static func titleLine(_ root: [String: Any]) -> (isCustom: Bool, title: String)? {
        let type = root["type"] as? String
        let key = type == "custom-title" ? "customTitle" : type == "ai-title" ? "aiTitle" : nil
        guard let key,
              let title = (root[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
        else { return nil }
        return (key == "customTitle", title)
    }

    /// last-prompt 行的正文；其它类型返回 nil
    public static func lastPrompt(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "last-prompt",
              let prompt = (root["lastPrompt"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !prompt.isEmpty
        else { return nil }
        return prompt
    }

    /// 行 cwd：workspace-directories 的 directories[0]，或普通行的 cwd 字段
    public static func cwd(_ root: [String: Any]) -> String? {
        if root["type"] as? String == "workspace-directories",
           let directories = root["directories"] as? [String],
           let first = directories.first, !first.isEmpty {
            return first
        }
        return root["cwd"] as? String
    }

    /// 事件时间：`timestamp` 为 ISO-8601 字符串（带/不带小数秒），epoch 毫秒数字兜底
    public static func timestamp(_ root: [String: Any]) -> Date? {
        if let string = root["timestamp"] as? String {
            return KimiWireDecoder.parseISO(string)
        }
        if let number = root["timestamp"] as? Double {
            return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
        }
        return nil
    }
}
