import CryptoKit
import Foundation
import EurekaKit

/// Decodes a Claude Code PostToolUse hook payload into an audit event. Only PostToolUse is
/// recognised; the tool_response/tool_output body is dropped and only the is_error boolean is
/// sniffed.
///
/// Trae CN reuses the same path (`source: .trae`): its hook payload has Claude's shape, down to
/// `tool_response` (see the notes on `ClaudeHookDecoder`).
public enum ClaudeAuditDecoder {
    public static func decode(
        payload: [String: Any], receivedAt: Date, source: AgentSource = .claude
    ) -> AuditEvent? {
        guard payload["hook_event_name"] as? String == "PostToolUse",
              let sessionId = payload["session_id"] as? String,
              let toolName = payload["tool_name"] as? String
        else { return nil }

        let input = payload["tool_input"] as? [String: Any]
        let op = AuditExtractor.claude(name: toolName, input: input)
        // PostToolUse has no per-call unique ID (officially confirmed), so synthesize a stable key:
        // receivedAtMs keeps different calls of the same command apart and is stable across spool
        // file replays.
        let opId = (payload["tool_use_id"] as? String)
            ?? synthOpId(
                sessionId: sessionId, toolName: toolName, input: input,
                receivedAt: receivedAt, source: source)

        return AuditEvent(
            opId: opId, source: source, sessionId: sessionId, timestamp: receivedAt,
            kind: op.kind, tool: op.name, detail: op.detail,
            cwd: payload["cwd"] as? String,
            isError: sniffError(payload["tool_response"] ?? payload["tool_output"]))
    }

    /// Best-effort sniffing of a failure marker (tool shapes vary; only explicit booleans count;
    /// absent means success)
    private static func sniffError(_ response: Any?) -> Bool {
        guard let dict = response as? [String: Any] else { return false }
        if let isError = dict["is_error"] as? Bool { return isError }
        if let interrupted = dict["interrupted"] as? Bool { return interrupted }
        return false
    }

    private static func synthOpId(
        sessionId: String, toolName: String, input: [String: Any]?, receivedAt: Date,
        source: AgentSource
    ) -> String {
        let inputJSON = input.flatMap {
            try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        } ?? Data()
        let ms = Int(receivedAt.timeIntervalSince1970 * 1000)
        var hasher = SHA256()
        hasher.update(data: Data("\(sessionId)\u{1}\(toolName)\u{1}\(ms)\u{1}".utf8))
        hasher.update(data: inputJSON)
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // Prefixed with source: Claude and Trae session id spaces are unrelated, so the same hash
        // must not collide
        return source.rawValue + ":" + hex.prefix(32)
    }
}
