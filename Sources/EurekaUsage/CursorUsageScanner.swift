import EurekaKit
import EurekaStore
import Foundation

/// 扫描 Cursor `state.vscdb` 的助手气泡累计 token 用量。
///
/// **口径（重要，改之前先读完）**：Cursor 的 `tokenCount` 只有
/// `{inputTokens, outputTokens}` 两个数，**没有缓存读写拆分**，而 `inputTokens`
/// 是「这一轮送进去的整个上下文」——同一会话里逐轮单调递增（实勘
/// 50684 → 59288 → 85571 → 93562 → 111408 → 112382）。直接当新鲜输入记账
/// 会把一个会话的输入放大十几倍。
/// 所以按**相邻差分**归集（与 `CodexUsageScanner` 对 `total_token_usage` 的做法同源）：
///   `cacheRead = 上一轮的 inputTokens`，`input = max(0, 本轮 - 上一轮)`；
///   本轮反而变小 = 发生了压缩/新开话题，视作重置（`cacheRead = 0`）。
/// 于是一个会话的「新鲜输入」总和 ≈ 最终上下文大小，符合直觉。
///
/// 模型名一律写成 `cursor/<model>`：Cursor 按请求订阅计费，且 93% 的轮次只报
/// `default`（真实模型名在 `modelInfo` 里只有少数几条有）。`pricing.json` 里
/// `cursor/` 前缀标了 `unknown` → **成本恒为 0**，只统计 token，不给误导性金额。
///
/// 增量：每 composer 一条 `scan_files`（key `cursor-usage://<composerId>`），
/// `offset` = 已计入的气泡条数，`inode` = 库 inode（库被换掉则整体重来）。
/// 气泡只追加不重排，所以按条数做水位天然幂等，重扫返回 0。
public final class CursorUsageScanner {
    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    private let recentWindow: TimeInterval
    private let maxSessions: Int

    /// 每 composer 的扫描私有状态（存 scan_files.extra）
    private struct Extra: Codable {
        var project: String?
        var lastInput: Int?
        /// 上次扫过时该会话的 lastActiveAt：没动过就整段跳过，
        /// 免得每轮把 100+ 个 composerData（单个可达 236KB）读出来白解一遍 JSON
        var seenActiveAt: Double?
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// `sessions` 由调用方注入（`EurekaUsage` 不依赖 `EurekaIngest`，
    /// 拿不到 `CursorSessionIndexer`）：(composerId, cwd, lastActiveAt) 三元组。
    public typealias SessionRef = (id: String, cwd: String?, lastActiveAt: Date)
    private let sessions: (Date) -> [SessionRef]

    public init(
        dbPath: URL,
        store: EurekaStore,
        workspaceStorageRoot: URL,
        recentWindow: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        sessions: @escaping (Date) -> [SessionRef]
    ) {
        self.dbPath = dbPath
        self.store = store
        self.workspaceStorageRoot = workspaceStorageRoot
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
        self.sessions = sessions
    }

    @discardableResult
    public func scanOnce(now: Date = Date()) throws -> Int {
        guard FileManager.default.fileExists(atPath: dbPath.path),
            let db = try? SQLiteDB(path: dbPath.path, readOnly: true)
        else { return 0 }
        let inode = Self.fileInode(dbPath.path)
        var inserted = 0
        for session in sessions(now).prefix(maxSessions) {
            inserted += try scan(session: session, db: db, inode: inode)
        }
        return inserted
    }

