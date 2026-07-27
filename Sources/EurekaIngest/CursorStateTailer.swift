import EurekaKit
import EurekaStore
import Foundation

/// 轮询 Cursor `state.vscdb` 产出实时事件（灵动岛生命周期）。
///
/// 为什么是轮询：Cursor 是 IDE，没有 hook / notify 回调，全部会话状态只落在
/// 一个 SQLite 库里（同 opencode / hermes / antigravity 的取舍——没有回调时这是唯一实时通道）。
/// 库由 Cursor 进程常驻持有并跑 WAL，本 tailer 一律 `SQLITE_OPEN_READONLY` 打开，
/// **绝不用 `immutable=1`**，否则读不到未 checkpoint 的新写入。
///
/// 每轮两段：
///   1. `composerHeaders`（`idx_composerHeaders_1(recency, composerId)` 覆盖索引）取近窗会话头，
///      拿到标题 / ctx% / 待授权标记，只有 `recency` 前进或仍在 live 的会话才进第 2 段；
///   2. 单点读 `composerData:<id>`，判运行/结束、取工具名与子会话。
///
/// 进度水位 = 气泡数 + `contextTokensUsed`，只用来判「有没有推进」，
/// 用量口径另有 `CursorUsageScanner` 负责。
///
/// ⚠️ 顶层会话的判定用 `value.subagentInfo == nil` 而**不是** `isSubagent` 列：
/// 实勘里子会话（Best-of-N 变体）的 `isSubagent` 列仍是 0，只有 JSON 里带 `subagentInfo`。
public final class CursorStateTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    /// 会话在本 tailer 眼里的阶段（决定同一行下次该发什么事件）
    private enum Phase {
        case live      // 已发过开始/心跳，尚未收尾
        case ended     // 已按 status 发过收尾
        case reaped    // 静默超阈值、按空闲收尾过
    }

    private struct SessionState {
        var cwd: String?
        var progress: Int64
        var recency: Date
        var phase: Phase
        var lastProgressAt: Date
        var startedAt: Date?
        var title: String?
        var lastContextPercent: Double?
        var waiting: Bool = false
        var lastSubagents: [SubagentInfo] = []
        /// 已看到收口状态、但还在等一轮确认（见 inspect 里的 aborted→completed 实勘）
        var pendingClose: String?
        /// 这一轮开始时转录文件就已存在 → 整轮的生命周期都归转录侧。
        /// **必须在开始那一刻定死**：若中途才改判，会出现「开始由库侧发、收尾由转录侧
        /// 负责，而转录侧首见文件时它已收尾所以静默」→ 卡片永远挂着。
        var ownedByTranscript = false
    }

    /// `composerHeaders` 一行（value 里的 JSON 已摊平）
    struct Header {
        var composerId: String
        var workspaceId: String?
        var createdAt: Date?
        var recency: Date
        var title: String?
        var contextPercent: Double?
        var blocking: Bool
        var subagentIds: [String]
    }

    /// `composerData:<id>` 摘要
    struct Detail {
        var progress: Int64
        var generating: Bool
        var status: String
        var contextPercent: Double?
        var lastTool: String?
        var bubbleIds: [String]
        var subagentIds: [String]
    }

    private let dbPath: URL
    private let workspaceStorageRoot: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let maxSessions: Int
    private let handler: Handler
    /// 有转录文件的会话 → 生命周期事件让给 `CursorTranscriptTailer`（它有显式 turn_ended）。
    /// ctx% / 子会话 / 等待授权只有库里有，那几样照发。
    private let transcriptOwned: (Date) -> Set<String>
    private let queue = DispatchQueue(label: "com.vinlee.eureka.cursor-tailer")
    private var timer: DispatchSourceTimer?

    private var states: [String: SessionState] = [:]
    /// 已建过水位（首扫只记水位、不重放历史）
    private var baselined = false

    static let healthName = "Cursor 会话监视"

    public init(
        dbPath: URL = CursorPaths.globalStateDB(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 86400,
        maxSessions: Int = 200,
        transcriptOwned: ((Date) -> Set<String>)? = nil,
        handler: @escaping Handler
    ) {
        self.dbPath = dbPath
        self.workspaceStorageRoot = workspaceStorageRoot
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.maxSessions = maxSessions
        self.transcriptOwned = transcriptOwned ?? { now in
            CursorTranscriptIndex.ownedComposerIds(
                cliHome: CursorPaths.cliHome(),
                workspaceStorageRoot: workspaceStorageRoot, now: now)
        }
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
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

    /// 公开供测试与启动时同步调用
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        poll(now: now)
        reapIdle(now: now)
    }

    private func poll(now: Date) {
        guard FileManager.default.fileExists(atPath: dbPath.path),
            let db = try? SQLiteDB(path: dbPath.path, readOnly: true)
        else { return }
        let folders = CursorWorkspaceIndex.folders(root: workspaceStorageRoot, now: now)
        let owned = transcriptOwned(now)
        let headers = fetchHeaders(db: db, now: now)
        let isBaseline = !baselined
        baselined = true

        var seen = Set<String>()
        for header in headers {
            seen.insert(header.composerId)
            let cwd = header.workspaceId.flatMap { folders[$0] }
            if isBaseline {
                // 首扫只记水位：否则每次 app 启动都会把历史会话重放成一堆卡片
                guard let detail = fetchDetail(db: db, composerId: header.composerId) else {
                    continue
                }
                states[header.composerId] = SessionState(
                    cwd: cwd, progress: detail.progress, recency: header.recency,
                    phase: Self.isClosed(detail.status) ? .ended : .reaped, lastProgressAt: now,
                    startedAt: header.createdAt, title: header.title,
                    lastContextPercent: header.contextPercent)
                continue
            }
            inspect(
                header, cwd: cwd, db: db, now: now,
                owned: owned.contains(header.composerId))
        }
        prune(seen: seen)
    }

    private func inspect(
        _ header: Header, cwd: String?, db: SQLiteDB, now: Date, owned: Bool
    ) {
        let previous = states[header.composerId]
        // 没推进又不在跑的会话，跳过 composerData 的读取（最大的一笔开销）。
        // 待落定的收口要放行：它正是靠「下一轮水位不再动」才敢认最终状态。
        if let previous, previous.phase != .live, previous.pendingClose == nil,
            previous.recency >= header.recency { return }
        guard let detail = fetchDetail(db: db, composerId: header.composerId) else { return }

        var state = previous ?? SessionState(
            cwd: cwd, progress: detail.progress, recency: header.recency,
            phase: .reaped, lastProgressAt: now, startedAt: header.createdAt,
            title: header.title, lastContextPercent: nil)
        state.cwd = cwd ?? state.cwd
        state.recency = header.recency
        state.startedAt = header.createdAt ?? state.startedAt
        if let title = header.title { state.title = title }

        let advanced = previous == nil || detail.progress > previous!.progress
        state.progress = detail.progress  // 水位必须回写，否则 advanced 永远为真
        let fresh = now.timeIntervalSince(header.recency) <= staleThreshold
        // `generatingBubbleIds` 实勘全程为空（Cursor 不落生成中状态），所以它只是
        // 一层保险，真正判活的是「水位在推进且状态还没收口」。
        let running = detail.generating || (advanced && !Self.isClosed(detail.status))

        // 等待授权要在「水位不推进」时也判：卡在授权弹窗上恰恰是什么都不动的时候，
        // 塞进 running 分支就永远等不到。
        if state.phase == .live { emitWaiting(header, state: &state, now: now) }

        if running {
            state.pendingClose = nil
            if state.phase != .live {
                // 水位建立后才冒出来的老会话不出假卡：只有真·刚动过的才当活跃
                state.phase = fresh ? .live : .reaped
                state.lastProgressAt = now
                state.ownedByTranscript = owned
                states[header.composerId] = state
                if fresh && !owned {
                    emit(.taskStarted(title: state.title), composerId: header.composerId,
                        state: state, at: now, now: now)
                }
            } else {
                state.lastProgressAt = now
                states[header.composerId] = state
                if !state.ownedByTranscript {
                    emit(.activity(tool: detail.lastTool), composerId: header.composerId,
                        state: state, at: now, now: now)
                }
            }
            // 本轮才转 live 的会话上面那次还没轮到，这里补一次；
            // `emitWaiting` 只在翻转时发，重复调用是空操作。
            emitWaiting(header, state: &state, now: now)
            emitContext(header, detail: detail, state: &state, now: now)
            emitSubagents(header, detail: detail, db: db, state: &state, now: now)
            states[header.composerId] = state
            return
        }

        guard Self.isClosed(detail.status) else {
            // 状态没收口又没推进（例如刚被打开的老会话）：只更新水位。
            // 之前挂着的待落定收口作废——状态已经不是收口的了。
            state.pendingClose = nil
            states[header.composerId] = state
            return
        }

        // 收口状态**要等一轮再落定**：实勘同一轮里 status 先写 `aborted` 再写
        // `completed`（f704e4ec，2s 内两次），当场收尾会把成功的一轮记成中断。
        // 等到「状态仍是收口的 且 水位不再推进」才认，正好落在最终状态上。
        guard let pending = state.pendingClose, pending == detail.status, !advanced else {
            state.pendingClose = detail.status
            states[header.composerId] = state
            return
        }
        state.pendingClose = nil

        // 一整轮跑完都没被任何一次轮询逮到（turn 短于轮询间隔）→ 补一张开始卡，
        // 否则这一轮在历史里会整条消失。老会话被顺手碰一下不算，靠 fresh 挡住。
        let wasLive = state.phase == .live
        guard wasLive || fresh else {
            state.phase = .ended
            states[header.composerId] = state
            return
        }
        state.phase = .ended
        state.waiting = false
        state.lastSubagents = []
        states[header.composerId] = state
        // 只认开始那一刻的归属：中途冒出来的转录文件不能把收尾抢走
        guard !state.ownedByTranscript else { return }
        if !wasLive {
            emit(.taskStarted(title: state.title), composerId: header.composerId,
                state: state, at: now, now: now)
        }
        emit(
            .taskFinished(outcome: Self.outcome(status: detail.status), title: state.title,
                detail: nil),
            composerId: header.composerId, state: state, at: now, now: now)
    }

    /// `hasBlockingPendingActions` = Cursor 在等用户点确认（工具授权 / 阻塞式提问）。
    /// 只在翻转时发一次，复位交给下一次 `.activity`（TaskStore 会把 waiting 打回 running）。
    /// ⚠️ **尚未实勘到它真的翻 true**：一轮带命令执行的真实会话全程采样，该字段恒为 0。
    /// 字段名摆在那儿、代价也只是一次布尔比较，故保留；但别把「Cursor 会出等待授权卡」
    /// 当成已验证行为——真遇到授权弹窗时它可能压根不落盘（同 Hermes 的处境）。
    private func emitWaiting(_ header: Header, state: inout SessionState, now: Date) {
        guard header.blocking != state.waiting else { return }
        state.waiting = header.blocking
        guard header.blocking else { return }
        emit(.waiting(reason: .permission, message: nil), composerId: header.composerId,
            state: state, at: now, now: now)
    }

    /// ctx% 直接取 Cursor 自己算好的 `contextUsagePercent`（不用我们估），
    /// 沿用 CodeBuddy 的 ≥0.5pt 节流，避免每轮都刷一次 UI
    private func emitContext(
        _ header: Header, detail: Detail, state: inout SessionState, now: Date
    ) {
        guard let percent = detail.contextPercent ?? header.contextPercent, percent > 0 else {
            return
        }
        let clamped = min(100, max(0, percent))
        if let last = state.lastContextPercent, abs(last - clamped) < 0.5 { return }
        state.lastContextPercent = clamped
        emit(.contextUpdate(percent: clamped), composerId: header.composerId, state: state,
            at: now, now: now)
    }

    /// 子会话快照：`subagentComposerIds`（真子代理）与 `subComposerIds`（Best-of-N 并行变体）
    /// 都当子代理展示——岛上那个盒子要的就是「父会话下面并行跑着几路」。
    private func emitSubagents(
        _ header: Header, detail: Detail, db: SQLiteDB, state: inout SessionState, now: Date
    ) {
        let ids = detail.subagentIds.isEmpty ? header.subagentIds : detail.subagentIds
        guard !ids.isEmpty else {
            if !state.lastSubagents.isEmpty {
                state.lastSubagents = []
                emit(.subagentsUpdated([]), composerId: header.composerId, state: state,
                    at: now, now: now)
            }
            return
        }
        let subagents = ids.compactMap { childSubagent(db: db, composerId: $0) }
        guard subagents != state.lastSubagents else { return }
        state.lastSubagents = subagents
        emit(.subagentsUpdated(subagents), composerId: header.composerId, state: state,
            at: now, now: now)
    }

    private func childSubagent(db: SQLiteDB, composerId: String) -> SubagentInfo? {
        guard let detail = fetchDetail(db: db, composerId: composerId) else { return nil }
        let header = fetchHeader(db: db, composerId: composerId)
        let status: SubagentInfo.Status
        switch detail.status {
        case "completed": status = .completed
        case "aborted": status = .failed
        default: status = detail.generating ? .running : .completed
        }
        return SubagentInfo(
            agentId: composerId,
            agentType: "cursor",
            description: header?.title ?? "",
            status: status,
            currentActivity: detail.lastTool,
            startedAt: header?.createdAt,
            finishedAt: status == .running ? nil : header?.recency)
    }

    /// 静默超过 staleThreshold 的活跃会话按空闲收尾：Cursor 被强退时不会写 `status`，
    /// 不收尾岛上就挂着一张永不消失的运行卡。
    private func reapIdle(now: Date) {
        for (composerId, var state) in states
        where state.phase == .live && now.timeIntervalSince(state.lastProgressAt) > staleThreshold {
            state.phase = .reaped
            guard !state.ownedByTranscript else {
                states[composerId] = state  // 转录侧负责收尾，这里只记相位
                continue
            }
            state.waiting = false
            states[composerId] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(
                TaskEvent(
                    source: .cursor, sessionId: composerId,
                    kind: .taskFinished(outcome: .success, title: state.title, detail: nil),
                    timestamp: now, cwd: state.cwd, sessionStartedAt: state.startedAt),
                false)
        }
    }

    /// 掉出时间窗的行清掉，避免 states 无限膨胀；活跃行保留（等 reapIdle 收尾后再清）
    private func prune(seen: Set<String>) {
        for (composerId, state) in states
        where state.phase != .live && !seen.contains(composerId) {
            states.removeValue(forKey: composerId)
        }
    }

    // MARK: - 读库

    private func fetchHeaders(db: SQLiteDB, now: Date) -> [Header] {
        let cutoff = Int64((now.timeIntervalSince1970 - recentWindow) * 1000)
        let rows = (try? db.query("""
            SELECT composerId, workspaceId, createdAt, recency, value
            FROM composerHeaders
            WHERE recency >= ? AND COALESCE(isArchived, 0) = 0
            ORDER BY recency DESC
            LIMIT ?
            """, [.int(cutoff), .int(Int64(maxSessions))]) { row in
            (row.text(0) ?? "", row.text(1), row.int(2), row.int(3), row.text(4))
        }) ?? []
        return rows.compactMap { header(composerId: $0.0, workspaceId: $0.1, createdAtMs: $0.2,
            recencyMs: $0.3, value: $0.4) }
    }

    private func fetchHeader(db: SQLiteDB, composerId: String) -> Header? {
        let rows = (try? db.query("""
            SELECT composerId, workspaceId, createdAt, recency, value
            FROM composerHeaders WHERE composerId = ?
            """, [.text(composerId)]) { row in
            (row.text(0) ?? "", row.text(1), row.int(2), row.int(3), row.text(4))
        }) ?? []
        return rows.first.flatMap {
            header(composerId: $0.0, workspaceId: $0.1, createdAtMs: $0.2, recencyMs: $0.3,
                value: $0.4, allowSubagent: true)
        }
    }

    private func header(
        composerId: String, workspaceId: String?, createdAtMs: Int64, recencyMs: Int64,
        value: String?, allowSubagent: Bool = false
    ) -> Header? {
        guard !composerId.isEmpty else { return nil }
        let json = value.flatMap { Self.parse($0) } ?? [:]
        // 草稿（还没发过 prompt 的空会话）与子会话不占岛上的位置
        if json["isDraft"] as? Bool == true { return nil }
        if !allowSubagent, json["subagentInfo"] != nil { return nil }
        return Header(
            composerId: composerId,
            workspaceId: workspaceId.flatMap { $0.isEmpty ? nil : $0 },
            createdAt: createdAtMs > 0 ? Date(timeIntervalSince1970: Double(createdAtMs) / 1000) : nil,
            recency: Date(timeIntervalSince1970: Double(recencyMs) / 1000),
            title: (json["name"] as? String).flatMap { summarizeTitle($0) },
            contextPercent: (json["contextUsagePercent"] as? NSNumber)?.doubleValue,
            blocking: json["hasBlockingPendingActions"] as? Bool == true,
            subagentIds: Self.ids(json["subagentComposerIds"]) + Self.ids(json["subComposerIds"]))
    }

    private func fetchDetail(db: SQLiteDB, composerId: String) -> Detail? {
        let rows = (try? db.query(
            "SELECT value FROM cursorDiskKV WHERE key = ?",
            [.text("composerData:\(composerId)")]) { $0.text(0) }) ?? []
        guard let json = rows.first.flatMap({ $0 }).flatMap({ Self.parse($0) }) else { return nil }
        let bubbleIds = (json["fullConversationHeadersOnly"] as? [[String: Any]] ?? [])
            .compactMap { $0["bubbleId"] as? String }
        let contextTokens = (json["contextTokensUsed"] as? NSNumber)?.int64Value ?? 0
        return Detail(
            progress: Int64(bubbleIds.count) + contextTokens,
            generating: !Self.ids(json["generatingBubbleIds"]).isEmpty,
            status: json["status"] as? String ?? "",
            contextPercent: (json["contextUsagePercent"] as? NSNumber)?.doubleValue,
            lastTool: lastTool(db: db, composerId: composerId, bubbleIds: bubbleIds),
            bubbleIds: bubbleIds,
            subagentIds: Self.ids(json["subagentComposerIds"]) + Self.ids(json["subComposerIds"]))
    }

    /// 当前工具名：从尾部往回找最近一条带 `toolFormerData` 的气泡。
    /// 只看最后 8 条——再往回翻拿到的是上一轮的工具，反而误导。
    private func lastTool(db: SQLiteDB, composerId: String, bubbleIds: [String]) -> String? {
        let tail = bubbleIds.suffix(8)
        guard !tail.isEmpty else { return nil }
        for bubbleId in tail.reversed() {
            let rows = (try? db.query(
                "SELECT value FROM cursorDiskKV WHERE key = ?",
                [.text("bubbleId:\(composerId):\(bubbleId)")]) { $0.text(0) }) ?? []
            guard let json = rows.first.flatMap({ $0 }).flatMap({ Self.parse($0) }),
                let tool = json["toolFormerData"] as? [String: Any],
                let name = tool["name"] as? String, !name.isEmpty
            else { continue }
            return CursorToolNames.displayName(name)
        }
        return nil
    }

    // MARK: - 小工具

    private func emit(
        _ kind: TaskEvent.Kind, composerId: String, state: SessionState, at timestamp: Date,
        now: Date
    ) {
        HealthRegistry.shared.event(Self.healthName)
        let isStale = now.timeIntervalSince(timestamp) > staleThreshold
        handler(
            TaskEvent(
                source: .cursor, sessionId: composerId, kind: kind,
                timestamp: timestamp, cwd: state.cwd, sessionStartedAt: state.startedAt),
            isStale)
    }

    static func parse(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func ids(_ raw: Any?) -> [String] {
        (raw as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
    }

    /// `status` 取值实勘：`completed` / `aborted` / `none` / 空
    static func isClosed(_ status: String) -> Bool {
        status == "completed" || status == "aborted"
    }

    static func outcome(status: String) -> TaskOutcome {
        status == "aborted" ? .interrupted : .success
    }
}
