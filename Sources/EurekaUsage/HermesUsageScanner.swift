import Foundation
import EurekaKit
import EurekaStore

/// 扫描 Hermes Agent 的 `state.db`（schema v23，WAL，只读打开）→ usage_records。
///
/// Hermes 没有 JSONL transcript：token / 成本全落在 `session_model_usage`
/// （PK = session_id + model + billing_provider + billing_base_url + billing_mode + task，
/// `task=''` 是主循环，其余是 title_generation 等辅助模型），且**行是原地累加的**
/// —— 会话越长值越大 → 不能像 JSONL 那样"读到即记"，否则每轮都把累计值再加一遍。
///
/// token 口径（对 live DB 算术核验过，与 Codex 不同）：
///   - `input_tokens` **已扣掉缓存**，总量 = input + cache_read + cache_write + output；
///   - `reasoning_tokens` 是 `output_tokens` 的子集，**不再另加**，否则 output 双计。
///
/// 增量机制：`last_seen` 当水位（存 scan_files.offset，键 `<db>#hermes-usage`）筛出变动行，
/// 再用"每会话快照"（键 `<db>#hu:<会话 id>`，extra 存该会话各行已计入的累计值）算 delta，
/// 只写增量。之所以不用 dedup_keys：它只有一个 output_tokens 列，装不下四段 token 的基线，
/// 而 usage_records 也没有整行覆盖的更新接口。快照按会话分行存（不是整库一坨 JSON），
/// 写入量只与"本轮变动的会话数"成正比。
public final class HermesUsageScanner {
    private let stateDBs: () -> [URL]
    private let store: EurekaStore
    private let projectResolver = ProjectResolver()
    /// 分批查询的会话数上限（IN 占位符规模，与 Store 各仓一致量级）
    private static let chunkSize = 300
    /// `ended_at IS NULL`（在跑 / 崩溃未收尾）的会话回看窗：它们的 sessions 行没有
    /// last_seen 语义，靠这个窗把僵尸会话挡在候选集外；首轮（水位 0）则全量回扫。
    private static let runningLookback: TimeInterval = 2 * 86400

    /// stateDBs 由调用方传入（app/CLI 用 `HermesPaths.allStateDBs()` 覆盖全部 profile，
    /// 测试用临时库）—— EurekaUsage 不依赖 EurekaIngest，故此处不设默认值。
    /// 传**闭包**而非数组：`allStateDBs()` 按 `fileExists` 过滤，运行期才装 Hermes
    /// （或新建 profile）的用户否则要重启 app 才有用量。与 HermesStateTailer 同一口径。
    public init(stateDBs: @escaping () -> [URL], store: EurekaStore) {
        self.stateDBs = stateDBs
        self.store = store
    }

    public convenience init(stateDBs: [URL], store: EurekaStore) {
        self.init(stateDBs: { stateDBs }, store: store)
    }

    /// 返回本轮新增的 usage 记录数
    @discardableResult
    public func scanOnce() throws -> Int {
        var inserted = 0
        for dbPath in stateDBs() {
            inserted += try scan(dbPath: dbPath, now: Date())
        }
        return inserted
    }

    // MARK: - 单库扫描

