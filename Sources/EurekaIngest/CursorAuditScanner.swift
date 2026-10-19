import EurekaKit
import EurekaStore
import Foundation

/// Scans Cursor's `state.vscdb` and records `toolFormerData` tool calls as audit entries.
///
/// Two structural differences from the other audit scanners:
/// - The data is not in JSONL, so there is no byte offset to use as a watermark → one `scan_files`
///   record per composer (key `audit://cursor:<composerId>`), with `offset` holding the number of
///   bubbles processed and `inode` the DB inode (a replaced DB triggers a full rescan
///   automatically).
/// - The idempotency key is `cursor:<composerId>:<bubbleId>`: only 3999/6505 entries have
///   `toolFormerData.toolCallId` (old bubbles lack it), while bubbleId is globally unique and
///   stable.
///
/// The tool vocabulary is Cursor's private snake_case (`run_terminal_cmd` / `search_replace` /
/// `mcp_<server>_<tool>`), so it must go through `AuditExtractor.cursor` -- the Claude or Codex
/// extractor would map everything to `.other` and no risk rule would ever match.
public final class CursorAuditScanner {
    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let store: EurekaStore
    private let pipeline: AuditPipeline
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int

    /// Per-composer private scan state (stored in scan_files.extra). `seenActiveAt` lets untouched
    /// sessions be skipped at zero cost on the hot path -- this scanner runs every 2s, and without
    /// it every tick would read and JSON-decode 100+ composerData blobs (up to 236KB each).
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

    /// DB fingerprint from the previous scan; if unchanged the whole tick is skipped (see scanOnce)
    private var lastFingerprint: String?

    /// DB fingerprint = size/mtime of the main DB + WAL.
    ///
    /// **`-wal` is required**: Cursor holds this DB in WAL mode, so new writes land in
    /// `state.vscdb-wal` first, and the main DB's size/mtime can stay unchanged for a long time --
    /// looking only at the main DB would judge an active session "unchanged" and miss it. `-shm` is
    /// ignored: it is the shared-memory index that reads touch too, so using it as the signal would
    /// mean no gating at all.
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

    /// Scans recent sessions once and returns the number of audit rows inserted this tick.
    /// alertSink receives high-risk alerts.
    ///
    /// **Returns immediately if the DB has not changed.** This gate is required: auditing runs
    /// every 2 seconds, and each tick here opens a **250 MB** SQLite DB and runs a full
    /// `CursorSessionIndexer.index` (which in turn opens each DB under workspaceStorage). Measured,
    /// this path was the app's top CPU consumer (`sample` caught `AuditService.scanCursor →
    /// SQLiteDB.init → openDatabase` as a persistent hotspot, averaging 25% CPU over long runs).
    /// When Cursor is inactive it now costs a single stat.
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
        // **Record the fingerprint only after a complete scan** (no defer: it would also run on a
        // throw, marking a half-scanned DB as done, and the next tick's gate would skip it ⇒ audits
        // silently lost)
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
                // The session has not changed since the last scan → no new tool calls possible,
                // skip it
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
        // Bubbles are append-only and never reordered; an unchanged count means no new tool calls.
        // Still persist the state once: advancing seenActiveAt is what lets the next tick skip it.
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
