import Foundation
import EurekaKit

/// grok 会话索引：扫 ~/.grok/sessions/<enc-cwd>/<uuid>/summary.json → AgentSessionInfo。
/// 名字取 summary.json 的 generated_title；对话查看器读同目录 chat_history.jsonl。
public enum GrokSessionIndexer {
    public static func index(
        sessionsRoot: URL = GrokPaths.sessionsRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        var results: [AgentSessionInfo] = []
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                guard let info = sessionInfo(dir: sessionDir),
                      now.timeIntervalSince(info.lastActiveAt) < window
                else { continue }
                results.append(info)
            }
        }
        return Array(results.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    private static func sessionInfo(dir: URL) -> AgentSessionInfo? {
        let summaryURL = dir.appendingPathComponent("summary.json")
        guard let data = try? Data(contentsOf: summaryURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return nil }

        let info = root["info"] as? [String: Any]
        let id = (info?["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? dir.lastPathComponent
        let cwd = (info?["cwd"] as? String) ?? (root["cwd"] as? String)
        let title = (root["generated_title"] as? String)
            ?? (root["session_summary"] as? String)
        let startedAt = GrokEventDecoder.parseDate(root["created_at"] as? String)
        let updatedAt = GrokEventDecoder.parseDate(root["last_active_at"] as? String)
            ?? GrokEventDecoder.parseDate(root["updated_at"] as? String)

        let chatHistory = dir.appendingPathComponent("chat_history.jsonl")
        let size = (try? chatHistory.resourceValues(
            forKeys: [.fileSizeKey]))?.fileSize ?? 0
        // updated_at 缺失时退 summary.json 的 mtime
        let lastActive = updatedAt
            ?? (try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            ?? startedAt
            ?? Date(timeIntervalSince1970: 0)

        return AgentSessionInfo(
            source: .grok,
            id: id,
            cwd: cwd,
            name: title.flatMap { $0.isEmpty ? nil : $0 },
            startedAt: startedAt,
            lastActiveAt: lastActive,
            sizeBytes: UInt64(size),
            transcriptPath: chatHistory.path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
