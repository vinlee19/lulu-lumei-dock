import EurekaKit
import EurekaStore
import Foundation

/// Hermes session index: reads only the `sessions` table of `state.db` → `AgentSessionInfo`.
///
/// Differences from other sources:
///   - times are epoch **seconds** (opencode's table uses milliseconds);
///   - there is no transcript file: `transcriptPath` records the state.db path and `sizeBytes` is 0
///     (`TranscriptReader.loadHermes` uses it + the session id to look up `messages`);
///   - a session may still be running (`ended_at IS NULL`); last-active time is the first non-null
///     of `ended_at` → the session's last message → `started_at`;
///   - each profile has its own state.db, so the public entry point is `indexAll`.
///
/// Only top-level sessions (`parent_session_id` empty): child sessions are delegate_task subagents
/// and compaction splits and stay out of the browse list. Archived sessions (`archived = 1`) are
/// skipped too.
public enum HermesSessionIndexer {
    /// Single-db index
    public static func index(
        dbPath: URL,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return [] }
        let cutoff = now.timeIntervalSince1970 - window
        let rows = (try? db.query("""
            SELECT s.id, s.cwd, s.title, s.started_at,
                   COALESCE(s.ended_at,
                            (SELECT MAX(m.timestamp) FROM messages m WHERE m.session_id = s.id),
                            s.started_at)
            FROM sessions s
            WHERE (s.parent_session_id IS NULL OR s.parent_session_id = '')
              AND s.archived = 0
              AND s.started_at >= ?
            ORDER BY s.started_at DESC
            LIMIT ?
            """, [.real(cutoff), .int(Int64(maxSessions))]) { row in
            AgentSessionInfo(
                source: .hermes,
                id: row.text(0) ?? "",
                cwd: row.text(1).flatMap { $0.isEmpty ? nil : $0 },
                name: row.text(2).flatMap { $0.isEmpty ? nil : $0 },
                startedAt: Date(timeIntervalSince1970: row.real(3)),
                lastActiveAt: Date(timeIntervalSince1970: row.real(4)),
                sizeBytes: 0,
                transcriptPath: dbPath.path)
        }) ?? []
        return rows.filter { !$0.id.isEmpty }
    }

    /// Merged index over the default home + each profile's state.db (most recently active first,
    /// capped overall)
    public static func indexAll(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        var all: [AgentSessionInfo] = []
        for db in HermesPaths.allStateDBs(environment: environment) {
            all += index(dbPath: db, window: window, maxSessions: maxSessions, now: now)
        }
        return Array(all.sorted { $0.lastActiveAt > $1.lastActiveAt }.prefix(maxSessions))
    }

    /// Recent session cwds (merged into project-level discovery; Hermes has no project-level
    /// skills/memory, only the plan directory uses them)
    public static func recentDirectories(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        maxSessions: Int = 300
    ) -> [String] {
        indexAll(environment: environment, maxSessions: maxSessions).compactMap(\.cwd)
    }
}
