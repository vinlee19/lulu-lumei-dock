import EurekaKit
import EurekaStore
import Foundation

/// Cursor session index: read-only over `cursorDiskKV` in `state.vscdb` → `AgentSessionInfo`.
///
/// The main source is a key-prefix range scan over `composerData:<id>` (uses the unique `key`
/// index; 151 sessions in 40ms observed), with name/time extracted on the C side by SQLite's
/// `json_extract`, so the 200KB JSON never gets hauled into Swift. If the system libsqlite3 was
/// built without JSON1, the whole query throws → it falls back automatically to session headers
/// only (`CursorWorkspaceIndex`), losing some history but never going blind entirely.
///
/// cwd isn't in the session; it is looked up via `composerHeaders.workspaceId` (currently open
/// workspaces) or each workspace database's `allComposers` (history); if neither has it, nil is
/// recorded. Cursor has no transcript file, so `transcriptPath` records the database path and
/// `sizeBytes` records 0 (same as opencode / hermes).
public enum CursorSessionIndexer {
    public static func index(
        dbPath: URL = CursorPaths.globalStateDB(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        guard FileManager.default.fileExists(atPath: dbPath.path),
            let db = try? SQLiteDB(path: dbPath.path, readOnly: true)
        else { return [] }

        // composerId → (cwd, fallback title)
        var cwds: [String: String] = [:]
        var names: [String: String] = [:]
        for entry in CursorWorkspaceIndex.historicalComposers(root: workspaceStorageRoot) {
            if let cwd = entry.cwd { cwds[entry.composerId] = cwd }
            if let name = entry.name { names[entry.composerId] = name }
        }
        let folders = CursorWorkspaceIndex.folders(root: workspaceStorageRoot, now: now)
        for (composerId, workspaceId) in openWorkspaceMap(db: db) {
            if let cwd = folders[workspaceId] { cwds[composerId] = cwd }
        }

        let cutoffMs = Self.cutoffMillis(window: window, now: now)
        var rows = composerRows(db: db, cutoffMs: cutoffMs, maxSessions: maxSessions)
        if rows.isEmpty {
            // JSON1 missing or no composerData in the database: fall back to session headers
            rows = CursorWorkspaceIndex.historicalComposers(root: workspaceStorageRoot)
                .compactMap { entry in
                    guard let updated = entry.lastUpdatedAt,
                        Int64(max(0, updated.timeIntervalSince1970) * 1000) >= cutoffMs
                    else { return nil }
                    return Row(
                        composerId: entry.composerId, name: entry.name,
                        createdAt: entry.createdAt, lastUpdatedAt: updated)
                }
        }

        return rows
            .map { row in
                AgentSessionInfo(
                    source: .cursor,
                    id: row.composerId,
                    cwd: cwds[row.composerId],
                    name: row.name ?? names[row.composerId],
                    startedAt: row.createdAt,
                    lastActiveAt: row.lastUpdatedAt,
                    sizeBytes: 0,
                    transcriptPath: dbPath.path)
            }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(maxSessions)
            .map { $0 }
    }

    /// Set of top-level session directories (merged into project discovery)
    public static func recentDirectories(
        dbPath: URL = CursorPaths.globalStateDB(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        maxSessions: Int = 300
    ) -> [String] {
        index(dbPath: dbPath, workspaceStorageRoot: workspaceStorageRoot,
            maxSessions: maxSessions).compactMap(\.cwd)
    }

    struct Row {
        var composerId: String
        var name: String?
        var createdAt: Date?
        var lastUpdatedAt: Date
    }

    /// "Full history" window for the usage / audit scans: each keeps a per-composer watermark, so
    /// revisiting old sessions is nearly free, whereas truncating at 30 days would keep usage from
    /// a month ago out of the ledger forever. A finite value rather than
    /// `.greatestFiniteMagnitude`; see the comment on `cutoffMillis`.
    public static let fullHistoryWindow: TimeInterval = 100 * 365 * 86400

    /// Time window → lower bound in epoch milliseconds.
    /// ⚠️ The sessions page's "All" passes `.greatestFiniteMagnitude`; computing
    /// `(now - window) * 1000` directly overflows to -inf, and `Int64(-inf)` is a **runtime crash**
    /// in Swift (not a truncation). So clamp before converting.
    static func cutoffMillis(window: TimeInterval, now: Date) -> Int64 {
        let seconds = now.timeIntervalSince1970 - window
        guard seconds.isFinite else { return 0 }
        return Int64(max(0, seconds) * 1000)
    }

    private static func composerRows(
        db: SQLiteDB, cutoffMs: Int64, maxSessions: Int
    ) -> [Row] {
        // Key-prefix range scan (`;` in `composerData;` is the ASCII character right after `:`)
        // uses the covering index. It can't be written as LIKE: default LIKE is case-insensitive,
        // so the optimizer won't turn it into an index range lookup.
        let rows = (try? db.query("""
            SELECT substr(key, 14),
                   json_extract(value, '$.name'),
                   json_extract(value, '$.createdAt'),
                   json_extract(value, '$.lastUpdatedAt')
            FROM cursorDiskKV
            WHERE key >= 'composerData:' AND key < 'composerData;'
              AND json_extract(value, '$.isDraft') IS NOT 1
              AND json_extract(value, '$.isBestOfNSubcomposer') IS NOT 1
              AND json_extract(value, '$.lastUpdatedAt') >= ?
            ORDER BY json_extract(value, '$.lastUpdatedAt') DESC
            LIMIT ?
            """, [.int(cutoffMs), .int(Int64(maxSessions))]) { row -> Row? in
            let composerId = row.text(0) ?? ""
            guard !composerId.isEmpty, !row.isNull(3) else { return nil }
            return Row(
                composerId: composerId,
                name: row.text(1).flatMap { $0.isEmpty ? nil : $0 },
                createdAt: row.isNull(2)
                    ? nil : Date(timeIntervalSince1970: Double(row.int(2)) / 1000),
                lastUpdatedAt: Date(timeIntervalSince1970: Double(row.int(3)) / 1000))
        }) ?? []
        return rows.compactMap { $0 }
    }

    /// composer → workspaceId for the currently open workspaces
    private static func openWorkspaceMap(db: SQLiteDB) -> [String: String] {
        let rows = (try? db.query(
            "SELECT composerId, workspaceId FROM composerHeaders", []) { row in
            (row.text(0) ?? "", row.text(1) ?? "")
        }) ?? []
        var map: [String: String] = [:]
        for (composerId, workspaceId) in rows where !composerId.isEmpty && !workspaceId.isEmpty {
            map[composerId] = workspaceId
        }
        return map
    }
}
