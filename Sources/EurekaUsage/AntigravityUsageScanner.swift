import Foundation
import EurekaKit
import EurekaStore

/// Antigravity (`agy`) usage scanner (**experimental**, off by default in Settings).
///
/// One `conversations/<uuid>.db` per session; its `gen_metadata(idx, data)` has one row per model call,
/// and data is an undocumented protobuf. Field meanings were checked against the structure (isomorphic to
/// Windsurf/Codeium's ModelUsageStats):
/// - `1.19` model name (e.g. `gemini-3.8-flash`)
/// - `1.4` usage: `2` input, `3` output, `4` cache write, `5` cache read, `9` thinking output, `10`
///   reply output
///   -- all 1248 local rows satisfy 9 + 10 == 3; in 1069 rows cache read > input, so input **excludes**
///   cache reads (same convention as Claude)
/// - `1.20` key/value pairs; `last_step_index` points at `steps.idx`, whose `metadata.1.1` is the
///   call time (Unix seconds)
///
/// How the DB is read: it is in WAL mode, so a read-only connection can't open it without `-shm`, while
/// `immutable=1` would miss un-checkpointed WAL content.
/// So each time `.db` (and `-wal`, if present) is copied into a temp dir, the copy is opened (SQLite rebuilds
/// the index from the wal), read, and deleted.
/// DBs whose fingerprint (size + mtime) hasn't changed are skipped without copying. Any row that doesn't
/// match the format is skipped; errors never propagate up.
public final class AntigravityUsageScanner {
    private let conversationsRoot: URL
    private let store: EurekaStore
    /// Session workspace (EurekaUsage doesn't depend on EurekaIngest; the app injects
    /// AntigravityPaths.cwd)
    private let cwdResolver: (URL) -> String?
    private let projectResolver = ProjectResolver()

    private struct Fingerprint: Codable, Equatable {
        var size: Int64
        var mtime: Double
        var walSize: Int64
        var walMtime: Double
    }

    public init(conversationsRoot: URL, store: EurekaStore, cwdResolver: @escaping (URL) -> String?) {
        self.conversationsRoot = conversationsRoot
        self.store = store
        self.cwdResolver = cwdResolver
    }

