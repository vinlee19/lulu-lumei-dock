import EurekaKit
import EurekaStore
import Foundation

/// Cursor 会话索引：只读 `state.vscdb` 的 `cursorDiskKV` → `AgentSessionInfo`。
///
/// 主源是 `composerData:<id>` 的键前缀范围扫描（走 `key` 唯一索引，实勘 151 个会话 40ms），
/// 名字/时间直接由 SQLite 的 `json_extract` 在 C 侧取出，不把 200KB 的 JSON 搬进 Swift。
/// 万一系统 libsqlite3 没编 JSON1，整条 query 会抛错 → 自动退回只用会话头（`CursorWorkspaceIndex`），
/// 少一部分历史但不至于整块瞎掉。
///
/// cwd 不在会话里，要经 `composerHeaders.workspaceId`（当前打开的 workspace）
/// 或各 workspace 库的 `allComposers`（历史）反查；两边都查不到就记 nil。
/// Cursor 无 transcript 文件，故 `transcriptPath` 记库路径、`sizeBytes` 记 0（同 opencode / hermes）。
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

        // composerId → (cwd, 标题兜底)
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
            // JSON1 缺席或库里没有 composerData：退回会话头
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

    /// 顶层会话目录集合（供项目发现并入）
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

    /// 用量 / 审计扫描用的「全量历史」窗口：它们各有 per-composer 水位，
    /// 回访老会话近乎零成本，按 30 天截断反而会让一个月前的用量永远进不了账。
    /// 用有限值而不是 `.greatestFiniteMagnitude`，见 `cutoffMillis` 的注释。
    public static let fullHistoryWindow: TimeInterval = 100 * 365 * 86400

    /// 时间窗 → epoch 毫秒下界。
    /// ⚠️ 会话页「全部」传的是 `.greatestFiniteMagnitude`，直接 `(now - window) * 1000`
    /// 会溢出成 -inf，`Int64(-inf)` 在 Swift 里是**运行时崩溃**（不是截断）。故先夹再转。
    static func cutoffMillis(window: TimeInterval, now: Date) -> Int64 {
        let seconds = now.timeIntervalSince1970 - window
        guard seconds.isFinite else { return 0 }
        return Int64(max(0, seconds) * 1000)
    }

    private static func composerRows(
        db: SQLiteDB, cutoffMs: Int64, maxSessions: Int
    ) -> [Row] {
        // 键前缀范围扫描（`composerData;` 是 `:` 的下一个 ASCII 字符）走覆盖索引，
        // 不能写 LIKE：默认 LIKE 大小写不敏感，优化器不会退化成索引区间查找。
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

    /// 当前打开的 workspace 里的 composer → workspaceId
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
