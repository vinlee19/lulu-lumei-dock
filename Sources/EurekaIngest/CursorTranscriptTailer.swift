import EurekaKit
import Foundation

/// 尾随 Cursor 的会话转录 `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`。
///
/// 这是 Cursor 的**第二条**实时通道，与 `CursorStateTailer`（轮询 `state.vscdb`）分工明确：
///   - 转录有**显式的 `turn_ended`**，收尾不用像库侧那样靠「状态收口 + 水位不动」防抖
///     （库里同一轮会先写 `aborted` 再写 `completed`）；
///   - 转录**没有** token / ctx% / todos / 子会话，那些只有库里有。
/// 所以：**同一个 composer 一旦有转录文件，生命周期事件由本 tailer 独占**，
/// 库侧让出（见 `CursorStateTailer` 的 `transcriptOwned`），只继续供 ctx% 与子会话。
/// 两边的 sessionId 都是 composerId，让出之后不会出现两张卡或两条历史。
///
/// ⚠️ 转录只覆盖这个特性上线之后的回合（实勘 3.13.10 才开始写），历史会话一条都没有 →
/// 它永远不能替代库通道，只能叠在上面。
public final class CursorTranscriptTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private struct FileContext {
        var composerId: String
        var cwd: String?
        var title: String?
        var running = false
    }

    private let cliHome: URL
    private let workspaceStorageRoot: URL
    private let staleThreshold: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.cursor-transcript")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private var contexts: [String: FileContext] = [:]

    static let healthName = "Cursor 转录监视"

    public init(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        staleThreshold: TimeInterval = 300,
        handler: @escaping Handler
    ) {
        self.cliHome = cliHome
        self.workspaceStorageRoot = workspaceStorageRoot
        self.staleThreshold = staleThreshold
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
        for entry in CursorTranscriptIndex.entries(
            cliHome: cliHome, workspaceStorageRoot: workspaceStorageRoot, now: now) {
            tail(entry, now: now)
        }
    }

    private func tail(_ entry: CursorTranscriptIndex.Entry, now: Date) {
        let path = entry.url.path
        guard let size = fileSize(path) else { return }
        // 先取出来改、再整体写回：绝不能写成
        // `contexts[path]?.cwd = entry.cwd ?? contexts[path]?.cwd` ——
        // 左边对字典是独占的修改访问，右边又读同一个键，重叠访问会让 Swift 直接 abort。
        // （`??` 在 cwd 非 nil 时短路，所以只有 empty-window 那种无 cwd 的会话才炸，
        //   测试里 cwd 恒非 nil 就漏掉了这条路径。）
        var stored = contexts[path] ?? FileContext(composerId: entry.composerId, cwd: entry.cwd)
        if let cwd = entry.cwd { stored.cwd = cwd }
        contexts[path] = stored

        guard var offset = offsets[path] else {
            initialScan(entry, size: size, now: now)
            return
        }
        if size < offset { offset = 0 }  // 整写（重开同一会话）→ 从头再来
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty
        else { return }
        // 半行不消费：Cursor 正在写的那一行下一轮才完整
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]

        var ctx = contexts[path] ?? FileContext(composerId: entry.composerId, cwd: entry.cwd)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard var event = CursorTranscriptDecoder.decode(
                line: Data(line), sessionId: ctx.composerId, cwd: ctx.cwd) else { continue }
            switch event.kind {
            case .taskStarted(let title):
                ctx.running = true
                if let title { ctx.title = title }
            case .taskFinished(let outcome, _, let detail):
                ctx.running = false
                // 收尾行本身不带标题，补上本轮的提问摘要，历史里才看得出这轮干了啥
                event.kind = .taskFinished(outcome: outcome, title: ctx.title, detail: detail)
            default:
                break
            }
            HealthRegistry.shared.event(Self.healthName)
            handler(event, now.timeIntervalSince(event.timestamp) > staleThreshold)
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
    }

    /// 首见一个转录文件：只建水位，**绝不重放历史**。
    /// 唯一的例外是「文件已存在但这一轮还没收尾」——那说明 app 是在回合中途启动的，
    /// 补一张运行卡，否则这轮到结束前岛上什么都没有。
    private func initialScan(_ entry: CursorTranscriptIndex.Entry, size: UInt64, now: Date) {
        let path = entry.url.path
        offsets[path] = size
        var ctx = FileContext(composerId: entry.composerId, cwd: entry.cwd)
        defer { contexts[path] = ctx }

        guard let handle = FileHandle(forReadingAtPath: path),
            let data = try? handle.readToEnd()
        else { return }
        try? handle.close()

        var lastKind: TaskEvent.Kind?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = CursorTranscriptDecoder.decode(
                line: Data(line), sessionId: ctx.composerId, cwd: ctx.cwd) else { continue }
            if case .taskStarted(let title) = event.kind, let title { ctx.title = title }
            lastKind = event.kind
        }
        guard let lastKind else { return }
        if case .taskFinished = lastKind { return }  // 已收尾的历史回合：静默

        // 中途启动：这轮还在跑
        ctx.running = true
        HealthRegistry.shared.event(Self.healthName)
        handler(
            TaskEvent(
                source: .cursor, sessionId: ctx.composerId,
                kind: .taskStarted(title: ctx.title), timestamp: now, cwd: ctx.cwd),
            false)
    }

    private func fileSize(_ path: String) -> UInt64? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }
}
