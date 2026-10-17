import EurekaKit
import EurekaStore
import Foundation

/// ZCode session index: reads only the `session` table of `~/.zcode/cli/db/db.sqlite` ->
/// `AgentSessionInfo`. Top-level sessions only (empty parent_id); `sess_subagent_*` child
/// sessions are subagents and stay out of the browse list.
/// Schema shared with opencode (time_created/time_updated are epoch millis); zcode has no
/// per-session transcript file, so sizeBytes is 0 (same as opencode).
public enum ZcodeSessionIndexer {
    public static func index(
        dbPath: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return [] }
        let cutoffMs = (now.timeIntervalSince1970 - window) * 1000
        let rows = (try? db.query("""
            SELECT id, directory, title, time_created, time_updated
            FROM session
            WHERE (parent_id IS NULL OR parent_id = '')
              AND time_updated >= ?
            ORDER BY time_updated DESC
            LIMIT ?
            """, [.real(cutoffMs), .int(Int64(maxSessions))]) { row in
            AgentSessionInfo(
                source: .zcode,
                id: row.text(0) ?? "",
                cwd: row.text(1),
                name: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                startedAt: Date(timeIntervalSince1970: row.real(3) / 1000),
                lastActiveAt: Date(timeIntervalSince1970: row.real(4) / 1000),
                sizeBytes: 0,
                transcriptPath: dbPath.path)
        }) ?? []
        return rows.filter { !$0.id.isEmpty }
    }

    /// Dirs of top-level sessions (merged into project-level skill discovery)
    public static func recentDirectories(dbPath: URL, maxSessions: Int = 300) -> [String] {
        index(dbPath: dbPath, maxSessions: maxSessions).compactMap(\.cwd)
    }
}
