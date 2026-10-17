import EurekaKit
import EurekaStore
import Foundation

/// Scans cumulative token usage of assistant bubbles in Cursor's `state.vscdb`.
///
/// **Accounting (important, read fully before changing)**: Cursor's `tokenCount` has only two
/// numbers, `{inputTokens, outputTokens}`, **with no cache read/write split**, and `inputTokens` is
/// "the entire context sent this turn" — it grows monotonically turn by turn within a session
/// (observed 50684 → 59288 → 85571 → 93562 → 111408 → 112382). Booking it directly as fresh input
/// would inflate a session's input more than tenfold. So it is aggregated by **adjacent
/// differencing** (same approach as `CodexUsageScanner` on `total_token_usage`):
///   `cacheRead = previous turn's inputTokens`, `input = max(0, this turn - previous turn)`; if
///   this turn is smaller, compaction / a new topic happened and it is treated as a reset
///   (`cacheRead = 0`).
/// The sum of a session's "fresh input" then ≈ the final context size, which matches intuition.
///
/// Model names are always written as `cursor/<model>`: Cursor bills per request on a subscription,
/// and 93% of turns only report `default` (only a few entries carry the real model name in
/// `modelInfo`). In `pricing.json` the `cursor/` prefix is marked `unknown` → **cost is always 0**;
/// only tokens are counted, no misleading amounts.
///
/// Incremental: one `scan_files` row per composer (key `cursor-usage://<composerId>`), `offset` =
/// number of bubbles already counted, `inode` = DB inode (a replaced DB restarts from scratch).
/// Bubbles are only appended, never reordered, so a count watermark is naturally idempotent; a
/// rescan returns 0.
public final class CursorUsageScanner {
    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    private let recentWindow: TimeInterval
    private let maxSessions: Int

    /// Per-composer private scan state (stored in scan_files.extra)
    private struct Extra: Codable {
        var project: String?
        var lastInput: Int?
        /// The session's lastActiveAt at the last scan: if unchanged, skip it entirely, rather than
        /// reading 100+ composerData blobs (up to 236KB each) every pass and decoding JSON for
        /// nothing
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

    /// `sessions` is injected by the caller (`EurekaUsage` does not depend on `EurekaIngest`, so it
    /// cannot reach `CursorSessionIndexer`): (composerId, cwd, lastActiveAt) triples.
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
        // Persist state even with no new bubbles: advancing seenActiveAt is what lets the next pass
        // skip it
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
            // type 1 = user bubble → the session page's conversation count
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
            // Context shrank = compaction or topic change; the cache is void and this whole turn
            // counts as fresh input
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
            // First scan (processed == 0) overwrites, later scans accumulate — same convention as
            // CodeBuddy
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