    private func scan(dbPath: URL, now: Date) throws -> Int {
        let path = dbPath.path
        guard FileManager.default.fileExists(atPath: path),
              let db = try? SQLiteDB(path: path, readOnly: true) else { return 0 }

        let inode = fileInode(path)
        let markerKey = path + "#hermes-usage"
        let saved = try store.scanState.fileState(path: markerKey)
        // 库被重建（inode 变）→ 水位归零重扫；每会话快照仍在，delta 天然为 0，不会重复计
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
                // 快照变了也要落盘：库被重建 / 回滚时累计值会变小，基线要跟着降下来，
                // 否则要等新会话重新长过旧基线才恢复记账（无 delta 时则完全不写，零开销复查）
                guard !records.isEmpty || snapshot != baseline else { continue }
                // 每会话一个事务：快照与记录同生共死，中途失败最多让下一轮重算该会话
                try store.scanState.transaction {
                    try store.usage.insert(records)
                    try store.scanState.setFileState(
                        path: key, .init(inode: inode, offset: seen, extra: encode(snapshot)))
                }
                inserted += records.count
            }
        }
        // 水位最后推进：任何一步失败都让下一轮重扫同一批（快照保证不重复计）
        try store.scanState.setFileState(
            path: markerKey, .init(inode: inode, offset: newWatermark))
        return inserted
    }

    /// 候选会话：`session_model_usage.last_seen` 过水位的（真实变动），
    /// 并上 sessions 侧近期收尾 / 仍在跑的（网关会话可能一行 usage 都没有，见 residual 注释）
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
                // 行标识 = PK 去掉 session_id 的五元组（\u{1} 分隔，不会出现在这些字段里）
                identity: ([1, 2, 3, 4, 5] as [Int32])
                    .map { row.text($0) ?? "" }.joined(separator: "\u{1}"),
                model: row.text(1) ?? "hermes-unknown",
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
            // 时间是 epoch **秒**（不是毫秒）；未收尾的会话用 started_at 落桶
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

    /// 逐行 delta → UsageRecord，并把快照推到当前累计值
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
                model: row.model, meta: meta, sessionID: sessionID,
                timestamp: row.lastSeen > 0 ? Date(timeIntervalSince1970: row.lastSeen) : now,
                tokens: delta))
        }
        // 网关会话（absolute=True 的累计写路径）只更新 sessions 行、不落 session_model_usage，
        // 故 SUM(主循环行) <= sessions 聚合。选择"补记残差"而不是丢弃：否则这部分 token
        // 在账本里整段消失。比较只取 task='' 的主循环行（sessions 聚合不含辅助模型：
        // live DB 上 sessions.input == 主循环行 input，title_generation 那 117 token 不在其中）。
        if let meta {
            let mainLoop = rows.filter { $0.task.isEmpty }
                .reduce(Counted()) { $0.adding($1.tokens) }
            let residual = meta.tokens.subtracting(mainLoop)
            // 真实行标识必带 4 个 \u{1} 分隔符，故这个键不会和它们撞
            let key = "#residual"
            let delta = residual.subtracting(snapshot[key] ?? Counted())
            snapshot[key] = residual
            if !delta.isEmpty {
                records.append(record(
                    model: meta.model, meta: meta, sessionID: sessionID,
                    timestamp: meta.timestamp, tokens: delta))
            }
        }
        return records
    }

    /// model 原样入库（自由文本、多 provider，如 `gpt-5.6-sol`；价目表按前缀匹配，不硬编码清单）
    private func record(
        model: String, meta: SessionMeta?, sessionID: String, timestamp: Date, tokens: Counted
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
            cacheReadTokens: tokens.cacheRead)
    }

    // MARK: - 官方成本

    /// Hermes 自报成本。usage_records 没有 cost 列（全项目统一由 PricingTable 估算），
    /// 而 Hermes 多走第三方网关 / 订阅路由、model 名在价目表里根本匹配不到 →
    /// 官方成本单独读出来，由展示层覆盖估算值。
    public struct OfficialCost: Equatable, Sendable {
        public var sessionId: String
        public var model: String
        /// nil = Hermes 自己也不知道 → 交回价目表估算
        public var costUSD: Double?
        /// 同 Hermes `cost_status`：actual / estimated / included / unknown
        public var status: String
    }

    /// 区间内各会话的官方成本（sessions 行为准：它含网关旁路的累计写，比 usage 表全）
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

    /// 成本优先级：actual > 0 是账单事实，最高；`included`（订阅内路由，如
    /// billing_mode=subscription_included）真实增量支出**就是 0**，要记 0 而不是 nil ——
    /// 它的 estimated 只是"若按 API 计价"的参考值，拿来展示会虚增账单；
    /// 再退 estimated；全无 → nil，交给价目表。
    private static func cost(actual: Double?, estimated: Double, status: String) -> Double? {
        if let actual, actual > 0 { return actual }
        if status == "included" { return 0 }
        if estimated > 0 { return estimated }
        return nil
    }

    // MARK: - 内部类型与工具

    /// 四段 token 的累计值（既作快照基线，也作 delta 载体）。
    /// 字段名压短是因为它要 JSON 序列化进 scan_files.extra，每会话一行、越小越好。
    private struct Counted: Codable, Equatable {
        var input: Int = 0
        var output: Int = 0
        var cacheRead: Int = 0
        var cacheWrite: Int = 0

        enum CodingKeys: String, CodingKey {
            case input = "i", output = "o", cacheRead = "r", cacheWrite = "w"
        }

        var isEmpty: Bool { input == 0 && output == 0 && cacheRead == 0 && cacheWrite == 0 }

        /// 逐字段相减，负数截零：库回滚 / 重建时只重新对齐基线，绝不倒扣账本
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

    /// 该会话已计入的累计值：行标识 → 基线。extra 只由本扫描器写；
    /// 解析不出来只能当空基线（会把该会话重记一遍），故格式若要改，得随 schema 版本重建派生表。
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

    /// epoch 秒 → 整秒水位（NaN / 越界脏值截零，避免 Int64(Double) 转换陷阱）。
    /// 取下取整 + 查询侧用 `>=` 是刻意的：同一秒内又长大的行会被重扫一遍，delta 为 0，不重复计。
    private static func seconds(_ value: Double) -> Int64 {
        guard value.isFinite, value > 0, value < 4e9 else { return 0 }
        return Int64(value)
    }

    private func fileInode(_ path: String) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.systemFileNumber] as? Int).map(Int64.init) ?? 0
    }
}
