import Foundation
import EurekaKit
import EurekaStore

/// Scans Hermes Agent's `state.db` (schema v23, WAL, opened read-only) → usage_records.
///
/// Hermes has no JSONL transcript: all tokens / cost live in `session_model_usage`
/// (PK = session_id + model + billing_provider + billing_base_url + billing_mode + task;
/// `task=''` is the main loop, the rest are auxiliary models such as title_generation), and
/// **rows accumulate in place** — they grow as the session goes on → unlike JSONL we cannot
/// "record on read", or every turn would add the running total again.
///
/// Token semantics (arithmetically verified against a live DB; differs from Codex):
///   - `input_tokens` **already excludes cache**; total = input + cache_read + cache_write +
///     output;
///   - `reasoning_tokens` is a subset of `output_tokens` and is **not added again**, or output
///     would be double-counted.
///
/// Incremental mechanism: `last_seen` serves as the watermark (stored in scan_files.offset, key
/// `<db>#hermes-usage`) to pick out changed rows, then a "per-session snapshot" (key
/// `<db>#hu:<session id>`, extra holds the totals already counted for each of that session's rows)
/// yields the delta, and only the increment is written. dedup_keys is not used: it has a single
/// output_tokens column and cannot hold a four-part token baseline, and usage_records has no
/// whole-row overwrite API. Snapshots are stored one row per session (not one JSON blob for the
/// whole DB), so write volume scales only with "sessions changed this round".
public final class HermesUsageScanner {
    private let stateDBs: () -> [URL]
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    /// Max sessions per batched query (IN placeholder count, same order of magnitude as the Store
    /// repos)
    private static let chunkSize = 300
    /// Lookback window for `ended_at IS NULL` sessions (running / crashed without closing): their
    /// sessions rows have no last_seen semantics, so this window keeps zombie sessions out of the
    /// candidate set; the first round (watermark 0) rescans everything.
    private static let runningLookback: TimeInterval = 2 * 86400

    /// stateDBs is supplied by the caller (app/CLI pass `HermesPaths.allStateDBs()` to cover every
    /// profile, tests pass a temp DB) — EurekaUsage does not depend on EurekaIngest, so there is no
    /// default here. Pass a **closure**, not an array: `allStateDBs()` filters by `fileExists`, so
    /// users who install Hermes (or create a new profile) at runtime would otherwise have to
    /// restart the app to see usage. Same approach as HermesStateTailer.
    public init(stateDBs: @escaping () -> [URL], store: EurekaStore) {
        self.stateDBs = stateDBs
        self.store = store
    }

    public convenience init(stateDBs: [URL], store: EurekaStore) {
        self.init(stateDBs: { stateDBs }, store: store)
    }

