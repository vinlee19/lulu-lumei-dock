import Foundation
import EurekaKit

/// 增量 tail Codex rollout 文件（~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl）。
/// 轮询今天/昨天日期目录中近期有写入的文件；按 offset 续读、半行不消费。
/// 新发现的文件只做"尾部状态恢复"（找出最后的生命周期状态），不重放历史。
public final class CodexRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void
    public typealias RateLimitHandler = (RateLimitSnapshot) -> Void

    /// 默认 ~/.codex/sessions，可用 EUREKA_CODEX_SESSIONS 覆盖（测试用）
    public static func defaultSessionsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEX_SESSIONS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    private let sessionsRoot: URL
    private let staleThreshold: TimeInterval
    private let handler: Handler
    private let rateLimitHandler: RateLimitHandler?
    private let queue = DispatchQueue(label: "com.vinlee.eureka.codex-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
    }
    private var contexts: [String: FileContext] = [:]

    public init(
        sessionsRoot: URL,
        staleThreshold: TimeInterval = 300,
        rateLimitHandler: RateLimitHandler? = nil,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.staleThreshold = staleThreshold
        self.rateLimitHandler = rateLimitHandler
        self.handler = handler
    }

    static let healthName = "Codex rollout 监视"

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
        for url in recentRolloutFiles() {
            tail(url)
        }
    }

    // MARK: - 文件发现

    /// 今天/昨天（本地时区，与 rollout 目录命名一致）日期目录下全部 rollout 文件。
    /// 不按 mtime 过滤：tail() 内部已有 size 检查（无新数据则跳过），过滤只会漏掉
    /// 长时间空闲后重新活跃、或历史已完成的会话文件。
    private func recentRolloutFiles() -> [URL] {
        let fm = FileManager.default
        let calendar = Calendar.current
        let now = Date()
        var results: [URL] = []
        for dayOffset in 0...1 {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = parts.year, let m = parts.month, let d = parts.day else { continue }
            let dir = sessionsRoot
                .appendingPathComponent(String(format: "%04d", y), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", m), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", d), isDirectory: true)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" {
                results.append(file)
            }
        }
        return results
    }

    // MARK: - 增量读取

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // 文件被截断/重写
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, context: context(for: url))
        offsets[path] = offset + UInt64(consumed)
    }

    /// 处理完整行（最后的半行不消费，等下次轮询），返回消费的字节数
    private func processLines(_ data: Data, context: FileContext) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            if !line.isEmpty {
                deliver(
                    decoded: CodexRolloutDecoder.decode(
                        line: Data(line), sessionId: context.sessionId, cwd: context.cwd),
                    context: context)
            }
            cursor = complete.index(after: lineEnd)
        }
        return complete.count
    }

    private func deliver(decoded: [CodexRolloutDecoder.Decoded], context: FileContext) {
        for item in decoded {
            switch item {
            case .sessionMeta:
                break  // context 已在发现文件时建立
            case .event(var event):
                event.sessionStartedAt = context.sessionStartedAt
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            case .rateLimits(let snapshot):
                rateLimitHandler?(snapshot)
            case .tokenUsage:
                break  // M5 用量引擎消费
            }
        }
    }

    /// 新发现的文件：读首行建上下文，再从尾部恢复"最后状态"——
    /// - 仍在进行中（最后 task_started 晚于最后 task_complete）：补发 running 事件
    /// - 已完成（最后 task_complete 晚于最后 task_started）：补发 finished 事件
    ///   让最近完成的任务能正常出卡（超过 staleThreshold 则仅写历史，不弹岛）
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        let ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 65536)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastStartedEvent: TaskEvent?
        var lastFinishedEvent: TaskEvent?
        var lastTitle: String?
        var lastRateLimits: RateLimitSnapshot?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            for item in CodexRolloutDecoder.decode(
                line: Data(line), sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch item {
                case .event(let event):
                    switch event.kind {
                    case .taskStarted(let title) where title != nil:
                        lastTitle = title
                    case .taskStarted:
                        lastStartedEvent = event
                    case .taskFinished:
                        lastFinishedEvent = event
                    default:
                        break
                    }
                case .rateLimits(let snapshot):
                    lastRateLimits = snapshot
                case .sessionMeta, .tokenUsage:
                    break
                }
            }
        }

        if let snapshot = lastRateLimits {
            rateLimitHandler?(snapshot)
        }

        if let started = lastStartedEvent {
            if let finished = lastFinishedEvent, finished.timestamp >= started.timestamp {
                // 任务已结束：以 sessionStarted 直接注册为空闲（通知卡由 notify 通道负责）
                // 避免发 taskFinished：store 里没有 existing task → idle 无法建立；
                // 也避免重复卡或与 dedup 窗口产生竞态。
                var ev = started
                ev.kind = .sessionStarted
                ev.sessionStartedAt = ctx.sessionStartedAt
                handler(ev, false)
                if let title = lastTitle {
                    var titleEv = ev
                    titleEv.kind = .titleUpdate(title: title)
                    handler(titleEv, false)
                }
            } else {
                // 仍在进行中：补发 running（不按 stale 抑制，timestamp 用真实开始时间）
                var event = started
                event.sessionStartedAt = ctx.sessionStartedAt
                if let title = lastTitle { event.kind = .taskStarted(title: title) }
                handler(event, false)
            }
        } else if let finished = lastFinishedEvent {
            // 尾窗未含 task_started（超长会话），但任务已结束：同样注册空闲
            var ev = finished
            ev.kind = .sessionStarted
            ev.sessionStartedAt = ctx.sessionStartedAt
            handler(ev, false)
            if let title = lastTitle {
                var titleEv = ev
                titleEv.kind = .titleUpdate(title: title)
                handler(titleEv, false)
            }
        }
    }

    private func context(for url: URL) -> FileContext {
        let path = url.path
        if let cached = contexts[path] { return cached }

        var ctx = FileContext(sessionId: sessionIdFromFilename(url), cwd: nil, sessionStartedAt: nil)
        // 首行应是 session_meta
        if let handle = FileHandle(forReadingAtPath: path),
           let head = try? handle.read(upToCount: 16384) {
            try? handle.close()
            if let newline = head.firstIndex(of: UInt8(ascii: "\n")) {
                let decoded = CodexRolloutDecoder.decode(
                    line: head[head.startIndex..<newline],
                    sessionId: ctx.sessionId, cwd: nil)
                for case .sessionMeta(let id, let cwd, let startedAt) in decoded {
                    ctx = FileContext(sessionId: id, cwd: cwd, sessionStartedAt: startedAt)
                }
            }
        }
        contexts[path] = ctx
        return ctx
    }

    /// rollout-2026-06-08T23-36-02-<uuid>.jsonl → uuid 兜底
    private func sessionIdFromFilename(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        if parts.count >= 5 {
            return parts.suffix(5).joined(separator: "-")
        }
        return stem
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
