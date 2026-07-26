import Foundation
import EurekaKit

/// Codex 会话索引：~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// resume 的旧会话在创建日目录原地追加，故整树枚举后按 mtime 窗口过滤。
/// 正式 thread_name 优先；缺失时流式读取 session_meta 与首条完整 user_message 兜底。
public enum CodexSessionIndexer {
    public static func index(
        sessionsRoot: URL,
        threadNameIndexURL: URL? = nil,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        // window 可传 .greatestFiniteMagnitude（"显示全部"），这里必须是无换算的
        // 区间比较——先除 86400 再取 Int 会直接溢出崩溃。
        var candidates: [(URL, Date, UInt64)] = []
        for entry in CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot) {
            guard let mtime = entry.mtime, now.timeIntervalSince(mtime) < window
            else { continue }
            candidates.append((entry.url, mtime, entry.size))
        }
        candidates.sort { $0.1 > $1.1 }
        let names = CodexThreadNameIndex.load(
            threadNameIndexURL ?? CodexThreadNameIndex.resolvedURL(for: sessionsRoot))
        return candidates.prefix(maxSessions).map { file, mtime, size in
            let head = headInfo(fileURL: file)
            let id = head.id ?? fallbackId(file)
            return AgentSessionInfo(
                source: .codex,
                id: id,
                cwd: head.cwd,
                name: names[id] ?? head.name,
                startedAt: head.startedAt,
                lastActiveAt: mtime,
                sizeBytes: size,
                transcriptPath: file.path
            )
        }
    }

    static func headInfo(fileURL: URL) -> (id: String?, cwd: String?, name: String?, startedAt: Date?) {
        var id: String?
        var cwd: String?
        var name: String?
        var startedAt: Date?
        CodexJSONLReader.forEachCompleteLine(fileURL, includeTrailingLine: true) { line in
            guard
                let object = try? JSONSerialization.jsonObject(with: line),
                let root = object as? [String: Any],
                let payload = root["payload"] as? [String: Any]
            else { return true }
            switch root["type"] as? String {
            case "session_meta":
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
                // 新版 Codex 在 payload.timestamp 给出真实开始时间；旧版退顶层时间。
                if let ts = payload["timestamp"] as? String ?? root["timestamp"] as? String {
                    startedAt = ClaudeSessionFirstTimestamp.parse(ts)
                }
            case "event_msg":
                if name == nil, payload["type"] as? String == "user_message",
                   let message = payload["message"] as? String {
                    name = summarizeTitle(message)
                }
            default:
                break
            }
            return !(id != nil && name != nil)
        }
        return (id, cwd, name, startedAt)
    }

    /// rollout-2026-06-08T23-36-02-<uuid>.jsonl → uuid
    private static func fallbackId(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }
}