    @discardableResult
    public func scanOnce() throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: conversationsRoot, includingPropertiesForKeys: nil)) ?? []
        var inserted = 0
        for db in files where db.pathExtension == "db" {
            inserted += try autoreleasepool { try scanDatabase(db) }
        }
        return inserted
    }

    private func scanDatabase(_ dbURL: URL) throws -> Int {
        let path = dbURL.path
        guard let fingerprint = Self.fingerprint(dbURL) else { return 0 }
        let saved = try store.scanState.fileState(path: path)
        let savedFingerprint = saved?.extra.flatMap {
            try? JSONDecoder().decode(Fingerprint.self, from: Data($0.utf8))
        }
        guard savedFingerprint != fingerprint else { return 0 }
        var watermark = saved?.offset ?? -1

        guard let snapshot = Self.snapshotCopy(dbURL) else { return 0 }
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        guard let db = try? SQLiteDB(path: snapshot.path) else { return 0 }

        // DB was rebuilt (max idx fell below the watermark) → clear that session's recorded rows
        // and rescan from the start
        let maxIndex = (try? db.query("SELECT MAX(idx) FROM gen_metadata") { $0.int(0) })?.first ?? -1
        let sessionId = dbURL.deletingPathExtension().lastPathComponent
        var reset = false
        if maxIndex < watermark {
            watermark = -1
            reset = true
        }
        guard let rows = try? db.query(
            "SELECT idx, data FROM gen_metadata WHERE idx > ? ORDER BY idx", [.int(watermark)],
            map: { row -> (Int64, Data?) in
                (row.int(0), row.blob(1))
            })
        else { return 0 }

        let fileDate = Date(timeIntervalSince1970: fingerprint.mtime)
        let project = projectResolver.projectName(forCwd: cwdResolver(dbURL))
        var parsed: [(model: String, usage: Data, step: Int64?)] = []
        for (_, data) in rows {
            guard let data, let call = ProtobufReader.first(data, [1])?.data,
                  let usage = ProtobufReader.first(call, [4])?.data
            else { continue }
            let model = ProtobufReader.first(call, [19])?.string ?? "antigravity"
            let step = ProtobufReader.all(call, 20).compactMap { pair -> Int64? in
                guard let raw = pair.data,
                      ProtobufReader.first(raw, [1])?.string == "last_step_index",
                      let value = ProtobufReader.first(raw, [2])?.string
                else { return nil }
                return Int64(value)
            }.first
            parsed.append((model, usage, step))
        }
        let stepTimes = Self.stepTimes(db: db, steps: Set(parsed.compactMap(\.step)))

        var records: [UsageRecord] = []
        for item in parsed {
            func count(_ number: Int) -> Int {
                Int(ProtobufReader.first(item.usage, [number])?.uint ?? 0)
            }
            let input = count(2), output = count(3), cacheWrite = count(4), cacheRead = count(5)
            guard input > 0 || output > 0 || cacheRead > 0 || cacheWrite > 0 else { continue }
            records.append(UsageRecord(
                source: .antigravity,
                model: item.model,
                project: project,
                sessionId: sessionId,
                timestamp: item.step.flatMap { stepTimes[$0] } ?? fileDate,
                inputTokens: input,
                outputTokens: output,
                cacheCreationTokens: cacheWrite,
                cacheReadTokens: cacheRead,
                provider: "google"))
        }

        let extra = String(data: (try? JSONEncoder().encode(fingerprint)) ?? Data(), encoding: .utf8)
        let newWatermark = max(watermark, rows.map(\.0).max() ?? watermark)
        try store.scanState.transaction {
            if reset { try store.usage.deleteRecords(source: .antigravity, sessionId: sessionId) }
            try store.usage.insert(records)
            try store.scanState.setFileState(
                path: path, .init(inode: 0, offset: newWatermark, extra: extra))
        }
        return records.count
    }

    /// `1.1` of steps.metadata (Unix seconds) → call time
    private static func stepTimes(db: SQLiteDB, steps: Set<Int64>) -> [Int64: Date] {
        guard !steps.isEmpty else { return [:] }
        var result: [Int64: Date] = [:]
        let list = Array(steps)
        for chunk in stride(from: 0, to: list.count, by: 500).map({
            Array(list[$0..<min($0 + 500, list.count)])
        }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let rows = (try? db.query(
                "SELECT idx, metadata FROM steps WHERE idx IN (\(placeholders))",
                chunk.map { .int($0) }) { row -> (Int64, Data?) in (row.int(0), row.blob(1)) }
            ) ?? []
            for (index, metadata) in rows {
                guard let metadata, let seconds = ProtobufReader.first(metadata, [1, 1])?.uint,
                      seconds > 1_500_000_000, seconds < 4_000_000_000
                else { continue }
                result[index] = Date(timeIntervalSince1970: TimeInterval(seconds))
            }
        }
        return result
    }

    /// Copy .db (+ -wal) into a dedicated temp dir; -shm is not copied (SQLite rebuilds it from the
    /// wal on open)
    static func snapshotCopy(_ dbURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("eureka-agy-\(UUID().uuidString)")
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

    private static func fingerprint(_ dbURL: URL) -> Fingerprint? {
        func stat(_ path: String) -> (Int64, Double)? {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return (size, mtime)
        }
        guard let main = stat(dbURL.path) else { return nil }
        let wal = stat(dbURL.path + "-wal") ?? (0, 0)
        return Fingerprint(size: main.0, mtime: main.1, walSize: wal.0, walMtime: wal.1)
    }
}