    private func scan(session: SessionRef, db: SQLiteDB, inode: Int64) throws -> Int {
        let stateKey = "cursor-usage://\(session.id)"
        let saved = try store.scanState.fileState(path: stateKey)
        var processed = 0
        var extra = Extra()
        if let saved, saved.inode == inode {
            processed = Int(saved.offset)
            if let json = saved.extra,
                let decoded = try? JSONDecoder().decode(Extra.self, from: Data(json.utf8)) {
                extra = decoded
                if let seen = decoded.seenActiveAt,
                    session.lastActiveAt.timeIntervalSince1970 <= seen {
                    return 0
                }
            }
        }
        extra.seenActiveAt = session.lastActiveAt.timeIntervalSince1970
        if extra.project == nil {
            extra.project = projectResolver.projectName(forCwd: session.cwd)
        }

        guard let composer = Self.json(db: db, key: "composerData:\(session.id)") else { return 0 }
        let bubbleIds = (composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { $0["bubbleId"] as? String }
        // 没有新气泡也要落一次 state：把 seenActiveAt 推上去，下轮才跳得掉
        guard bubbleIds.count > processed else {
            try store.scanState.setFileState(
                path: stateKey,
                .init(inode: inode, offset: Int64(processed), extra: Self.encode(extra)))
            return 0
        }
        let fallbackModel = ((composer["modelConfig"] as? [String: Any])?["modelName"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "default"

        var records: [UsageRecord] = []
        var toolBumps: [(day: String, kind: String, name: String, ts: Double)] = []
        var promptCount = 0
        for bubbleId in bubbleIds[processed...] {
            guard let bubble = Self.json(db: db, key: "bubbleId:\(session.id):\(bubbleId)") else {
                continue
            }
            let timestamp = (bubble["createdAt"] as? String)
                .flatMap { Self.iso8601.date(from: $0) } ?? session.lastActiveAt
            // type 1 = 用户气泡 → 会话页的「对话数」
            if (bubble["type"] as? NSNumber)?.intValue == 1 { promptCount += 1 }

            if let tool = bubble["toolFormerData"] as? [String: Any],
                let name = tool["name"] as? String, !name.isEmpty {
                toolBumps.append((
                    day: Self.dayFormatter.string(from: timestamp),
                    kind: CursorToolNames.usageKind(name),
                    name: CursorToolNames.displayName(name),
                    ts: timestamp.timeIntervalSince1970))
            }

            guard let counts = bubble["tokenCount"] as? [String: Any] else { continue }
            let rawInput = (counts["inputTokens"] as? NSNumber)?.intValue ?? 0
            let output = (counts["outputTokens"] as? NSNumber)?.intValue ?? 0
            guard rawInput > 0 || output > 0 else { continue }

            let previous = extra.lastInput ?? 0
            // 上下文变小 = 压缩或换话题，缓存作废，本轮整份都算新鲜输入
            let reset = rawInput < previous
            let cacheRead = reset ? 0 : previous
            let input = reset ? rawInput : rawInput - previous
            extra.lastInput = rawInput

            let model = ((bubble["modelInfo"] as? [String: Any])?["modelName"] as? String)
                .flatMap { $0.isEmpty ? nil : $0 } ?? fallbackModel
            records.append(UsageRecord(
                source: .cursor, model: "cursor/\(model)", project: extra.project,
                sessionId: session.id, timestamp: timestamp,
                inputTokens: input, outputTokens: output,
                cacheCreationTokens: 0, cacheReadTokens: cacheRead))
        }

        var inserted = 0
        try store.scanState.transaction {
            try store.usage.insert(records)
            inserted = records.count
            for bump in toolBumps {
                try store.toolCalls.bump(
                    day: bump.day, source: .cursor, kind: bump.kind, name: bump.name, ts: bump.ts)
            }
            try store.scanState.setFileState(
                path: stateKey,
                .init(inode: inode, offset: Int64(bubbleIds.count), extra: Self.encode(extra)))
            // 首扫（processed == 0）覆盖写，之后增量累加——与 CodeBuddy 同口径
            try store.sessionStats.recordPrompts(
                path: stateKey, sessionId: session.id, count: promptCount, reset: processed == 0)
        }
        return inserted
    }

    private static func encode(_ extra: Extra) -> String? {
        String(data: (try? JSONEncoder().encode(extra)) ?? Data(), encoding: .utf8)
    }

    static func json(db: SQLiteDB, key: String) -> [String: Any]? {
        let rows = (try? db.query(
            "SELECT value FROM cursorDiskKV WHERE key = ?", [.text(key)]) { $0.text(0) }) ?? []
        guard let text = rows.first.flatMap({ $0 }), let data = text.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func fileInode(_ path: String) -> Int64 {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int64(info.st_ino)
    }
}
