import Foundation
import EurekaKit

/// Codex 会话索引：~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// 正式 thread_name 优先；缺失时流式读取 session_meta 与首条完整 user_message 兜底。
public enum CodexSessionIndexer {
    public static func index(
        sessionsRoot: URL,
        threadNameIndexURL: URL? = nil,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let calendar = Calendar.current
        var candidates: [(URL, Date, UInt64)] = []
        let days = Int(window / 86400) + 1
        for dayOffset in 0..<days {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let dir = sessionsRoot
                .appendingPathComponent(String(format: "%04d", parts.year ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.month ?? 0), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", parts.day ?? 0), isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(
                    forKeys: [.contentModificationDateKey, .fileSizeKey]),
                    let mtime = values.contentModificationDate
                else { continue }
                candidates.append((file, mtime, UInt64(values.fileSize ?? 0)))
            }
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
