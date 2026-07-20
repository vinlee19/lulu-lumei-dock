import Foundation
import EurekaKit

/// 解析 Codex rollout 单行 JSON（`{timestamp, type, payload}`）。
/// rollout 是 Codex 的主事件源：task_started/task_complete/turn_aborted/error 齐全，
/// 外部 notify 只有 agent-turn-complete（仅作低延迟冗余）。
public enum CodexRolloutDecoder {
    public enum Decoded {
        case sessionMeta(id: String, cwd: String?, startedAt: Date?)
        case event(TaskEvent)
        case rateLimits(RateLimitSnapshot)
        case tokenUsage(CodexTokenTotals)
    }

    /// token_count 的累计值（M5 用相邻差值法记账）
    public struct CodexTokenTotals: Equatable, Sendable {
        public var timestamp: Date
        public var inputTokens: Int
        public var cachedInputTokens: Int
        public var outputTokens: Int
        public var reasoningOutputTokens: Int
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let isoPlain = ISO8601DateFormatter()

    static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        return isoWithFraction.date(from: string) ?? isoPlain.date(from: string)
    }

    /// 单行解码；sessionId/cwd 是该文件 session_meta 的上下文
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> [Decoded] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line),
            let root = object as? [String: Any],
            let type = root["type"] as? String
        else { return [] }
        let timestamp = parseDate(root["timestamp"] as? String) ?? Date()
        let payload = root["payload"] as? [String: Any] ?? [:]

        switch type {
        case "session_meta":
            guard let id = payload["id"] as? String else { return [] }
            return [.sessionMeta(
                id: id,
                cwd: payload["cwd"] as? String,
                startedAt: parseDate(payload["timestamp"] as? String) ?? timestamp)]

        case "event_msg":
            return decodeEventMessage(
                payload, timestamp: timestamp, sessionId: sessionId, cwd: cwd)

        default:
            return []
        }
    }

    private static func decodeEventMessage(
        _ payload: [String: Any], timestamp: Date, sessionId: String, cwd: String?
    ) -> [Decoded] {
        func task(_ kind: TaskEvent.Kind, at date: Date = Date.distantPast, turnId: String? = nil) -> Decoded {
            .event(TaskEvent(
                source: .codex,
                sessionId: sessionId,
                kind: kind,
                timestamp: date == Date.distantPast ? timestamp : date,
                cwd: cwd,
                turnId: turnId
            ))
        }

        switch payload["type"] as? String {
        case "task_started":
            // started_at 是秒级 epoch，比行时间戳更准（落盘可能滞后）
            let startedAt = (payload["started_at"] as? Double).map {
                Date(timeIntervalSince1970: $0)
            }
            return [task(
                .taskStarted(title: nil),
                at: startedAt ?? timestamp,
                turnId: payload["turn_id"] as? String
            )]

        case "user_message":
            // 出现在 task_started 之后，借 taskStarted 的 upsert 语义补标题
            guard
                let message = payload["message"] as? String,
                let title = summarizeTitle(message)
            else { return [] }
            return [task(.taskStarted(title: title))]

        case "thread_name_updated":
            // Codex app-server/桌面端生成或修改的正式会话名，优先级高于 prompt 摘要。
            guard let rawName = payload["thread_name"] as? String else { return [] }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return [] }
            let targetSessionId = payload["thread_id"] as? String ?? sessionId
            return [.event(TaskEvent(
                source: .codex,
                sessionId: targetSessionId,
                kind: .titleUpdate(title: name),
                timestamp: timestamp,
                cwd: cwd
            ))]

        case "task_complete":
            let detail = (payload["last_agent_message"] as? String)
                .flatMap { summarizeTitle($0, maxLength: 120) }
            return [task(
                .taskFinished(outcome: .success, title: nil, detail: detail),
                turnId: payload["turn_id"] as? String
            )]

        case "turn_aborted":
            return [task(
                .taskFinished(outcome: .interrupted, title: nil, detail: "已中断"),
                turnId: payload["turn_id"] as? String
            )]

        case "error":
            let message = (payload["message"] as? String).flatMap {
                summarizeTitle($0, maxLength: 120)
            }
            return [task(.taskFinished(outcome: .error, title: nil, detail: message))]

        case "token_count":
            var results: [Decoded] = []
            if let info = payload["info"] as? [String: Any] {
                if let totals = info["total_token_usage"] as? [String: Any] {
                    results.append(.tokenUsage(CodexTokenTotals(
                        timestamp: timestamp,
                        inputTokens: totals["input_tokens"] as? Int ?? 0,
                        cachedInputTokens: totals["cached_input_tokens"] as? Int ?? 0,
                        outputTokens: totals["output_tokens"] as? Int ?? 0,
                        reasoningOutputTokens: totals["reasoning_output_tokens"] as? Int ?? 0
                    )))
                }
                // 上下文占用：最近一次请求的 token 总量 ≈ 当前会话上下文大小
                if let last = info["last_token_usage"] as? [String: Any],
                   let lastTotal = last["total_tokens"] as? Int,
                   let window = info["model_context_window"] as? Int, window > 0 {
                    results.append(task(.contextUpdate(
                        percent: Double(lastTotal) / Double(window) * 100)))
                }
            }
            if let limits = payload["rate_limits"] as? [String: Any] {
                results.append(.rateLimits(rateLimitSnapshot(limits, asOf: timestamp)))
            }
            return results

        default:
            return []
        }
    }

    static func rateLimitSnapshot(_ limits: [String: Any], asOf: Date) -> RateLimitSnapshot {
        func window(_ key: String) -> RateLimitWindow? {
            guard let dict = limits[key] as? [String: Any],
                  let usedPercent = dict["used_percent"] as? Double
            else { return nil }
            return RateLimitWindow(
                usedPercent: usedPercent,
                windowMinutes: dict["window_minutes"] as? Int ?? 0,
                resetsAt: (dict["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            )
        }
        return RateLimitSnapshot(
            source: .codex,
            asOf: asOf,
            planType: limits["plan_type"] as? String,
            primary: window("primary"),
            secondary: window("secondary")
        )
    }
}
