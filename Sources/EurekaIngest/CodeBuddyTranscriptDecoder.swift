import Foundation
import EurekaKit

/// 解析 CodeBuddy CLI 会话行（`projects/<cwd-slug>/<sessionId>.jsonl`，JSONL 事件日志）。
/// schema 已对真实会话核验（2026-07，~/.codebuddy）：每行带 id/parentId/timestamp(epoch ms)/
/// sessionId/cwd，`type` 取值：
/// - `message` role=user：`content:[{type:"input_text",text}]`；
///   `providerData.skipRun:true` 是本地命令回显等元行，不算真实提问
/// - `message` role=assistant：`status:"completed"`，`content:[{type:"output_text",text}]`
/// - `function_call`：`{callId, name, arguments:<JSON 字符串>}`，token 在
///   `providerData.usage` / `message.usage`（实勘为 camelCase：inputTokens/outputTokens/
///   inputTokensDetails[0].cached_tokens；snake_case input_tokens 等作兜底），
///   model 在 `providerData.model`
/// - `function_call_result` / `reasoning` / `file-history-snapshot`：不进事件流
/// - `summary`：`{summary:"<首条用户 prompt>"}`（兜底标题）
/// - `ai-title`：`{aiTitle:"..."}`（AI 生成的会话标题）
/// 未知类型一律忽略不抛错。session id / cwd 由调用方从路径与行字段带入。
public enum CodeBuddyTranscriptDecoder {
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
        let lineCwd = (root["cwd"] as? String) ?? cwd

        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .codebuddy, sessionId: sessionId, kind: kind,
                      timestamp: ts, cwd: lineCwd)
        }

        switch type {
        case "message":
            switch root["role"] as? String {
            case "user":
                // skipRun = 本地命令回显/系统注入的元行，不是真实新一轮
                if (root["providerData"] as? [String: Any])?["skipRun"] as? Bool == true {
                    return nil
                }
                guard let text = userText(root) else { return nil }
                return event(.taskStarted(title: summarizeTitle(text)))
            case "assistant":
                guard root["status"] as? String == "completed" else { return nil }
                return event(.taskFinished(outcome: .success, title: nil, detail: nil))
            default:
                return nil
            }

        case "function_call":
            return event(.activity(tool: root["name"] as? String))

        case "ai-title", "summary":
            // titleUpdate 只改已有任务的标题（TaskStore 不为它建任务），
            // 对未知会话安全，不会制造幻影任务
            guard let title = title(root) else { return nil }
            return event(.titleUpdate(title: title))

        default:
            // reasoning / function_call_result / file-history-snapshot / 未知：忽略
            return nil
        }
    }

    // MARK: - 旁路提取（tailer/scanner/indexer 复用；全部容缺）

    /// message+user 的正文（content input_text 拼接）；skipRun/空正文返回 nil
    public static func userText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "message",
              root["role"] as? String == "user",
              (root["providerData"] as? [String: Any])?["skipRun"] as? Bool != true,
              let blocks = root["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "input_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// message+assistant 的正文（content output_text 拼接）；其它返回 nil
    public static func assistantText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "message",
              root["role"] as? String == "assistant",
              let blocks = root["content"] as? [[String: Any]]
        else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "output_text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// ai-title / summary 行的标题文本；其它类型返回 nil
    public static func title(_ root: [String: Any]) -> String? {
        switch root["type"] as? String {
        case "ai-title":
            return (root["aiTitle"] as? String).flatMap { summarizeTitle($0) }
        case "summary":
            return (root["summary"] as? String).flatMap { summarizeTitle($0) }
        default:
            return nil
        }
    }

    /// function_call 行的 (工具名, 解析后的 arguments)；arguments 是 JSON 字符串
    public static func toolCall(_ root: [String: Any]) -> (name: String, args: [String: Any])? {
        guard root["type"] as? String == "function_call",
              let name = root["name"] as? String, !name.isEmpty
        else { return nil }
        var args: [String: Any] = [:]
        if let raw = root["arguments"] as? String,
           let object = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) {
            args = object as? [String: Any] ?? [:]
        }
        return (name, args)
    }

    /// function_call 行携带的归一化用量；无 usage 或全零返回 nil。
    /// 实勘主格式是 camelCase（inputTokens 含缓存部分 → 口径 input = inputTokens − cached、
    /// cacheRead = cached）；snake_case（input_tokens 等，Claude 式不含缓存 → 不减）兜底。
    public static func usage(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "function_call" else { return nil }
        let providerData = root["providerData"] as? [String: Any]
        let message = root["message"] as? [String: Any]
        guard let dict = (providerData?["usage"] ?? message?["usage"]) as? [String: Any]
        else { return nil }
        let model = (providerData?["model"] ?? message?["model"]) as? String

        func int(_ dict: [String: Any], _ keys: [String]) -> Int {
            for key in keys {
                if let number = dict[key] as? NSNumber { return number.intValue }
            }
            return 0
        }

        let rawInput = int(dict, ["inputTokens", "input_tokens"])
        let output = int(dict, ["outputTokens", "output_tokens"])
        // camelCase：缓存读在 inputTokensDetails[0].cached_tokens；
        // snake_case：cache_read_input_tokens / cached_tokens 平铺
        var cached = int(dict, ["cache_read_input_tokens", "cached_tokens"])
        if cached == 0,
           let details = dict["inputTokensDetails"] as? [[String: Any]] {
            cached = details.reduce(0) { $0 + int($1, ["cached_tokens"]) }
        }
        // camelCase 的 inputTokens 含缓存读（OpenAI 口径）；snake_case 不含（Claude 口径）
        let includesCache = dict["inputTokens"] != nil
        let input = includesCache ? max(0, rawInput - cached) : rawInput
        let usage = Usage(input: input, output: output, cacheRead: cached)
        guard usage.total > 0 else { return nil }
        return (model, usage)
    }

    /// 归一化 token 用量（CodeBuddy 无 cache creation 概念）
    public struct Usage: Equatable {
        public var input: Int
        public var output: Int
        public var cacheRead: Int
        public var total: Int { input + output + cacheRead }
    }

    /// 行时间：`timestamp` 的 epoch 毫秒（>1e12 判毫秒，否则按秒）
    public static func timestamp(_ root: [String: Any]) -> Date? {
        if let number = root["timestamp"] as? NSNumber {
            let value = number.doubleValue
            return Date(timeIntervalSince1970: value > 1e12 ? value / 1000 : value)
        }
        return nil
    }
}
