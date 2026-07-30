import EurekaKit
import EurekaStore
import Foundation

/// 扫描 Cursor `state.vscdb`，把 `toolFormerData` 工具调用落成审计流水。
///
/// 与其余审计扫描器的两点结构差异：
/// - 数据不在 JSONL 里，没有字节 offset 可做水位 → 每个 composer 一条 `scan_files`
///   记录（key `audit://cursor:<composerId>`），`offset` 记已处理的气泡条数，
///   `inode` 记库 inode（库被换掉时自动全量重来）。
/// - 幂等键用 `cursor:<composerId>:<bubbleId>`：`toolFormerData.toolCallId` 只有
///   3999/6505 条有（老气泡没有），而 bubbleId 全局唯一且稳定。
///
/// 工具词汇是 Cursor 私有的 snake_case（`run_terminal_cmd` / `search_replace` / `mcp_<server>_<tool>`），
/// 必须喂 `AuditExtractor.cursor`——喂 Claude 或 Codex 的提取器会全落 `.other`，风险规则永不命中。
public final class CursorAuditScanner {
    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int

    /// 每 composer 的扫描私有状态（存 scan_files.extra）。
    /// `seenActiveAt` 让没动过的会话在热路径上零成本跳过——本扫描器是 2s 一轮，
    /// 少了它每轮都要把 100+ 个 composerData（单个可达 236KB）读出来解一遍 JSON。
    private struct Extra: Codable {
        var cwd: String?
        var seenActiveAt: Double?
    }

    public init(
        dbPath: URL, workspaceStorageRoot: URL, store: EurekaStore, pipeline: AuditPipeline,
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = CursorSessionIndexer.fullHistoryWindow,
        maxSessions: Int = 2000
    ) {
        self.dbPath = dbPath
        self.workspaceStorageRoot = workspaceStorageRoot
        self.store = store
        self.pipeline = pipeline
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
    }

    /// 上一轮扫描时的库指纹；相同就整轮跳过（见 scanOnce）
    private var lastFingerprint: String?

    /// 库指纹 = 主库 + WAL 的 size/mtime。
    ///
    /// **必须带 `-wal`**：Cursor 以 WAL 模式持有这个库，新写入先落在 `state.vscdb-wal` 上，
    /// 主库的 size/mtime 可以长时间不变 —— 只看主库会把正在活跃的会话判成"没变化"而漏采。
    /// 不看 `-shm`：那是共享内存索引，读操作也会碰它，拿它当判据等于没有门控。
    private static func fingerprint(_ dbPath: URL) -> String {
        let fm = FileManager.default
        return [dbPath.path, dbPath.path + "-wal"].map { path -> String in
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let size = (attrs[.size] as? NSNumber)?.int64Value,
                  let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970
            else { return "-" }
            return "\(size):\(mtime)"
        }.joined(separator: "|")
    }

    /// 扫一遍近窗会话，返回本轮新插入的审计行数。alertSink 接收高危告警。
    ///
    /// ⚡️ **库没变就立刻返回**。这一条门控是必须的：审计是 2 秒节奏，而这里每轮都要打开一个
    /// **250 MB** 的 SQLite 库、再跑一整轮 `CursorSessionIndexer.index`（内部还会逐个打开
    /// workspaceStorage 下的库）。实测这条路径是整个应用的 CPU 头号消耗
    /// （`sample` 抓到 `AuditService.scanCursor → SQLiteDB.init → openDatabase` 常驻热点，
    /// 应用长跑平均 CPU 25%）。Cursor 不活跃时现在是一次 stat 的成本。
    @discardableResult
    public func scanOnce(now: Date = Date(), alertSink: ((RiskAlert) -> Void)? = nil) throws -> Int {
        guard FileManager.default.fileExists(atPath: dbPath.path) else { return 0 }
        let fingerprint = Self.fingerprint(dbPath)
        if let lastFingerprint, lastFingerprint == fingerprint { return 0 }
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return 0 }
        let inode = Self.fileInode(path: dbPath.path)
        let sessions = CursorSessionIndexer.index(
            dbPath: dbPath, workspaceStorageRoot: workspaceStorageRoot,
            window: recentWindow, maxSessions: maxSessions, now: now)

