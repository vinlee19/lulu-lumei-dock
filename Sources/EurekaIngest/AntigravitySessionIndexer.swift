import Foundation
import EurekaKit

/// Antigravity session index: scans ~/.gemini/antigravity-cli/conversations/<uuid>.db →
/// AgentSessionInfo. The content is a protobuf blob, so no title/body; only id (uuid), workspace
/// (raw scan for file://), time (mtime) and size.
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
        for db in files where db.pathExtension == "db" {  // Skip -wal/-shm (not a .db extension)
            guard let mtime = AntigravityPaths.newestMtime(dbURL: db),
                  now.timeIntervalSince(mtime) < window
            else { continue }
            result.append(AgentSessionInfo(
                source: .antigravity,
                id: db.deletingPathExtension().lastPathComponent,
                cwd: AntigravityPaths.cwd(dbURL: db),
                name: nil,  // title is inside the protobuf → show the short id
                startedAt: nil,
                lastActiveAt: mtime,
                sizeBytes: AntigravityPaths.sizeBytes(dbURL: db),
                transcriptPath: db.path))
        }
        return Array(result.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }
}
