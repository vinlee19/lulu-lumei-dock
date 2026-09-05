import EurekaKit
import EurekaStore
import Foundation

/// 尾随 opencode.db 的 `event` 表（append-only）做实时事件。opencode 无 hook/notify 回调，
/// 这是唯一的实时通道。只读打开外部库，按 `event.rowid` 水位增量；首扫定基线到当前最大 rowid，
/// 不重放历史（与 Codex initialScan 同理）。子会话（subagent）的事件按 session.parent_id 过滤掉。
public final class OpencodeEventTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let dbPath: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.opencode-tailer")
    private var timer: DispatchSourceTimer?

    private var lastRowid: Int64 = -1  // -1 = 未初始化（首扫定基线）
    private var knownTopLevel = Set<String>()
    private var knownChild = Set<String>()
    /// 事件自身时间戳距今超过此秒数即视为积压：只入历史/用量、不触发岛动画
    /// （与 spool / Hermes tailer 同一口径；消息完成时间可能是几周前的历史）
    private let staleThreshold: TimeInterval = 300

    static let healthName = "opencode 事件监视"

    public init(dbPath: URL, handler: @escaping Handler) {
        self.dbPath = dbPath
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway 让系统合并唤醒省电；必须小于轮询间隔（1s 档用 100ms）
        let leeway: DispatchTimeInterval = pollInterval >= 2
            ? .milliseconds(500) : .milliseconds(100)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval, leeway: leeway)
        timer.setEventHandler { [weak self] in self?.scanOnce() }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    /// 公开供测试与启动同步调用
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        guard FileManager.default.fileExists(atPath: dbPath.path),
              let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }

        // 水位查询失败（IO 抖动 / 锁超时 / 表暂不可用）必须原样返回、保住水位，下轮再试。
        // 之前把失败读成 0 再当作"rowid 回退"把水位归零 —— 下一轮就把 25,571 条历史事件
        // 整表当实时事件重放（2026-09-05 实测：灵动岛排进上百张完成卡收不回去，
        // 22 个 7、8 月的旧会话被重建成运行中、一分钟后又被判"中断"写进历史）。
        guard let maxRowid = (try? db.query("SELECT COALESCE(MAX(rowid), 0) FROM event") {
            $0.int(0)
        })?.first else { return }
        if lastRowid < 0 || maxRowid < lastRowid {
            // 首扫、或表被重建变小（rowid 真回退）：都只定基线、不重放 —— 重建后的表里
            // 装的同样是历史，当实时事件重放一样会灌满岛；之后的新事件照常增量送达
            lastRowid = maxRowid
            return
        }

        let rows = (try? db.query("""
            SELECT rowid, type, data FROM event WHERE rowid > ? ORDER BY rowid ASC
            """, [.int(lastRowid)]) { row -> (Int64, String, Data?) in
            (row.int(0), row.text(1) ?? "", row.text(2).flatMap { $0.data(using: .utf8) })
        }) ?? []

        let now = Date()
        for (rowid, type, dataBytes) in rows {
            lastRowid = max(lastRowid, rowid)
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else { continue }
            for event in OpencodeEventDecoder.decode(type: type, data: data)
            where !isChildSession(event.sessionId, db: db) {
                HealthRegistry.shared.event(Self.healthName)
                // 按事件自身时间戳判积压：即便水位失守重放了历史，几周前完成的消息
                // 也只会进历史/用量，不会再排成岛卡
                handler(event, now.timeIntervalSince(event.timestamp) > staleThreshold)
            }
        }
    }

    /// 会话是否为子 agent（session.parent_id 非空）。每个 session id 只查一次表，缓存。
    private func isChildSession(_ sessionID: String, db: SQLiteDB) -> Bool {
        if knownChild.contains(sessionID) { return true }
        if knownTopLevel.contains(sessionID) { return false }
        let parents = (try? db.query(
            "SELECT parent_id FROM session WHERE id = ?", [.text(sessionID)]) { $0.text(0) }) ?? []
        let parent = parents.first ?? nil
        let child = (parent?.isEmpty == false)
        if child { knownChild.insert(sessionID) } else { knownTopLevel.insert(sessionID) }
        return child
    }
}
