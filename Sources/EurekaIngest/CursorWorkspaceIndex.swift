import EurekaStore
import Foundation

/// Cursor 的 workspace 反查表：composer（会话）→ 工程目录。
///
/// 为什么需要单独一层：`composerHeaders` 只带 `workspaceId`（一串 hash），
/// 真正的目录在 `workspaceStorage/<wsId>/workspace.json` 的 `folder` 字段里。
/// 而且 `composerHeaders` **只覆盖当前已打开的 workspace**（实勘：本机 35 行 / 全库 151 个会话），
/// 其余历史会话的会话头散落在各 workspace 自己的
/// `state.vscdb → ItemTable['composer.composerData'].allComposers` 里。
///
/// 于是分两个口子：
///   - `folders(root:)` — 只读 `workspace.json`，轻量，tailer 每轮都可以调（带 30s 缓存）；
///   - `historicalComposers(root:)` — 要逐个打开 workspace 库，只给会话页/项目发现用。
public enum CursorWorkspaceIndex {
    /// 历史会话头（来自各 workspace 库的 `allComposers`）
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
    /// 目录增减只在开/关 workspace 时发生，30s 粒度足够，省掉每 2s 的 11 次小文件读
    /// 与 11 次 SQLite 只读连接（审计扫描是 2s 一轮，不缓存会把开销打进热路径）
    private static let cacheTTL: TimeInterval = 30

    /// `workspaceId → cwd`（绝对路径）。`empty-window` 之类没有 folder 的条目直接跳过。
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

    /// 各 workspace 库里的历史会话头。开销较大（逐库开只读连接）→ 同样 30s 缓存。
    /// 别放进 tailer 的每轮热路径；会话页刷新 / 项目发现 / 审计与用量扫描共用这份缓存。
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

    /// Cursor 的时间戳一律是 epoch 毫秒（`createdAt` / `lastUpdatedAt` / `recency`）
    static func epochMillis(_ raw: Any?) -> Date? {
        guard let millis = (raw as? NSNumber)?.doubleValue, millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    /// 仅供测试：清掉缓存，免得临时目录之间串台
    public static func resetCacheForTesting() {
        lock.lock()
        folderCache.removeAll()
        composerCache.removeAll()
        lock.unlock()
    }
}