        var inserted = 0
        for session in sessions {
            inserted += try scan(
                session: session, db: db, inode: inode, now: now, alertSink: alertSink)
        }
        // **只有整轮扫完才记指纹**（不能用 defer：抛错时也会执行，那会把没扫完的库当已完成，
        // 下一轮门控直接跳过 ⇒ 静默丢审计）
        lastFingerprint = fingerprint
        return inserted
    }

    private func scan(
        session: AgentSessionInfo, db: SQLiteDB, inode: Int64, now: Date,
        alertSink: ((RiskAlert) -> Void)?
    ) throws -> Int {
        let stateKey = "audit://cursor:\(session.id)"
        let saved = try store.scanState.fileState(path: stateKey)
        var processed = 0
        var extra = Extra(cwd: session.cwd)
        if let saved, saved.inode == inode {
            processed = Int(saved.offset)
            if let json = saved.extra,
                let decoded = try? JSONDecoder().decode(Extra.self, from: Data(json.utf8)) {
                extra.cwd = session.cwd ?? decoded.cwd
                extra.seenActiveAt = decoded.seenActiveAt
                // 上次扫过之后这个会话没再动过 → 不可能有新工具调用，直接跳过
                if let seen = decoded.seenActiveAt,
                    session.lastActiveAt.timeIntervalSince1970 <= seen {
                    return 0
                }
            }
        }
        extra.seenActiveAt = session.lastActiveAt.timeIntervalSince1970

        guard let composer = Self.json(db: db, key: "composerData:\(session.id)") else { return 0 }
        let bubbleIds = (composer["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { $0["bubbleId"] as? String }
        // 气泡只追加不重排；条数没变就没有新工具调用。
        // 注意仍要落一次 state：把 seenActiveAt 推上去，下轮才跳得掉。
        guard bubbleIds.count > processed else {
            try store.scanState.setFileState(
                path: stateKey,
                .init(inode: inode, offset: Int64(processed), extra: Self.encode(extra)))
            return 0
        }

        var inserted = 0
        var alerts: [RiskAlert] = []
        try store.scanState.transaction {
            for bubbleId in bubbleIds[processed...] {
                guard let bubble = Self.json(
                    db: db, key: "bubbleId:\(session.id):\(bubbleId)"),
                    let tool = bubble["toolFormerData"] as? [String: Any],
                    let name = tool["name"] as? String, !name.isEmpty
                else { continue }
                let timestamp = (bubble["createdAt"] as? String)
                    .flatMap { TranscriptReader.iso8601.date(from: $0) } ?? session.lastActiveAt
                let args = AuditExtractor.cursorArguments(
                    rawArgs: tool["rawArgs"], params: tool["params"])
                let op = AuditExtractor.cursor(name: name, input: args)
                let event = AuditEvent(
                    opId: "cursor:\(session.id):\(bubbleId)",
                    source: .cursor, sessionId: session.id, timestamp: timestamp,
                    kind: op.kind, tool: op.name, detail: op.detail, cwd: extra.cwd,
                    isError: (tool["status"] as? String) == "error")
                let result = try pipeline.ingest(
                    event, isStale: now.timeIntervalSince(timestamp) > staleThreshold, now: now)
                if result.inserted { inserted += 1 }
                if let alert = result.alert { alerts.append(alert) }
            }
            try store.scanState.setFileState(
                path: stateKey,
                .init(inode: inode, offset: Int64(bubbleIds.count), extra: Self.encode(extra)))
        }
        alerts.forEach { alertSink?($0) }
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

    static func fileInode(path: String) -> Int64 {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return 0 }
        return Int64(info.st_ino)
    }
}
