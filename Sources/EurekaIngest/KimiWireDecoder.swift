import Foundation
import EurekaKit

/// 解析 Kimi Code CLI `wire.jsonl` 单行（`{"type":..., "time":<epoch-ms>}`，事件溯源日志）。
/// schema 已对着本机真实会话核验（2026-07）：
/// - `turn.prompt`（origin.kind=user，input=[{type:text,text}]）= 用户新一轮
/// - `context.append_loop_event` 内嵌 `event.type`：
///   step.begin / content.part（part.type=think|text）/ tool.call（name+args）/
///   tool.result / step.end（finishReason: end_turn=终轮、tool_use=中间步）
/// - `usage.record`：{model, usage:{inputOther,output,inputCacheRead,inputCacheCreation}}
/// - `llm.request`：{modelAlias, maxTokens=剩余上下文预算}
/// 未知类型一律忽略不抛错。session id / cwd 由调用方从路径与 state.json 带入。
public enum KimiWireDecoder {
    // MARK: - 生命周期解码

    /// 单行解码 → 领域事件（0 或 1 个）
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any]
        else { return [] }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    /// 已解析行的解码（tailer 单次 JSON 解析后与旁路提取共用）
    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> [TaskEvent] {
        guard let type = root["type"] as? String else { return [] }
        let ts = timestamp(root) ?? Date()

        func event(_ kind: TaskEvent.Kind) -> [TaskEvent] {
            [TaskEvent(source: .kimi, sessionId: sessionId, kind: kind, timestamp: ts, cwd: cwd)]
        }

        switch type {
        case "turn.prompt":
            // origin.kind=user（或缺失）= 真实新一轮；其它来源（合成/续跑）按心跳
            let origin = (root["origin"] as? [String: Any])?["kind"] as? String
            return (origin == nil || origin == "user")
                ? event(.taskStarted(title: nil))
                : event(.activity(tool: nil))

        case "context.append_loop_event":
            guard let inner = root["event"] as? [String: Any],
                  let innerType = inner["type"] as? String
            else { return [] }
            switch innerType {
            case "tool.call":
                return event(.activity(tool: inner["name"] as? String))
            case "step.end":
                switch inner["finishReason"] as? String {
                case "end_turn", "stop", "stop_sequence", "completed":
                    return event(.taskFinished(outcome: .success, title: nil, detail: nil))
                case "error", "failed", "aborted", "cancelled":
                    return event(.taskFinished(outcome: .error, title: nil, detail: nil))
                default:
                    // tool_use / 未知 = 中间步，继续跑
                    return event(.activity(tool: nil))
                }
            default:
                // step.begin / content.part / tool.result / 未知 loop 事件：轮内心跳
                return event(.activity(tool: nil))
            }

        // 轮内其它记录：纯心跳（刷新活跃、等待复位）。
        // 注意 usage.record 不在此列——它跟在每个 step.end 之后（含终轮），
        // 若作心跳会把刚结束的任务"复活"成 running（TaskStore 对未知会话的 activity 会登记为运行中）。
        case "llm.request", "llm.tools_snapshot", "context.append_message":
            return event(.activity(tool: nil))

        // 记账事件：不影响任务状态（用量由扫描器旁路收取）
        case "usage.record":
            return []

        // 授权等待：本机会话未观测到（可能只在 TUI 总线），防御保留
        case "approval.requested":
            return event(.waiting(reason: .permission, message: toolName(root)))
        case "approval.resolved", "approval.expired":
            return event(.activity(tool: nil))

        default:
            // 防御：任何 *.error 类型带文案都按出错结束
            if type.hasSuffix(".error") {
                let detail = text(root)
                return event(.taskFinished(
                    outcome: .error, title: nil, detail: detail.isEmpty ? nil : detail))
            }
            // metadata / config.update / mcp.* / tools.* / plan_mode.* 等一律忽略
            return []
        }
    }

    // MARK: - 旁路提取（tailer/scanner/reader 复用；全部容缺）

    /// usage.record 的归一化用量（真实字段：inputOther/output/inputCacheRead/inputCacheCreation）
    public struct Usage: Equatable {
        public var input: Int          // inputOther（非缓存输入）
        public var output: Int
        public var cacheRead: Int      // inputCacheRead
        public var cacheCreation: Int  // inputCacheCreation
        public var total: Int { input + output + cacheRead + cacheCreation }
    }

    /// type=usage.record 的 (model, usage)；其它类型或全零返回 nil
    public static func usageRecord(_ root: [String: Any]) -> (model: String?, usage: Usage)? {
        guard root["type"] as? String == "usage.record",
              let dict = root["usage"] as? [String: Any]
        else { return nil }
        let usage = Usage(
            input: dict["inputOther"] as? Int ?? 0,
            output: dict["output"] as? Int ?? 0,
            cacheRead: dict["inputCacheRead"] as? Int ?? 0,
            cacheCreation: dict["inputCacheCreation"] as? Int ?? 0)
        guard usage.total > 0 else { return nil }
        return (root["model"] as? String, usage)
    }

    /// type=context.append_loop_event 且 event.type=tool.call 的 (工具名, args)；其它返回 nil
    public static func toolCall(_ root: [String: Any]) -> (name: String, args: [String: Any])? {
        guard root["type"] as? String == "context.append_loop_event",
              let inner = root["event"] as? [String: Any],
              inner["type"] as? String == "tool.call",
              let name = inner["name"] as? String, !name.isEmpty
        else { return nil }
        return (name, inner["args"] as? [String: Any] ?? [:])
    }

    /// type=turn.prompt 的用户正文（input=[{type:text,text}] 拼接）；非用户轮返回 nil
    public static func promptText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "turn.prompt" else { return nil }
        let origin = (root["origin"] as? [String: Any])?["kind"] as? String
        guard origin == nil || origin == "user" else { return nil }
        guard let blocks = root["input"] as? [[String: Any]] else { return nil }
        let text = blocks
            .compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// loop 事件里的 assistant 正文段（event.type=content.part 且 part.type=text）；其它返回 nil
    public static func assistantText(_ root: [String: Any]) -> String? {
        guard root["type"] as? String == "context.append_loop_event",
              let inner = root["event"] as? [String: Any],
              inner["type"] as? String == "content.part",
              let part = inner["part"] as? [String: Any],
              part["type"] as? String == "text",
              let text = (part["text"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
    }

    /// config.update / llm.request 的模型别名（如 "kimi-code/k3"）
    public static func modelAlias(_ root: [String: Any]) -> String? {
        if let alias = root["modelAlias"] as? String, !alias.isEmpty { return alias }
        if let model = root["model"] as? String, !model.isEmpty { return model }
        return nil
    }

    /// 事件时间：`time`/`created_at` 的 epoch 毫秒（>1e12 判毫秒，否则按秒），ISO 字符串兜底
    public static func timestamp(_ root: [String: Any]) -> Date? {
        for key in ["time", "created_at", "createdAt", "ts", "timestamp"] {
            if let number = root[key] as? Double {
                return Date(timeIntervalSince1970: number > 1e12 ? number / 1000 : number)
            }
            if let string = root[key] as? String, let date = parseISO(string) {
                return date
            }
        }
        return nil
    }

    /// 工具名（approval.* 防御路径用；多键名探测）
    static func toolName(_ root: [String: Any]) -> String? {
        for key in ["toolName", "tool_name", "name", "tool"] {
            if let string = root[key] as? String, !string.isEmpty { return string }
        }
        if let payload = root["payload"] as? [String: Any] {
            for key in ["toolName", "tool_name", "name", "tool"] {
                if let string = payload[key] as? String, !string.isEmpty { return string }
            }
        }
        return nil
    }

    /// 错误文案（*.error 防御路径用）
    static func text(_ root: [String: Any]) -> String {
        for key in ["message", "error", "detail", "content", "text"] {
            if let string = root[key] as? String, !string.isEmpty { return string }
        }
        return ""
    }

    // MARK: - 基础工具

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    /// state.json 的 ISO 时间（带/不带小数秒都容）
    static func parseISO(_ string: String) -> Date? {
        isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }
}
