import CryptoKit
import Foundation
import EurekaKit

/// 把 Claude Code PostToolUse hook payload 解码为审计事件。
/// 只认 PostToolUse；tool_response/tool_output 正文丢弃，仅嗅探 is_error 布尔。
public enum ClaudeAuditDecoder {
    public static func decode(payload: [String: Any], receivedAt: Date) -> AuditEvent? {
        guard payload["hook_event_name"] as? String == "PostToolUse",
              let sessionId = payload["session_id"] as? String,
              let toolName = payload["tool_name"] as? String
        else { return nil }

        let input = payload["tool_input"] as? [String: Any]
        let op = AuditExtractor.claude(name: toolName, input: input)
        // PostToolUse 无 per-call 唯一 ID（官方确认），合成稳定键：
        // receivedAtMs 使同命令的不同调用互不碰撞，且随 spool 文件体重放稳定。
        let opId = (payload["tool_use_id"] as? String)
            ?? synthOpId(sessionId: sessionId, toolName: toolName, input: input, receivedAt: receivedAt)

        return AuditEvent(
            opId: opId, source: .claude, sessionId: sessionId, timestamp: receivedAt,
            kind: op.kind, tool: op.name, detail: op.detail,
            cwd: payload["cwd"] as? String,
            isError: sniffError(payload["tool_response"] ?? payload["tool_output"]))
    }

    /// 尽力嗅探失败标记（各工具形态不一，仅取显式布尔；取不到按成功）
    private static func sniffError(_ response: Any?) -> Bool {
        guard let dict = response as? [String: Any] else { return false }
        if let isError = dict["is_error"] as? Bool { return isError }
        if let interrupted = dict["interrupted"] as? Bool { return interrupted }
        return false
    }

    private static func synthOpId(
        sessionId: String, toolName: String, input: [String: Any]?, receivedAt: Date
    ) -> String {
        let inputJSON = input.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        } ?? Data()
        let ms = Int(receivedAt.timeIntervalSince1970 * 1000)
        var hasher = SHA256()
        hasher.update(data: Data("\(sessionId)\u{1}\(toolName)\u{1}\(ms)\u{1}".utf8))
        hasher.update(data: inputJSON)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return "claude:" + hex.prefix(32)
    }
}