    /// Returns the number of usage records added this round
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for dbPath in stateDBs() {
            inserted += try scan(dbPath: dbPath, now: Date())
            try recordPromptCounts(dbPath: dbPath)
        }
        return inserted
    }

    /// Per-session user prompt count (`messages.role = 'user'`). As with opencode: a shared DB has
    /// no per-session file, so take the absolute value and overwrite with `reset: true`, not tied
    /// to the usage snapshot watermark. Note `sessions.message_count` cannot be used — it counts
    /// all roles (including assistant/tool).
    private func recordPromptCounts(dbPath: URL) throws {
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let rows = (try? db.query("""
            SELECT session_id, COUNT(*) FROM messages WHERE role = 'user' GROUP BY session_id
            """) { row -> (String, Int) in (row.text(0) ?? "", Int(row.int(1))) }) ?? []
        guard !rows.isEmpty else { return }
        try store.scanState.transaction {
            for (sessionId, count) in rows where !sessionId.isEmpty {
                try store.sessionStats.recordPrompts(
                    path: "\(dbPath.path)#\(sessionId)", sessionId: sessionId,
                    count: count, reset: true)
            }
        }
    }

    // MARK: - Single-DB scan

    private func scan(dbPath: URL, now: Date) throws -> Int {
        let path = dbPath.path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLiteDB(path: path, readOnly: true) else { return 0 }

        let inode = fileInode(path)
        let markerKey = path + "#hermes-usage"
        let saved = try store.scanState.fileState(path: markerKey)
        // DB rebuilt (inode changed) → reset the watermark and rescan; per-session snapshots
        // survive, so the delta is naturally 0 and nothing is double-counted
        let watermark: Int64 = (saved?.inode == inode ? saved?.offset : nil) ?? 0
        let candidates = changedSessionIDs(db: db, watermark: Double(watermark), now: now)
        guard !candidates.isEmpty else { return 0 }

        var inserted = 0
        var newWatermark = watermark
        for chunk in stride(from: 0, to: candidates.count, by: Self.chunkSize).map({
            Array(candidates[$0..<min($0 + Self.chunkSize, candidates.count)])
        }) {
            let rowsBySession = Dictionary(grouping: usageRows(db: db, sessionIDs: chunk)) {
                $0.sessionID
            }
            let metaByID = sessionMeta(db: db, sessionIDs: chunk, now: now)
            for sessionID in chunk {
                let rows = rowsBySession[sessionID] ?? []
                let key = path + "#hu:" + sessionID
                var snapshot = snapshot(key: key)
                let baseline = snapshot
                let records = deltaRecords(
                    sessionID: sessionID, meta: metaByID[sessionID], rows: rows,
                    snapshot: &snapshot, now: now)
                let seen = Self.seconds(rows.map(\.lastSeen).max() ?? 0)
                newWatermark = max(newWatermark, seen)
                // Persist even when only the snapshot changed: a rebuilt / rolled-back DB shrinks
                // the totals and the baseline must drop with it, otherwise accounting resumes only
                // once new sessions outgrow the old baseline (with no delta nothing is written, so
                // rechecks cost nothing)
                guard !records.isEmpty || snapshot != baseline else { continue }
                // One transaction per session: snapshot and records commit or fail together; a
                // mid-way failure at most makes the next round recompute that session
                try store.scanState.transaction {
                    try store.usage.insert(records)
                    try store.scanState.setFileState(
                        path: key, .init(inode: inode, offset: seen, extra: encode(snapshot)))
                }
                inserted += records.count
            }
        }
        // Advance the watermark last: any failure makes the next round rescan the same batch
        // (snapshots prevent double counting)
        try store.scanState.setFileState(
            path: markerKey, .init(inode: inode, offset: newWatermark))
        return inserted
    }

    /// Candidate sessions: those whose `session_model_usage.last_seen` passed the watermark (real
    /// changes), plus sessions recently closed / still running on the sessions side (gateway
    /// sessions may have no usage row at all; see the residual comment)
    private func changedSessionIDs(db: SQLiteDB, watermark: Double, now: Date) -> [String] {
        let runningCutoff = watermark > 0
            ? max(0, watermark - Self.runningLookback)
            : 0
        let rows = (try? db.query("""
            SELECT DISTINCT session_id FROM session_model_usage WHERE last_seen >= ?
            UNION
            SELECT id FROM sessions
             WHERE (ended_at IS NOT NULL AND ended_at >= ?)
                OR (ended_at IS NULL AND started_at >= ?)
            """, [.real(watermark), .real(watermark), .real(runningCutoff)]) {
            $0.text(0)
        }) ?? []
        return rows.compactMap { $0 }.filter { !$0.isEmpty }
    }

    private func usageRows(db: SQLiteDB, sessionIDs: [String]) -> [UsageRow] {
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        return (try? db.query("""
            SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
            FROM session_model_usage WHERE session_id IN (\(placeholders))
            """, sessionIDs.map { .text($0) }) { row in
            UsageRow(
                sessionID: row.text(0) ?? "",
                // Row identity = PK minus session_id, a 5-tuple (\u{1}-separated; never appears in
                // these fields)
                identity: ([1, 2, 3, 4, 5] as [Int32])
                    .map { row.text($0) ?? "" }.joined(separator: "\u{1}"),
                model: row.text(1) ?? "hermes-unknown",
                provider: row.text(2).flatMap { $0.isEmpty || $0 == "auto" ? nil : $0 },
                task: row.text(5) ?? "",
                tokens: Counted(
                    input: Int(row.int(6)), output: Int(row.int(7)),
                    cacheRead: Int(row.int(8)), cacheWrite: Int(row.int(9))),
                lastSeen: row.real(10))
        }) ?? []
    }

    private func sessionMeta(
        db: SQLiteDB, sessionIDs: [String], now: Date
    ) -> [String: SessionMeta] {
        let placeholders = Array(repeating: "?", count: sessionIDs.count).joined(separator: ",")
        let rows = (try? db.query("""
            SELECT id, model, cwd, started_at, ended_at, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens
            FROM sessions WHERE id IN (\(placeholders))
            """, sessionIDs.map { .text($0) }) { row -> SessionMeta in
            // Times are epoch **seconds** (not milliseconds); unfinished sessions are bucketed by
            // started_at
            let started = row.real(3)
            return SessionMeta(
                id: row.text(0) ?? "",
                model: row.text(1) ?? "hermes-unknown",
                project: self.projectResolver.projectName(forCwd: row.text(2)),
                timestamp: row.date(4)
                    ?? (started > 0 ? Date(timeIntervalSince1970: started) : now),
                tokens: Counted(
                    input: Int(row.int(5)), output: Int(row.int(6)),
                    cacheRead: Int(row.int(7)), cacheWrite: Int(row.int(8))))
        }) ?? []
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Per-row delta → UsageRecord, advancing the snapshot to the current totals
    private func deltaRecords(
        sessionID: String, meta: SessionMeta?, rows: [UsageRow],
        snapshot: inout [String: Counted], now: Date
    ) -> [UsageRecord] {
        var records: [UsageRecord] = []
        for row in rows {
            let delta = row.tokens.subtracting(snapshot[row.identity] ?? Counted())
            snapshot[row.identity] = row.tokens
            guard !delta.isEmpty else { continue }
            records.append(record(
                model: row.model, provider: row.provider, meta: meta, sessionID: sessionID,
                timestamp: row.lastSeen > 0 ? Date(timeIntervalSince1970: row.lastSeen) : now,
                tokens: delta))
        }
        // Gateway sessions (the absolute=True cumulative write path) update only the sessions row
        // and write nothing to session_model_usage, so SUM(main-loop rows) <= the sessions
        // aggregate. Record the residual instead of dropping it: otherwise those tokens vanish from
        // the ledger entirely. Compare only task='' main-loop rows (the sessions aggregate excludes
        // auxiliary models: on the live DB sessions.input == main-loop row input;
        // title_generation's 117 tokens are not in it).
        if let meta {
            let mainLoop = rows.filter { $0.task.isEmpty }
                .reduce(Counted()) { $0.adding($1.tokens) }
            let residual = meta.tokens.subtracting(mainLoop)
            // Real row identities always carry 4 \u{1} separators, so this key cannot collide with
            // them
            let key = "#residual"
            let delta = residual.subtracting(snapshot[key] ?? Counted())
            snapshot[key] = residual
            if !delta.isEmpty {
                records.append(record(
                    model: meta.model, provider: nil, meta: meta, sessionID: sessionID,
                    timestamp: meta.timestamp, tokens: delta))
            }
        }
        return records
    }

    /// model is stored verbatim (free text, many providers, e.g. `gpt-5.6-sol`; the price table
    /// matches by prefix, no hardcoded list)
    private func record(
        model: String, provider: String?, meta: SessionMeta?, sessionID: String,
        timestamp: Date, tokens: Counted
    ) -> UsageRecord {
        UsageRecord(
            source: .hermes,
            model: model,
            project: meta?.project,
            sessionId: sessionID,
            timestamp: timestamp,
            inputTokens: tokens.input,
            outputTokens: tokens.output,
            cacheCreationTokens: tokens.cacheWrite,
            cacheReadTokens: tokens.cacheRead,
            provider: provider)
    }

    // MARK: - Official cost

    /// Hermes' self-reported cost. usage_records has no cost column (the whole project estimates
    /// via PricingTable), but Hermes often goes through third-party gateways / subscription routes
    /// whose model names never match the price table → read the official cost separately and let
    /// the presentation layer override the estimate.
    public struct OfficialCost: Equatable, Sendable {
        public var sessionId: String
        public var model: String
        /// nil = Hermes doesn't know either → fall back to the price-table estimate
        public var costUSD: Double?
        /// Same as Hermes `cost_status`: actual / estimated / included / unknown
        public var status: String
    }

    /// Official cost per session in the range (the sessions row is authoritative: it includes the
    /// gateway bypass's cumulative writes, so it is more complete than the usage table)
    public func officialCosts(from: Date, to: Date) -> [OfficialCost] {
        var result: [OfficialCost] = []
        for dbPath in stateDBs() {
            guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { continue }
            result += (try? db.query("""
                SELECT id, model, estimated_cost_usd, actual_cost_usd, cost_status
                FROM sessions
                WHERE COALESCE(ended_at, started_at) >= ? AND started_at < ?
                """, [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { row in
                let status = row.text(4) ?? ""
                return OfficialCost(
                    sessionId: row.text(0) ?? "",
                    model: row.text(1) ?? "hermes-unknown",
                    costUSD: Self.cost(
                        actual: row.isNull(3) ? nil : row.real(3),
                        estimated: row.isNull(2) ? 0 : row.real(2),
                        status: status),
                    status: status)
            }) ?? []
        }
        return result.filter { !$0.sessionId.isEmpty }
    }

    /// Cost priority: actual > 0 is billing fact and ranks highest; `included` (in-subscription
    /// routing, e.g. billing_mode=subscription_included) has a real incremental spend of **exactly
    /// 0**, so record 0, not nil — its estimated value is only a "what if billed at API rates"
    /// reference and would inflate the bill; next fall back to estimated; nothing at all → nil,
    /// left to the price table.
    private static func cost(actual: Double?, estimated: Double, status: String) -> Double? {
        if let actual, actual > 0 { return actual }
        if status == "included" { return 0 }
        if estimated > 0 { return estimated }
        return nil
    }

    // MARK: - Internal types and helpers

    /// Running totals for the four token parts (both the snapshot baseline and the delta carrier).
    /// Field names are short because it is JSON-serialized into scan_files.extra, one row per
    /// session, so smaller is better.
    private struct Counted: Codable, Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0

        enum CodingKeys: String, CodingKey {
            case input = "i", output = "o", cacheRead = "r", cacheWrite = "w"
        }

        var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

        /// Field-wise subtraction clamped at zero: on DB rollback / rebuild only realign the
        /// baseline, never deduct from the ledger
        func subtracting(_ other: Counted) -> Counted {
            Counted(
                input: max(0, input - other.input), output: max(0, output - other.output),
                cacheRead: max(0, cacheRead - other.cacheRead),
                cacheWrite: max(0, cacheWrite - other.cacheWrite))
        }

        func adding(_ other: Counted) -> Counted {
            Counted(
                input: input + other.input, output: output + other.output,
                cacheRead: cacheRead + other.cacheRead, cacheWrite: cacheWrite + other.cacheWrite)
        }
    }

    private struct UsageRow {
        var sessionID: String
        var identity: String
        var model: String
        /// billing_provider (`auto` / empty = unknown)
        var provider: String?
        var task: String
        var tokens: Counted
        var lastSeen: Double
    }

    private struct SessionMeta {
        var id: String
        var model: String
        var project: String?
        var timestamp: Date
        var tokens: Counted
    }

    /// Totals already counted for this session: row identity → baseline. extra is written only by
    /// this scanner; if it fails to parse it can only be treated as an empty baseline (recounting
    /// that session), so changing the format requires rebuilding derived tables with a schema
    /// version bump.
    private func snapshot(key: String) -> [String: Counted] {
        guard let extra = (try? store.scanState.fileState(path: key))?.extra,
              let decoded = try? JSONDecoder().decode(
                [String: Counted].self, from: Data(extra.utf8))
        else { return [:] }
        return decoded
    }

    private func encode(_ snapshot: [String: Counted]) -> String? {
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Epoch seconds → whole-second watermark (NaN / out-of-range junk clamps to zero, avoiding the
    /// Int64(Double) conversion trap). Flooring plus `>=` on the query side is deliberate: rows
    /// that grew again within the same second get rescanned with delta 0, never double-counted.
    private static func seconds(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0, value < 4e9 else { return 0 }
        return Int64(value)
    }

    private func fileInode(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.systemFileNumber] as? Int).map(Int64.init) ?? 0
    }
}
