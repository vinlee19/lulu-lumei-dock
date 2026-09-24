import Foundation
import EurekaKit
import EurekaStore

/// Antigravity（`agy`）用量扫描（**实验**，设置里默认关闭）。
///
/// 每会话一个 `conversations/<uuid>.db`，其中 `gen_metadata(idx, data)` 每次模型调用一行，
/// data 是未公开的 protobuf。字段含义按结构核对（与 Windsurf/Codeium 的 ModelUsageStats 同构）：
/// - `1.19` 模型名（如 `gemini-3.8-flash`）
/// - `1.4` 用量：`2` 输入、`3` 输出、`4` 缓存写、`5` 缓存读、`9` 思考输出、`10` 回复输出
///   ——本地 1248 行全部满足 9 + 10 == 3；1069 行缓存读 > 输入，故输入**不含**缓存读（同 Claude 口径）
/// - `1.20` 键值对，`last_step_index` 指向 `steps.idx`；该步 `metadata.1.1` 是调用时间（Unix 秒）
///
/// 读库方式：库是 WAL 模式，只读连接在没有 `-shm` 时打不开；而 `immutable=1` 会漏读未 checkpoint 的 WAL。
/// 故每次把 `.db`（与 `-wal`，若有）复制到临时目录，打开副本（SQLite 会从 wal 重建索引）读完即删。
/// 文件指纹（大小 + mtime）没变的库直接跳过，不复制。格式对不上一律跳过该行，永不抛错到上层。
public final class AntigravityUsageScanner {
    private let conversationsRoot: URL
    private let store: EurekaStore
    /// 会话工作区（EurekaUsage 不依赖 EurekaIngest，由 app 注入 AntigravityPaths.cwd）
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

        // 库被重建（最大 idx 回退到水位以下）→ 清掉该会话已入账的行，从头重扫
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

    /// steps.metadata 的 `1.1`（Unix 秒）→ 调用时间
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

    /// 复制 .db（+ -wal）到独立临时目录；不复制 -shm（SQLite 打开时从 wal 重建）
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
