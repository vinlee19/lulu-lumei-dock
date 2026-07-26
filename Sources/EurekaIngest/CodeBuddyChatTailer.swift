import EurekaKit
import Foundation

/// 增量 tail CodeBuddy 会话（~/.codebuddy/projects/<cwd-slug>/<sessionId>.jsonl）。
/// CodeBuddy 无 hook/notify 回调，这是实时通道（与 qwen/kimi tailer 同理）。
/// 只看顶层会话文件，不 tail `<sessionId>/subagents/` 子目录（子代理 token 由
/// CodeBuddyUsageScanner 归并，事件流以主会话为准）；子 agent 现场由
/// CodeBuddySubagentScanner 快照（父 transcript 的 function_call/result 对派生）
/// 在运行中会话上随轮询以 .subagentsUpdated 发出。
/// 生命周期映射（CodeBuddyTranscriptDecoder）：user 消息（非 skipRun）→ taskStarted；
/// function_call → activity(工具名)；assistant completed → taskFinished(success)；
/// ai-title/summary → titleUpdate（只改已有任务标题，不造幻影任务）。
/// 上下文占用：function_call 行的归一化用量（复用 decoder 的 usage 提取，
/// input + cacheRead ≈ 当前上下文大小）÷ ContextWindows 窗口。
public final class CodeBuddyChatTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.codebuddy-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        /// 标题来源优先级：ai-title(2) > summary(1) > 首条 user 文本(0)，高优先级可覆盖
        var titleRank: Int = -1
        /// 当前是否有未收尾的 turn（子 agent 快照只在运行中扫描）
        var running = false
        /// 当前 turn 起点（taskStarted 时间）：子 agent 快照按它裁到本 turn
        var turnStartedAt: Date?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    /// 各会话上次发出的子 agent 快照（变化才重发；TaskStore 还会再去重）
    private var lastSubagents: [String: [SubagentInfo]] = [:]

    static let healthName = "codebuddy 事件监视"

    public init(
        projectsRoot: URL = CodeBuddyPaths.projectsRoot(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.projectsRoot = projectsRoot
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
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

    /// 公开供测试与启动时同步调用
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for url in recentSessionFiles() {
            tail(url)
        }
        emitSubagentUpdates()
    }

    /// projects/<slug>/*.jsonl 顶层文件（不进 <sessionId>/subagents/ 子目录）
    private func recentSessionFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs
        where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension.lowercased() == "jsonl" {
                guard let mtime = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(file)
            }
        }
        return results
    }

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // 会话恢复可能整写文件
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]
        var ctx = context(for: url)
        var lastUsage: (model: String?, used: Int)?
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            absorb(root, into: &ctx)
            if let usage = contextUsage(root) { lastUsage = usage }
            if let event = event(from: root, context: ctx) {
                switch event.kind {
                case .taskStarted:
                    ctx.running = true
                    ctx.turnStartedAt = event.timestamp
                case .taskFinished:
                    ctx.running = false
                default:
                    break
                }
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    private func absorb(_ root: [String: Any], into ctx: inout FileContext) {
        if ctx.cwd == nil { ctx.cwd = root["cwd"] as? String }
        if ctx.sessionStartedAt == nil {
            ctx.sessionStartedAt = CodeBuddyTranscriptDecoder.timestamp(root)
        }
        // 标题优先级：ai-title > summary > 首条 user 文本
        switch root["type"] as? String {
        case "ai-title", "summary":
            let rank = root["type"] as? String == "ai-title" ? 2 : 1
            if rank > ctx.titleRank, let title = CodeBuddyTranscriptDecoder.title(root) {
                ctx.title = title
                ctx.titleRank = rank
            }
        case "message":
            if ctx.titleRank < 0, let text = CodeBuddyTranscriptDecoder.userText(root),
               let title = summarizeTitle(text) {
                ctx.title = title
                ctx.titleRank = 0
            }
        default:
            break
        }
    }

    private func event(from root: [String: Any], context ctx: FileContext) -> TaskEvent? {
        guard var event = CodeBuddyTranscriptDecoder.decode(
            root: root, sessionId: ctx.sessionId, cwd: ctx.cwd)
        else { return nil }
        // taskFinished 的标题由上下文补（行内不带标题）
        if case .taskFinished(let outcome, nil, let detail) = event.kind {
            event.kind = .taskFinished(outcome: outcome, title: ctx.title, detail: detail)
        }
        event.sessionStartedAt = ctx.sessionStartedAt
        return event
    }

    /// function_call 行的上下文用量旁路：复用 decoder 的归一化 usage，
    /// input + cacheRead = 含缓存读的完整提示 ≈ 当前上下文大小
    private func contextUsage(_ root: [String: Any]) -> (model: String?, used: Int)? {
        guard let (model, usage) = CodeBuddyTranscriptDecoder.usage(root) else { return nil }
        let used = usage.input + usage.cacheRead
        return used > 0 ? (model, used) : nil
    }

    // MARK: - 上下文占用（function_call usage ÷ ContextWindows 窗口）

    /// 与 kimi/grok tailer 同例：按发射时刻 fresh 事件（stale 闸门会丢掉过期
    /// contextUpdate），只在变化 ≥0.5 时补发避免刷屏。TaskStore 不为 contextUpdate
    /// 建任务，且此处只对已跟踪会话发射，不会造幻影任务。
    private func emitContext(
        for chatURL: URL, context ctx: FileContext,
        usage: (model: String?, used: Int)
    ) {
        let percent = min(100, ContextWindows.percent(used: usage.used, model: usage.model))
        if let last = lastContextPercent[chatURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[chatURL.path] = percent
        HealthRegistry.shared.event(Self.healthName)
        handler(TaskEvent(
            source: .codebuddy, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// 新发现文件：只读头部 64KB 建上下文（cwd/起始时间/标题多在头部）
    /// + 尾部 256KB 恢复"最后状态"，不重放历史；小文件（≤320KB）一次读完。
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        let headLength: UInt64 = 65536
        let tailLength: UInt64 = 256 * 1024
        var chunks: [Data] = []
        if size <= headLength + tailLength {
            guard let data = try? handle.readToEnd() else { return }
            chunks = [data]
        } else {
            // 头部只用于建上下文，末尾可能的半行直接丢弃
            guard let head = try? handle.read(upToCount: Int(headLength)) else { return }
            if let lastNewline = head.lastIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(head[head.startIndex...lastNewline]))
            }
            // 尾部起点可能落在半行中间，对齐到第一个换行之后
            guard (try? handle.seek(toOffset: size - tailLength)) != nil,
                  let tail = try? handle.readToEnd()
            else { return }
            if let firstNewline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(tail[tail.index(after: firstNewline)...]))
            }
        }

        var ctx = context(for: url)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, used: Int)?
        for chunk in chunks {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let root = object as? [String: Any]
                else { continue }
                absorb(root, into: &ctx)
                if let usage = contextUsage(root) { lastUsage = usage }
                guard let event = event(from: root, context: ctx) else { continue }
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }
        // 运行状态与 turn 起点：子 agent 快照按 turn 裁剪、只在运行中扫描
        ctx.running = lastStarted != nil
            && (lastFinished.map { $0.timestamp < lastStarted!.timestamp } ?? true)
        ctx.turnStartedAt = lastStarted?.timestamp
        contexts[path] = ctx

        func titleEvent(from base: TaskEvent) {
            guard let title = ctx.title, !title.isEmpty else { return }
            var event = base
            event.kind = .titleUpdate(title: title)
            handler(event, false)
        }

        if let started = lastStarted,
           lastFinished.map({ $0.timestamp < started.timestamp }) ?? true {
            var event = started
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        } else if lastStarted != nil || lastFinished != nil {
            var event = lastFinished ?? lastStarted!
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
        // 尾部 usage 反映最新上下文占用（TaskStore 对未知会话直接丢弃，安全）
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - 子 agent 快照（父 transcript 的 function_call/result 对派生）

    /// 只对已跟踪且运行中的会话扫描（幻影任务不变式：不为未跟踪会话发事件）；
    /// 快照变化才发（TaskStore 还会再去重）；转空闲后清缓存，下一 turn 重新发。
    private func emitSubagentUpdates() {
        for (path, ctx) in contexts {
            guard ctx.running else {
                lastSubagents[path] = []
                continue
            }
            let file = URL(fileURLWithPath: path)
            let subagents = CodeBuddySubagentScanner.scan(
                sessionDir: file.deletingPathExtension(),
                parentTranscript: file,
                turnStartedAt: ctx.turnStartedAt)
            guard subagents != (lastSubagents[path] ?? []) else { continue }
            lastSubagents[path] = subagents
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .codebuddy, sessionId: ctx.sessionId,
                kind: .subagentsUpdated(subagents),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt), false)
        }
    }

    private func context(for url: URL) -> FileContext {
        contexts[url.path] ?? FileContext(
            sessionId: url.deletingPathExtension().lastPathComponent,
            cwd: nil, sessionStartedAt: nil, title: nil)
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
            .flatMap { ($0 as? NSNumber)?.uint64Value }
    }
}
