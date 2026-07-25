import EurekaKit
import EurekaStore
import Foundation

/// 轮询 Hermes `state.db` 的 `sessions` 表产出实时事件（灵动岛生命周期）。
///
/// 为什么是轮询而不是装 hook：Hermes 的 shell hook 同步跑在 agent 主循环线程上，
/// 且每条命令都要用户交互授权——装它等于给每一步 agent 循环加延迟并打断使用，
/// 所以改成外部只读轮询（与 opencode / antigravity 同一取舍：没有回调时这是唯一实时通道）。
///
/// 进度水位 = `message_count + tool_call_count + api_call_count` + 四类 token 之和，
/// **不含 `reasoning_tokens`**（它是 `output_tokens` 的子集，加进来等于重复计数）。
/// 水位只用来判"有没有推进"，不做用量口径，用量另有 scanner 负责。
///
/// ⚠️ Hermes **无法上报"等待权限确认"**：`sessions` 表只有计数与收尾字段，
/// 没有 pending-approval 状态，授权提示完全活在 TUI 进程内部。因此本 tailer
/// 永远不会发 `.waiting(reason: .permission)`——别再来表里找这个信号。
public final class HermesStateTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    /// 会话在本 tailer 眼里的阶段（决定同一行下次该发什么事件）
    private enum Phase {
        case live      // 已发过开始/心跳，尚未收尾
        case ended     // 已按 `ended_at` 发过收尾
        case reaped    // 静默超阈值、按空闲收尾过（`ended_at` 仍为空）
    }

    private struct SessionState {
        var sessionId: String
        var cwd: String?
        var progress: Int64
        var phase: Phase
        var lastProgressAt: Date
    }

    private struct Row {
        var sessionId: String
        var progress: Int64
        var startedAt: Date
        var endedAt: Date?
        var endReason: String?
        var title: String?
        var cwd: String?
    }

    private let stateDBs: () -> [URL]
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.hermes-tailer")
    private var timer: DispatchSourceTimer?

    /// key = "<dbPath>|<sessionId>"：多 profile 各有独立 state.db，
    /// 同名 session id 理论上可撞车，带库路径入 key 才不会串台。
    private var states: [String: SessionState] = [:]
    /// 已建过水位的库路径（首扫只记水位、不重放历史）
    private var baselined = Set<String>()

    static let healthName = "Hermes 会话监视"

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stateDBs: (() -> [URL])? = nil,
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 86400,
        maxSessions: Int = 200,
        handler: @escaping Handler
    ) {
        self.stateDBs = stateDBs ?? { HermesPaths.allStateDBs(environment: environment) }
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
        self.handler = handler
    }

    /// 5s 一轮：Hermes 一个 turn 动辄数十秒，再密只是白开只读连接
    public func start(pollInterval: TimeInterval = 5) {
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

    /// 公开供测试与启动时同步调用
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        for dbPath in stateDBs() {
            poll(dbPath: dbPath, now: now)
        }
        reapIdle(now: now)
    }

    private func poll(dbPath: URL, now: Date) {
        // 只读打开（WAL 感知，绝不用 immutable=1，否则读不到未 checkpoint 的新写入）
        guard let db = try? SQLiteDB(path: dbPath.path, readOnly: true) else { return }
        let rows = fetch(db: db, now: now)
        let isBaseline = !baselined.contains(dbPath.path)
        baselined.insert(dbPath.path)

        var seen = Set<String>()
        for row in rows {
            let key = "\(dbPath.path)|\(row.sessionId)"
            seen.insert(key)
            if isBaseline {
                // 首扫：只记水位。否则每次 app 启动都会把历史会话重放成一堆卡片。
                remember(row, key: key, phase: row.endedAt == nil ? .reaped : .ended, at: now)
                continue
            }
            inspect(row, key: key, now: now)
        }
        prune(dbPath: dbPath, seen: seen)
    }

    private func inspect(_ row: Row, key: String, now: Date) {
        let previous = states[key]

        if let endedAt = row.endedAt {
            let closed = previous?.phase == .ended || previous?.phase == .reaped
            remember(row, key: key, phase: .ended, at: now)
            // 已按 ended_at 或已按空闲收过尾的会话不再重复出卡（否则历史会写两条）
            guard !closed else { return }
            emit(
                .taskFinished(
                    outcome: Self.outcome(endReason: row.endReason),
                    title: Self.label(row),
                    detail: row.endReason?.isEmpty == false ? row.endReason : nil),
                row: row, at: endedAt, now: now)
            return
        }

        // ended_at 为空 = 仍在跑（或进程被 kill 后永远留空，靠 staleThreshold 兜底）
        guard let previous else {
            // 水位建立后才出现的新行：只有真·刚开始的会话才当活跃，
            // 老行（例如新 profile 库、被 prune 过的行）静默补水位，不出假卡。
            let fresh = now.timeIntervalSince(row.startedAt) <= staleThreshold
            remember(row, key: key, phase: fresh ? .live : .reaped, at: now)
            if fresh {
                emit(.taskStarted(title: Self.label(row)), row: row, at: now, now: now)
            }
            return
        }

        guard row.progress > previous.progress else { return }  // 无推进：交给 reapIdle 判空闲
        remember(row, key: key, phase: .live, at: now)
        // 表里没有"当前工具名"，心跳只能是 tool: nil
        let kind: TaskEvent.Kind = previous.phase == .live
            ? .activity(tool: nil)
            : .taskStarted(title: Self.label(row))
        emit(kind, row: row, at: now, now: now)
    }

    /// 静默超过 staleThreshold 的活跃会话按空闲收尾：Hermes 只在干净退出时写 ended_at，
    /// 被 Ctrl-C / kill 的会话会永远留空，不收尾岛上就挂着一张永不消失的运行卡。
    private func reapIdle(now: Date) {
        for (key, var state) in states
        where state.phase == .live && now.timeIntervalSince(state.lastProgressAt) > staleThreshold {
            state.phase = .reaped
            states[key] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(
                TaskEvent(
                    source: .hermes, sessionId: state.sessionId,
                    kind: .taskFinished(outcome: .success, title: nil, detail: nil),
                    timestamp: now, cwd: state.cwd),
                false)
        }
    }

    private func remember(_ row: Row, key: String, phase: Phase, at now: Date) {
        states[key] = SessionState(
            sessionId: row.sessionId, cwd: row.cwd, progress: row.progress,
            phase: phase, lastProgressAt: now)
    }

    /// 掉出时间窗的行清掉，避免 states 无限膨胀；活跃行保留（等 reapIdle 收尾后再清）
    private func prune(dbPath: URL, seen: Set<String>) {
        let prefix = "\(dbPath.path)|"
        for (key, state) in states
        where key.hasPrefix(prefix) && state.phase != .live && !seen.contains(key) {
            states.removeValue(forKey: key)
        }
    }

    private func fetch(db: SQLiteDB, now: Date) -> [Row] {
        let cutoff = now.timeIntervalSince1970 - recentWindow
        // 只看顶层会话：子会话（delegate_task 派生）不该单独占岛上的位置
        let rows = (try? db.query("""
            SELECT id,
                   COALESCE(message_count, 0) + COALESCE(tool_call_count, 0)
                     + COALESCE(api_call_count, 0)
                     + COALESCE(input_tokens, 0) + COALESCE(output_tokens, 0)
                     + COALESCE(cache_read_tokens, 0) + COALESCE(cache_write_tokens, 0),
                   started_at, ended_at, end_reason, title, cwd
            FROM sessions
            WHERE (parent_session_id IS NULL OR parent_session_id = '')
              AND COALESCE(archived, 0) = 0
              AND started_at >= ?
            ORDER BY started_at DESC
            LIMIT ?
            """, [.real(cutoff), .int(Int64(maxSessions))]) { row in
            Row(
                sessionId: row.text(0) ?? "",
                progress: row.int(1),
                startedAt: Date(timeIntervalSince1970: row.real(2)),
                endedAt: row.date(3),
                endReason: row.text(4),
                title: row.text(5),
                cwd: row.text(6).flatMap { $0.isEmpty ? nil : $0 })
        }) ?? []
        return rows.filter { !$0.sessionId.isEmpty }
    }

    private func emit(_ kind: TaskEvent.Kind, row: Row, at timestamp: Date, now: Date) {
        HealthRegistry.shared.event(Self.healthName)
        let isStale = now.timeIntervalSince(timestamp) > staleThreshold
        handler(
            TaskEvent(
                source: .hermes, sessionId: row.sessionId, kind: kind,
                timestamp: timestamp, cwd: row.cwd, sessionStartedAt: row.startedAt),
            isStale)
    }

    /// 卡片标题：优先 `title`（Hermes 自己生成的会话名），退化为 id 尾部 6 位短码
    private static func label(_ row: Row) -> String? {
        if let title = row.title, let summary = summarizeTitle(title) { return summary }
        let short = row.sessionId.split(separator: "_").last.map(String.init) ?? row.sessionId
        return short.isEmpty ? nil : "#\(short)"
    }

    /// `end_reason` → 结束方式。取值随 Hermes 版本变化，故按关键字宽松归类，
    /// 认不出的一律算正常完成（宁可少报错，也不给用户假红点）。
    private static func outcome(endReason: String?) -> TaskOutcome {
        let reason = (endReason ?? "").lowercased()
        func mentions(_ tokens: [String]) -> Bool { tokens.contains { reason.contains($0) } }
        if mentions(["error", "fail", "crash", "exception", "fatal"]) { return .error }
        if mentions(["interrupt", "cancel", "abort", "kill", "signal", "timeout"]) {
            return .interrupted
        }
        return .success
    }
}
