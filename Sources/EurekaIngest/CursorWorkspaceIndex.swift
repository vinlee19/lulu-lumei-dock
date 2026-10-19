import EurekaStore
import Foundation

/// Cursor's workspace lookup table: composer (session) → project directory.
///
/// Why a separate layer: `composerHeaders` only carries `workspaceId` (a hash string), while the
/// real directory is in the `folder` field of `workspaceStorage/<wsId>/workspace.json`. Also,
/// `composerHeaders` **only covers currently open workspaces** (observed: 35 rows locally vs 151
/// sessions in the whole database); the headers of the remaining historical sessions are scattered
/// across each workspace's own `state.vscdb → ItemTable['composer.composerData'].allComposers`.
///
/// Hence two entry points:
///   - `folders(root:)` — reads only `workspace.json`; lightweight, so the tailer can call it every
///     pass (with a 30s cache);
///   - `historicalComposers(root:)` — has to open each workspace database; only for the sessions
///     page / project discovery.
public enum CursorWorkspaceIndex {
    /// Historical session header (from a workspace database's `allComposers`)
    public struct Entry: Equatable, Sendable {
        public var composerId: String
        public var workspaceId: String
        public var cwd: String?
        public var name: String?
        public var createdAt: Date?
        public var lastUpdatedAt: Date?

        public init(
            composerId: String, workspaceId: String, cwd: String?, name: String?,
            createdAt: Date?, lastUpdatedAt: Date?
        ) {
            self.composerId = composerId
            self.workspaceId = workspaceId
            self.cwd = cwd
            self.name = name
            self.createdAt = createdAt
            self.lastUpdatedAt = lastUpdatedAt
        }
    }

    private static let lock = NSLock()
    private static var folderCache: [String: (value: [String: String], at: Date)] = [:]
    private static var composerCache: [String: (value: [Entry], at: Date)] = [:]
    /// Directories only change when a workspace is opened/closed, so 30s granularity is enough. It
    /// saves 11 small file reads and 11 read-only SQLite connections every 2s (the audit scan runs
    /// every 2s; without the cache that cost lands on the hot path).
    private static let cacheTTL: TimeInterval = 30

    /// `workspaceId → cwd` (absolute path). Folderless entries such as `empty-window` are skipped.
    public static func folders(
        root: URL = CursorPaths.workspaceStorageRoot(), now: Date = Date()
    ) -> [String: String] {
        lock.lock()
        if let cached = folderCache[root.path], now.timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        var result: [String: String] = [:]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in entries {
            let file = dir.appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: file),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let folder = root["folder"] as? String,
                let path = URL(string: folder)?.path, !path.isEmpty
            else { continue }
            result[dir.lastPathComponent] = path
        }

        lock.lock()
        folderCache[root.path] = (result, now)
        lock.unlock()
        return result
    }

    /// Historical session headers from each workspace database. Expensive (one read-only connection
    /// per database) → also cached for 30s. Keep it off the tailer's per-pass hot path; sessions
    /// page refresh / project discovery / audit and usage scans share this cache.
    public static func historicalComposers(
        root: URL = CursorPaths.workspaceStorageRoot(), now: Date = Date()
    ) -> [Entry] {
        lock.lock()
        if let cached = composerCache[root.path], now.timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        let folders = folders(root: root, now: now)
        var results: [Entry] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)) ?? []
        for dir in entries {
            let workspaceId = dir.lastPathComponent
            let dbPath = dir.appendingPathComponent("state.vscdb").path
            guard FileManager.default.fileExists(atPath: dbPath),
                let db = try? SQLiteDB(path: dbPath, readOnly: true)
            else { continue }
            let blobs = (try? db.query(
                "SELECT value FROM ItemTable WHERE key = 'composer.composerData'",
                []) { $0.text(0) }) ?? []
            for blob in blobs.compactMap({ $0 }) {
                guard let data = blob.data(using: .utf8),
                    let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                    let all = root["allComposers"] as? [[String: Any]]
                else { continue }
                for header in all {
                    guard let composerId = header["composerId"] as? String, !composerId.isEmpty,
                        header["isDraft"] as? Bool != true
                    else { continue }
                    results.append(
                        Entry(
                            composerId: composerId,
                            workspaceId: workspaceId,
                            cwd: folders[workspaceId],
                            name: (header["name"] as? String).flatMap {
                                $0.isEmpty ? nil : $0
                            },
                            createdAt: epochMillis(header["createdAt"]),
                            lastUpdatedAt: epochMillis(header["lastUpdatedAt"])))
                }
            }
        }
        lock.lock()
        composerCache[root.path] = (results, now)
        lock.unlock()
        return results
    }

    /// Cursor timestamps are always epoch milliseconds (`createdAt` / `lastUpdatedAt` / `recency`)
    static func epochMillis(_ raw: Any?) -> Date? {
        guard let millis = (raw as? NSNumber)?.doubleValue, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// Test-only: clears the cache so temporary directories don't bleed into each other
    public static func resetCacheForTesting() {
        lock.lock()
        folderCache.removeAll()
        composerCache.removeAll()
        lock.unlock()
    }
}
