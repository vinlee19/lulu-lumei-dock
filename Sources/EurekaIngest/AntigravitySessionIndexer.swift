import Foundation
import EurekaKit

/// Antigravity session index: one session per conversation file, `<uuid>.db` under the CLI's
/// `~/.gemini/antigravity-cli/conversations` and `<uuid>.{pb,db}` under the IDE's
/// `~/.gemini/antigravity/conversations`.
///
/// The file gives id, time (mtime of the file and its -wal) and size. When a catalog is passed,
/// Antigravity's own summary databases add the title (else the first prompt) and workspace, and
/// move the activity time forward when a conversation was summarized after its last write; the CLI
/// `.db` bytes are still raw-scanned for the workspace when the catalog doesn't have it.
public enum AntigravitySessionIndexer {
    public static func index(
        conversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        ideConversationsRoot: URL? = nil,
        catalog: AntigravityConversationCatalog? = nil,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let summaries = catalog?.summaries() ?? [:]
        var seen = Set<String>()
        var result: [AgentSessionInfo] = []
        for root in [conversationsRoot] + [ideConversationsRoot].compactMap({ $0 }) {
            let files = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            // -wal/-shm siblings have other extensions and are skipped
            for file in files where file.pathExtension == "db" || file.pathExtension == "pb" {
                let id = file.deletingPathExtension().lastPathComponent
                guard !seen.contains(id), let fileMtime = AntigravityPaths.newestMtime(dbURL: file)
                else { continue }
                let summary = summaries[id]
                let mtime = [fileMtime, summary?.lastModified].compactMap { $0 }.max() ?? fileMtime
                guard now.timeIntervalSince(mtime) < window else { continue }
                seen.insert(id)
                result.append(AgentSessionInfo(
                    source: .antigravity,
                    id: id,
                    // The IDE's .pb is encrypted, so only a CLI .db is worth raw-scanning
                    cwd: summary?.cwd
                        ?? (file.pathExtension == "db" ? AntigravityPaths.cwd(dbURL: file) : nil),
                    name: summary?.displayName,
                    startedAt: nil,
                    lastActiveAt: mtime,
                    sizeBytes: AntigravityPaths.sizeBytes(dbURL: file),
                    transcriptPath: file.path))
            }
        }
        return Array(result.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }
}
