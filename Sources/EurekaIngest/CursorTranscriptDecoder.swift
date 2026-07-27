import EurekaKit
import Foundation

/// Cursor 转录行（`agent-transcripts/<id>/<id>.jsonl`）→ `TaskEvent`。
///
/// 信封是 Claude 式的，但**工具词表也是 Claude 式的**（实勘 `Read` / `Glob` / `Grep` / `Shell`），
/// 与库里那套 Cursor 私有名（`read_file` / `glob_file_search` / `run_terminal_cmd`）**不是一回事**。
/// 所以这里不套 `CursorToolNames`——那是给库侧用的。
///
/// 实勘到的三种行：
///   `{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>"}]}}`
///   `{"role":"assistant","message":{"content":[{"type":"text",…},{"type":"tool_use","name":"Read","input":{…}}]}}`
///   `{"type":"turn_ended","status":"success"}`
public enum CursorTranscriptDecoder {
    public static func decode(
        line: Data, sessionId: String, cwd: String?
    ) -> TaskEvent? {
        guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return nil
        }
        return decode(root: root, sessionId: sessionId, cwd: cwd)
    }

    public static func decode(
        root: [String: Any], sessionId: String, cwd: String?
    ) -> TaskEvent? {
        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(source: .cursor, sessionId: sessionId, kind: kind, timestamp: Date(),
                cwd: cwd)
        }

        if root["type"] as? String == "turn_ended" {
            return event(.taskFinished(
                outcome: outcome(status: root["status"] as? String), title: nil, detail: nil))
        }

        switch root["role"] as? String {
        case "user":
            guard let text = userQuery(root), !text.isEmpty else { return nil }
            return event(.taskStarted(title: summarizeTitle(text)))
        case "assistant":
            // 一行里可能有多个 tool_use，取最后一个当「当前在做什么」
            if let tool = lastToolName(root) {
                return event(.activity(tool: tool))
            }
            // 纯文本行（最终答复或中间叙述）当心跳，别让长回合被 4h reaper 收走
            return hasText(root) ? event(.activity(tool: nil)) : nil
        default:
            return nil
        }
    }

    /// 用户输入被包在 `<user_query>…</user_query>` 里，外面还裹了一层 `<timestamp>`；
    /// 取不到标签就退回整段文本（Cursor 换了包装也不至于整条丢掉）。
    public static func userQuery(_ root: [String: Any]) -> String? {
        guard let raw = joinedText(root) else { return nil }
        guard let start = raw.range(of: "<user_query>"),
            let end = raw.range(of: "</user_query>", range: start.upperBound..<raw.endIndex)
        else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(raw[start.upperBound..<end.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 该行最后一个 `tool_use` 的名字（Claude 词表：Read / Glob / Grep / Shell …）
    public static func lastToolName(_ root: [String: Any]) -> String? {
        content(root)
            .filter { $0["type"] as? String == "tool_use" }
            .compactMap { $0["name"] as? String }
            .last { !$0.isEmpty }
    }

    public static func hasText(_ root: [String: Any]) -> Bool {
        (joinedText(root)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
    }

    static func joinedText(_ root: [String: Any]) -> String? {
        let pieces = content(root)
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n")
    }

    static func content(_ root: [String: Any]) -> [[String: Any]] {
        (root["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
    }

    /// `turn_ended.status`：实勘只见过 `success`；其余按关键字宽松归类，
    /// 认不出的一律算正常完成（宁可少报错，也不给用户假红点）。
    static func outcome(status: String?) -> TaskOutcome {
        let text = (status ?? "").lowercased()
        func mentions(_ tokens: [String]) -> Bool { tokens.contains { text.contains($0) } }
        if mentions(["error", "fail", "crash"]) { return .error }
        if mentions(["abort", "cancel", "interrupt", "stop"]) { return .interrupted }
        return .success
    }
}
