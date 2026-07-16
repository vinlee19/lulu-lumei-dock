import Foundation
import EurekaKit

/// Antigravity 会话索引：扫 ~/.gemini/antigravity-cli/conversations/<uuid>.db → AgentSessionInfo。
/// 内容是 protobuf blob，无法取标题/正文；只给 id(uuid)、工作区(裸扫 file://)、时间(mtime)、大小。
public enum AntigravitySessionIndexer {
    public static func index(
        conversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: conversationsRoot, includingPropertiesForKeys: nil)) ?? []
        var result: [AgentSessionInfo] = []
        for db in files where db.pathExtension == "db" {  // 跳过 -wal/-shm（非 .db 扩展名）
            guard let mtime = AntigravityPaths.newestMtime(dbURL: db),
                  now.timeIntervalSince(mtime) < window
            else { continue }
            result.append(AgentSessionInfo(
                source: .antigravity,
                id: db.deletingPathExtension().lastPathComponent,
                cwd: AntigravityPaths.cwd(dbURL: db),
                name: nil,  // 标题在 protobuf 里，拿不到 → 显示短 id
                startedAt: nil,
                lastActiveAt: mtime,
                sizeBytes: AntigravityPaths.sizeBytes(dbURL: db),
                transcriptPath: db.path))
        }
        return Array(result.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }
}
