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

    static let healthName = "opencode 事件监视"

    public init(dbPath: URL, handler: @escaping Handler) {
        self.dbPath = dbPath
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
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

        let maxRowid = (try? db.query("SELECT COALESCE(MAX(rowid), 0) FROM event") {
            $0.int(0)
        })?.first ?? 0
        if lastRowid < 0 { lastRowid = maxRowid; return }  // 首扫定基线，不重放
        if maxRowid < lastRowid { lastRowid = 0 }          // db 重建，rowid 回退

        let rows = (try? db.query("""
            SELECT rowid, type, data FROM event WHERE rowid > ? ORDER BY rowid ASC
            """, [.int(lastRowid)]) { row -> (Int64, String, Data?) in
            (row.int(0), row.text(1) ?? "", row.text(2).flatMap { $0.data(using: .utf8) })
        }) ?? []

        for (rowid, type, dataBytes) in rows {
            lastRowid = max(lastRowid, rowid)
            guard let dataBytes,
                  let object = try? JSONSerialization.jsonObject(with: dataBytes),
                  let data = object as? [String: Any] else { continue }
            for event in OpencodeEventDecoder.decode(type: type, data: data)
            where !isChildSession(event.sessionId, db: db) {
                HealthRegistry.shared.event(Self.healthName)
                handler(event, false)
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
