import EurekaKit
import Foundation

/// 增量 tail Qwen 会话（~/.qwen/projects/<encoded>/chats/<uuid>.jsonl）。
/// Qwen 无 hook/notify 回调，这是实时通道（与 gemini/kimi tailer 同理）。
/// 生命周期映射：user 消息 → taskStarted；assistant 消息 → taskFinished(success)；
/// api_response status_code ≠ 200 → taskFinished(error)。cwd 从消息行 cwd 字段带出。
public final class QwenChatTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.qwen-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
    }
    private var contexts: [String: FileContext] = [:]

    static let healthName = "qwen 事件监视"

    public init(
        projectsRoot: URL = QwenPaths.projectsRoot(),
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

    private func recentChatFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs
        where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let chatsDir = projectDir.appendingPathComponent("chats", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: chatsDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
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
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            absorb(root, into: &ctx)
            if let event = event(from: root, context: ctx) {
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
    }

    private func absorb(_ root: [String: Any], into ctx: inout FileContext) {
        guard let message = QwenChatDecoder.parseMessage(root) else { return }
        if ctx.cwd == nil { ctx.cwd = message.cwd }
        if ctx.sessionStartedAt == nil { ctx.sessionStartedAt = message.timestamp }
        if ctx.title == nil, message.type == "user", !message.text.isEmpty {
            ctx.title = summarizeTitle(message.text)
        }
    }

    private func event(from root: [String: Any], context ctx: FileContext) -> TaskEvent? {
        // API 错误（status_code ≠ 200）→ 出错收尾
        if let response = QwenChatDecoder.apiResponse(root),
           let status = (response["status_code"] as? NSNumber)?.intValue, status != 200 {
            return TaskEvent(
                source: .qwen, sessionId: ctx.sessionId,
                kind: .taskFinished(
                    outcome: .error, title: ctx.title, detail: "API \(status)"),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        }
        guard let message = QwenChatDecoder.parseMessage(root) else { return nil }
        let timestamp = message.timestamp ?? Date()
        switch message.type {
        case "user" where !message.text.isEmpty:
            return TaskEvent(
                source: .qwen, sessionId: ctx.sessionId,
                kind: .taskStarted(title: summarizeTitle(message.text)),
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        case "assistant" where !message.text.isEmpty:
            return TaskEvent(
                source: .qwen, sessionId: ctx.sessionId,
                kind: .taskFinished(outcome: .success, title: ctx.title, detail: nil),
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        default:
            return nil
        }
    }

    /// 首扫读取上限：头 64KB 建上下文（cwd/标题/开始时间取自头部消息），
    /// 尾 256KB 恢复"最后状态"；更小的文件整读。大转录不再全量载入解析。
    private static let initialHeadBytes: UInt64 = 64 * 1024
    private static let initialTailBytes: UInt64 = 256 * 1024

    /// 新发现文件：头 64KB 建上下文，只从尾 256KB 恢复"最后状态"，不重放历史
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
            var event = lastFinished ?? lastStarted!
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
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
