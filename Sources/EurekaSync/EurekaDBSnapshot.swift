import EurekaStore
import Foundation

/// **Analytics snapshot** of eureka.sqlite: extracts the three analytics fact tables
/// (usage_records / task_history /
/// tool_calls) into a small standalone SQLite file that rides along with the cloud backup, so the
/// server side can analyze it directly with
/// DuckDB (sqlite_scanner ATTACH) or sqlite3 (scripts in Scripts/analytics/).
///
/// Why the whole database can't be VACUUM-uploaded the way opencode's is:
/// 1. eureka.sqlite itself holds the sync_state / sync_runs bookkeeping tables: persisting state
///    after an upload modifies
///    the database file, so the next round sees it as "changed" and uploads again, an endless
///    upload-every-round noise loop;
/// 2. the whole database also carries full-text indexes (fts_docs / knowledge_docs), which can
///    reach hundreds of MB and are useless for analytics.
/// So: the fingerprint covers only the three fact tables (row count + max rowid), and the
/// snapshot is rebuilt only when it changes; the snapshot file itself
/// goes through the regular single-file enumeration → size/mtime diff, the same path as every
/// other backed-up file.
public enum EurekaDBSnapshot {
    /// Analytics fact tables extracted into the snapshot (the server-side bootstrap.sql writes its
    /// queries against this list)
    public static let tables = ["usage_records", "task_history", "tool_calls"]

    /// Fact-table fingerprint: `table=rows:maxRowid` concatenated per table. Returns nil if the
    /// database is missing or a query fails.
    public static func fingerprint(dbPath: URL) -> String? {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return nil }
        var parts: [String] = []
        for table in tables {
            guard let row = try? db.query(
                "SELECT count(*), coalesce(max(rowid), 0) FROM \(table)",
                map: { ($0.int(0), $0.int(1)) }
            ).first else { return nil }
            parts.append("\(table)=\(row.0):\(row.1)")
        }
        return parts.joined(separator: ",")
    }

    /// Rebuilds the snapshot only when the fingerprint changed (temp file + atomic replace +
    /// fingerprint sidecar); returns whether it rebuilt. Best-effort: any failure quietly returns
    /// false, and this round syncs the old snapshot (if any) as usual.
    @discardableResult
    public static func materializeIfChanged(dbPath: URL, snapshotPath: URL) -> Bool {
        guard let fingerprint = fingerprint(dbPath: dbPath) else { return false }
        let fm = FileManager.default
        let sidecar = URL(fileURLWithPath: snapshotPath.path + ".fingerprint")
        if (try? String(contentsOf: sidecar, encoding: .utf8)) == fingerprint,
           fm.fileExists(atPath: snapshotPath.path) {
            return false
        }
        let temp = URL(fileURLWithPath: snapshotPath.path + ".tmp")
        do {
            try fm.createDirectory(
                at: snapshotPath.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: temp)
            // The snapshot connection uses itself as main and ATTACHes the source only for SELECT;
            // copying the whole batch inside one transaction keeps the three tables consistent. The
            // scoped block guarantees the connection closes before the rename (so no half-open file
            // gets replaced).
            do {
                let out = try SQLiteDB(path: temp.path)
                let escaped = dbPath.path.replacingOccurrences(of: "'", with: "''")
                try out.execute("ATTACH '\(escaped)' AS src")
                try out.transaction {
                    for table in tables {
                        try out.execute("CREATE TABLE \(table) AS SELECT * FROM src.\(table)")
                    }
                }
                try out.execute("DETACH src")
                // SQLiteDB creates databases in WAL mode by default, but a file with a WAL header
                // **can't be opened read-only** without its -shm (after the server downloads the
                // single file, a read-only ATTACH from sqlite3/DuckDB fails with CANTOPEN). The
                // snapshot must be a self-contained single file → switch back to the DELETE journal
                // before closing the connection.
                try out.execute("PRAGMA journal_mode=DELETE")
            }
            try? fm.removeItem(at: snapshotPath)
            try fm.moveItem(at: temp, to: snapshotPath)
            try fingerprint.write(to: sidecar, atomically: true, encoding: .utf8)
            return true
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
    }
}
