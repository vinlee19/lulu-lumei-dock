import Foundation

/// Reads another app's SQLite database that is in WAL mode without touching it.
///
/// Such databases usually have no `-shm` next to them while the owning app is closed, so a
/// read-only connection can't open them, and `immutable=1` would silently skip everything not yet
/// checkpointed into the main file. The database and its `-wal` (never `-shm`; SQLite rebuilds it
/// from the wal) are copied into a fresh temp directory, the copy is opened, and the directory is
/// deleted afterwards. Used for Antigravity's conversation and summary databases.
public enum SQLiteWALSnapshot {
    /// Size + mtime of the database and its wal; unchanged means the copy can be skipped
    public struct Fingerprint: Codable, Equatable, Sendable {
        public var size: Int64
        public var mtime: Double
        public var walSize: Int64
        public var walMtime: Double
    }

    public static func fingerprint(_ dbURL: URL) -> Fingerprint? {
        func stat(_ path: String) -> (Int64, Double)? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
                return nil
            }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (size, mtime)
        }
        guard let main = stat(dbURL.path) else { return nil }
        let wal = stat(dbURL.path + "-wal") ?? (0, 0)
        return Fingerprint(size: main.0, mtime: main.1, walSize: wal.0, walMtime: wal.1)
    }

    /// Copies `.db` (+ `-wal`) into a new temp directory and returns the copy's URL; the caller
    /// removes `copy.deletingLastPathComponent()` when done
    public static func copy(_ dbURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("eureka-walcopy-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = dir.appendingPathComponent(dbURL.lastPathComponent)
            try fm.copyItem(at: dbURL, to: target)
            let wal = URL(fileURLWithPath: dbURL.path + "-wal")
            if fm.fileExists(atPath: wal.path) {
                try fm.copyItem(at: wal, to: URL(fileURLWithPath: target.path + "-wal"))
            }
            return target
        } catch {
            try? fm.removeItem(at: dir)
            return nil
        }
    }

    /// Copies, opens the copy, runs `body`, and deletes the copy; nil when any step fails
    public static func read<T>(_ dbURL: URL, _ body: (SQLiteDB) throws -> T) -> T? {
        guard let copy = copy(dbURL) else { return nil }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        guard let db = try? SQLiteDB(path: copy.path) else { return nil }
        return try? body(db)
    }
}
