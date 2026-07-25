import EurekaKit
import Foundation

/// 增量 tail Gemini CLI 会话（~/.gemini/tmp/<slug>/chats/session-*.jsonl）。
/// Gemini 无 hook/notify 回调，这是实时通道（与 grok/kimi tailer 同理）：
/// 轮询近期有写入的会话文件，按 offset 续读、半行不消费；新发现文件只做尾部状态恢复。
/// 生命周期映射：user 消息（非 session_context 注入）→ taskStarted；
/// gemini 消息 → taskFinished(success)；error 消息 → taskFinished(error)。
/// cwd 由 projects.json 的 slug 反查；标题 = 首条真实用户消息摘要。
public final class GeminiChatTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let tmpRoot: URL
    private let projectsFile: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.gemini-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
    }
    private var contexts: [String: FileContext] = [:]

    static let healthName = "gemini 事件监视"

    public init(
        tmpRoot: URL = GeminiPaths.tmpRoot(),
        projectsFile: URL = GeminiPaths.projectsFile(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.tmpRoot = tmpRoot
        self.projectsFile = projectsFile
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
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

    /// 公开供测试与启动时同步调用
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for url in recentChatFiles() {
            tail(url)
        }
    }

    // MARK: - 文件发现

    private func recentChatFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let slugDirs = (try? fm.contentsOfDirectory(
            at: tmpRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for slugDir in slugDirs where isDirectory(slugDir) {
            let chatsDir = slugDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files
            where file.lastPathComponent.hasPrefix("session-")
                && file.pathExtension.lowercased() == "jsonl" {
                guard let mtime = (try? file.resourceValues(
                    forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(file)
            }
        }
        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - 增量读取

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

        let consumed = processLines(data, url: url, replay: true)
        offsets[path] = offset + UInt64(consumed)
    }

    /// 处理完整行（最后的半行不消费），返回消费字节数
    @discardableResult
    private func processLines(_ data: Data, url: URL, replay: Bool) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var ctx = context(for: url)
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n"))
                ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            cursor = cursor < complete.endIndex && lineEnd < complete.endIndex
                ? complete.index(after: lineEnd) : complete.endIndex
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            absorb(root, into: &ctx)
            if replay, let event = event(from: root, context: ctx) {
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[url.path] = ctx
        return complete.count
    }

    /// header / 首条真实用户消息 → 上下文（sessionId / 开始时间 / 标题）
    private func absorb(_ root: [String: Any], into ctx: inout FileContext) {
        if root["type"] == nil, let header = GeminiChatDecoder.parseHeader(root) {
            ctx.sessionId = header.sessionId
            ctx.sessionStartedAt = header.startTime
            return
        }
        if ctx.title == nil, let message = GeminiChatDecoder.parseMessage(root),
           message.type == "user", !GeminiChatDecoder.isSessionContext(message.text) {
            ctx.title = summarizeTitle(message.text)
        }
    }

    /// 消息行 → 生命周期事件
    private func event(from root: [String: Any], context ctx: FileContext) -> TaskEvent? {
        guard let message = GeminiChatDecoder.parseMessage(root) else { return nil }
        let timestamp = message.timestamp ?? Date()
        switch message.type {
        case "user" where !GeminiChatDecoder.isSessionContext(message.text):
            return TaskEvent(
                source: .gemini, sessionId: ctx.sessionId,
                kind: .taskStarted(title: summarizeTitle(message.text)),
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        case "gemini":
            return TaskEvent(
                source: .gemini, sessionId: ctx.sessionId,
                kind: .taskFinished(outcome: .success, title: ctx.title, detail: nil),
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        case "error":
            return TaskEvent(
                source: .gemini, sessionId: ctx.sessionId,
                kind: .taskFinished(
                    outcome: .error, title: ctx.title,
                    detail: summarizeTitle(message.text)),
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        default:
            return nil
        }
    }

    /// 首扫读取上限：头 64KB 建上下文（header/首条真实用户消息在头部），
    /// 尾 256KB 恢复"最后状态"；更小的文件整读。大转录不再全量载入解析。
    private static let initialHeadBytes: UInt64 = 64 * 1024
    private static let initialTailBytes: UInt64 = 256 * 1024

    /// 新发现文件：头 64KB 建上下文（header 在首行、标题在头部），只从尾 256KB
    /// 恢复"最后状态"，不重放历史——仍在进行中（最后 user 晚于最后 gemini/error）
    /// 补发 running，否则注册空闲。
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var ctx = context(for: url)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?

        /// 扫一个数据块（块边界的半行丢弃），建上下文 + 跟踪最后 started/finished
        func scan(_ data: Data, dropLeadingPartial: Bool, dropTrailingPartial: Bool) {
            var lines = data.split(separator: UInt8(ascii: "\n"))[...]
            if dropLeadingPartial, !lines.isEmpty { lines = lines.dropFirst() }
            if dropTrailingPartial, !lines.isEmpty { lines = lines.dropLast() }
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let root = object as? [String: Any]
                else { continue }
                absorb(root, into: &ctx)
                guard let event = event(from: root, context: ctx) else { continue }
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

        if size <= Self.initialHeadBytes + Self.initialTailBytes {
            // 小文件整读（结尾半行 JSON 解析自然失败，与整读旧行为一致）
            guard let data = try? handle.readToEnd() else { return }
            scan(data, dropLeadingPartial: false, dropTrailingPartial: false)
        } else {
            guard let head = try? handle.read(upToCount: Int(Self.initialHeadBytes))
            else { return }
            scan(head, dropLeadingPartial: false,
                 dropTrailingPartial: head.last != UInt8(ascii: "\n"))
            guard (try? handle.seek(toOffset: size - Self.initialTailBytes)) != nil,
                  let tail = try? handle.readToEnd()
            else { return }
            scan(tail, dropLeadingPartial: true, dropTrailingPartial: false)
        }
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
            let base = lastFinished ?? lastStarted!
            var event = base
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
    }

    // MARK: - 上下文

    private func context(for url: URL) -> FileContext {
        if let cached = contexts[url.path] { return cached }
        // slug = chats 上级目录名；cwd 反查 projects.json
        let slug = url
            .deletingLastPathComponent()   // chats/
            .deletingLastPathComponent()   // <slug>/
            .lastPathComponent
        let cwd = GeminiPaths.slugToProject(projectsFile: projectsFile)[slug]
        return FileContext(
            sessionId: url.deletingPathExtension().lastPathComponent,
            cwd: cwd, sessionStartedAt: nil, title: nil)
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
            .flatMap { ($0 as? NSNumber)?.uint64Value }
    }
}
