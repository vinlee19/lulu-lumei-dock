import Foundation
import EurekaKit

/// 解析 ZCode CLI `model-io-sess_<id>.jsonl` 单行 -> 领域事件 / 用量。
/// schema 已对着本机真实会话核验（2026-08，~/.zcode/cli/rollout）：
/// - 每行 `type:"model_io"`，一次模型请求一条；`querySource` 有 main_turn / subagent 等
/// - `startedAt`/`completedAt`：ISO8601；`completedAt` 为 null = 请求仍在进行
/// - `model.modelId`：如 "glm-5.3"（response.modelId 是小写版）
/// - `response.finishReason`：tool-calls=中间步、stop=终轮
/// - `response.usage`：{inputTokens,outputTokens,totalTokens,cacheReadTokens,cacheWriteTokens}
///   （error 行可能是空对象 {}）。**OpenAI 口径**（实测全部 55 条 usage 行验证）：
///   `cacheReadTokens ⊆ inputTokens`（inputTokens 是完整输入侧、已含缓存读），
///   `totalTokens = inputTokens + outputTokens`，cacheWriteTokens 恒 0。
/// - `error` 非空 = 该请求出错（如 "v4 session stopped"）
/// 会话 id 从文件名解出（`model-io-sess_<id>.jsonl` -> `sess_<id>`）；
/// cwd 由调用方从 db 的 session 表带入。未知形状一律忽略不抛错。
public enum ZcodeRolloutDecoder {
    /// 归一化用量（response.usage 的真实字段）
    public struct Usage: Equatable {
        public var input: Int          // inputTokens（完整输入侧，已含 cacheRead——OpenAI 口径）
        public var output: Int         // outputTokens
        public var cacheRead: Int      // cacheReadTokens（input 的子集，不能与 input 相加）
        public var cacheWrite: Int     // cacheWriteTokens（实测恒 0）
        /// = 文件自带 totalTokens；ctx% 的分子（官方「上下文容量」同口径）
        public var total: Int { input + output }

        public init(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
            self.input = input
            self.output = output
            self.cacheRead = cacheRead
            self.cacheWrite = cacheWrite
        }
    }

    /// 从 rollout 文件名解会话 id：`model-io-sess_xxx.jsonl` -> `sess_xxx`；
    /// 不匹配（防御）返回 nil
    public static func sessionId(fileName: String) -> String? {
        guard fileName.hasPrefix("model-io-"), fileName.hasSuffix(".jsonl") else { return nil }
        let body = String(fileName.dropFirst("model-io-".count).dropLast(".jsonl".count))
        return body.isEmpty ? nil : body
    }

    /// 顶层 usage 与模型名（response.usage + response.modelId，缺后者回退 model.modelId 小写化）。
    /// 全零/空对象返回 nil（error 行与进行中行没有可计用量）。
    public static func usageRecord(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "model_io",
              let response = root["response"] as? [String: Any],
              let dict = response["usage"] as? [String: Any]
        else { return nil }
        let usage = Usage(
            input: dict["inputTokens"] as? Int ?? 0,
            output: dict["outputTokens"] as? Int ?? 0,
            cacheRead: dict["cacheReadTokens"] as? Int ?? 0,
            cacheWrite: dict["cacheWriteTokens"] as? Int ?? 0)
        guard usage.total > 0 else { return nil }
        let model = (response["modelId"] as? String)
            ?? (root["model"] as? [String: Any])?["modelId"] as? String
        return (model?.lowercased(), usage)
    }

    /// 请求是否已完成（completedAt 非空）。
    public static func isCompleted(_ root: [String: Any]) -> Bool {
        root["completedAt"] != nil
    }

    /// 单行解码 -> 领域事件（0 或多个）。
    /// 已完成的请求：finishReason=stop -> taskFinished；tool-calls -> activity（中间步）；
    /// error 非空 -> 出错收尾。进行中的请求不发事件（等活动/收尾）。
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard root["type"] as? String == "model_io",
              isCompleted(root),
              let ts = parseISO(root["completedAt"] as? String)
        else { return [] }

        let toolNames = toolCalls(root)
        func event(_ kind: TaskEvent.Kind) -> [TaskEvent] {
            [TaskEvent(source: .zcode, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)]
        }

        // error 非空：该请求异常终止（如用户停止 "v4 session stopped"）。
        // 顶层 error 与 response.error 两种形状都探测。
        let errorObject = root["error"] as? [String: Any]
            ?? (root["response"] as? [String: Any])?["error"] as? [String: Any]
        if let errorObject {
            let detail = errorObject["message"] as? String
            return event(.taskFinished(outcome: .interrupted, title: nil, detail: detail))
        }

        let response = root["response"] as? [String: Any] ?? [:]
        switch response["finishReason"] as? String {
        case "stop", "end_turn", "stop_sequence":
            return event(.taskFinished(outcome: .success, title: nil, detail: nil))
        case "tool-calls", "tool_use", "length":
            // 中间步：带上刚调的工具名（岛上显示「Bash」「Edit …」）
            return event(.activity(tool: toolNames.last))
        default:
            // finishReason 缺失（写盘竞争）按中间步，等终轮收尾
            return event(.activity(tool: toolNames.last))
        }
    }

    /// response.toolCalls 的工具名列表（[{name,input}]）
    static func toolCalls(_ root: [String: Any]) -> [String] {
        guard let response = root["response"] as? [String: Any],
              let calls = response["toolCalls"] as? [[String: Any]]
        else { return [] }
        return calls.compactMap { $0["name"] as? String }
    }

    /// 用户新一轮的标题素材：请求 messages 里首条 user 文本（供 tailer 发 taskStarted）
    public static func userPromptText(_ root: [String: Any]) -> String? {
        guard let request = root["request"] as? [String: Any],
              let body = request["body"] as? [String: Any],
              let messages = body["messages"] as? [[String: Any]]
        else { return nil }
        for message in messages {
            guard message["role"] as? String == "user" else { continue }
            if let text = message["content"] as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let blocks = message["content"] as? [[String: Any]] {
                let text = blocks
                    .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    // MARK: - 基础工具

    /// ISO8601（带毫秒小数）-> Date
    public static func parseISO(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        if let date = isoWithFraction.date(from: string) { return date }
        return isoPlain.date(from: string)
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
