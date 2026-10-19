import EurekaKit
import EurekaStore
import Foundation

/// opencode session index: read-only `opencode.db` → `AgentSessionInfo`. Reads both generations of
/// session tables: 1.x `session` and 2.x `session_v2` (opencode 2.x / OpenChamber write only the
/// latter).
/// On upgrade, 1.x sessions are copied into `session_v2` under their original ids; only one row per
/// id is kept (the 2.x one).
/// Only top-level sessions (empty parent_id) are taken; child sessions are opencode subagents and
/// stay out of the browse list.
/// Times are epoch milliseconds; opencode has no transcript file, so sizeBytes is recorded as 0.
public enum OpencodeSessionIndexer {
    public static func index(
        dbPath: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return [] }
        let cutoffMs = (now.timeIntervalSince1970 - window) * 1000

        func query(_ table: String) -> [AgentSessionInfo] {
            // Table missing (1.x databases have no session_v2) → query fails → empty
            (try? db.query("""
                SELECT id, directory, title, time_created, time_updated
                FROM \(table)
                WHERE (parent_id IS NULL OR parent_id = '')
                  AND time_updated >= ?
                ORDER BY time_updated DESC
                LIMIT ?
                """, [.real(cutoffMs), .int(Int64(maxSessions))]) { row in
                AgentSessionInfo(
                    source: .opencode,
                    id: row.text(0) ?? "",
                    cwd: row.text(1),
                    name: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                    startedAt: Date(timeIntervalSince1970: row.real(3) / 1000),
                    lastActiveAt: Date(timeIntervalSince1970: row.real(4) / 1000),
                    sizeBytes: 0,
                    transcriptPath: dbPath.path)
            }) ?? []
        }

        let v2 = query("session_v2")
        let v2Ids = Set(v2.map(\.id))
        let merged = v2 + query("session").filter { !v2Ids.contains($0.id) }
        return Array(merged
            .filter { !$0.id.isEmpty }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(maxSessions))
    }

    /// Top-level session directories (merged into project-level skill/agent discovery)
    public static func recentDirectories(dbPath: URL, maxSessions: Int = 300) -> [String] {
        index(dbPath: dbPath, maxSessions: maxSessions).compactMap(\.cwd)
    }
}
