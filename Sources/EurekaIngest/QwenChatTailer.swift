import EurekaKit
import Foundation

/// Incrementally tails Qwen sessions (~/.qwen/projects/<encoded>/chats/<uuid>.jsonl). Qwen has no
/// hook/notify callbacks, so this is the live channel (same as the gemini/kimi tailers). Lifecycle
/// mapping: user message → taskStarted; assistant message → taskFinished(success); api_response
/// status_code ≠ 200 → taskFinished(error). cwd comes from the message line's cwd field.
/// functionCall parts of assistant messages → activity(tool name) (heartbeat for long tool runs).
/// Context usage: input_token_count of the api_response telemetry line (includes cache reads, ≈
/// current context size) ÷ the ContextWindows window (no official figure for the qwen family yet →
/// default 200k).
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
    private var lastContextPercent: [String: Double] = [:]

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
        // leeway lets the system coalesce wakeups to save power; must be smaller than the poll
        // interval (100ms for the 1s tier)
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

    /// Public for tests and synchronous calls at launch
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
        if size < offset { offset = 0 }  // Session resume may rewrite the whole file
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
            for event in events(from: root, context: ctx) {
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
        guard let message = QwenChatDecoder.parseMessage(root) else { return }
        if ctx.cwd == nil { ctx.cwd = message.cwd }
        if ctx.sessionStartedAt == nil { ctx.sessionStartedAt = message.timestamp }
        if ctx.title == nil, message.type == "user", !message.text.isEmpty {
            ctx.title = summarizeTitle(message.text)
        }
    }

    /// One line → domain events (0..n: one assistant message can carry several functionCalls)
    private func events(from root: [String: Any], context ctx: FileContext) -> [TaskEvent] {
        // API error (status_code ≠ 200) → finish with error
        if let response = QwenChatDecoder.apiResponse(root),
           let status = (response["status_code"] as? NSNumber)?.intValue, status != 200 {
            return [TaskEvent(
                source: .qwen, sessionId: ctx.sessionId,
                kind: .taskFinished(
                    outcome: .error, title: ctx.title, detail: "API \(status)"),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)]
        }
        guard let message = QwenChatDecoder.parseMessage(root) else { return [] }
        let timestamp = message.timestamp ?? Date()
        func event(_ kind: TaskEvent.Kind) -> TaskEvent {
            TaskEvent(
                source: .qwen, sessionId: ctx.sessionId, kind: kind,
                timestamp: timestamp, cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt)
        }
        switch message.type {
        case "user" where !message.text.isEmpty:
            return [event(.taskStarted(title: summarizeTitle(message.text)))]
        case "assistant":
            var results: [TaskEvent] = []
            // functionCall parts → tool heartbeat (previously dropped, so long tool runs showed no
            // activity)
            for tool in message.toolCalls {
                results.append(event(.activity(tool: tool)))
            }
            if !message.text.isEmpty {
                results.append(event(.taskFinished(
                    outcome: .success, title: ctx.title, detail: nil)))
            }
            return results
        default:
            return []
        }
    }

    /// Side channel for context usage from api_response telemetry lines: input_token_count includes
    /// cache reads (same accounting as QwenUsageScanner), ≈ current context size
    private func contextUsage(_ root: [String: Any]) -> (model: String?, used: Int)? {
        guard let response = QwenChatDecoder.apiResponse(root),
              let input = (response["input_token_count"] as? NSNumber)?.intValue,
              input > 0
        else { return nil }
        return (response["model"] as? String, input)
    }

    // MARK: - Context usage (api_response input_token_count ÷ ContextWindows window)

    /// Same as the kimi/grok tailers: events are fresh as of emission time (the stale gate would
    /// drop an outdated contextUpdate), and re-emitted only on a change ≥0.5 to avoid flooding.
    /// TaskStore doesn't create tasks for contextUpdate, and we only emit for tracked sessions, so
    /// no phantom tasks appear.
    private func emitContext(
        for chatURL: URL, context ctx: FileContext,
        usage: (model: String?, used: Int)
    ) {
        let percent = min(100, ContextWindows.percent(used: usage.used, model: usage.model))
        if let last = lastContextPercent[chatURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[chatURL.path] = percent
        HealthRegistry.shared.event(Self.healthName)
        handler(TaskEvent(
            source: .qwen, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// First-scan read limits: the first 64KB builds context (cwd/title/start time come from the
    /// head messages), the last 256KB restores the "last state"; smaller files are read whole.
    /// Large transcripts are no longer fully loaded and parsed.
    private static let initialHeadBytes: UInt64 = 64 * 1024
    private static let initialTailBytes: UInt64 = 256 * 1024

    /// Newly discovered file: build context from the first 64KB, restore the "last state" only from
    /// the last 256KB, no history replay
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var ctx = context(for: url)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, used: Int)?

        /// Scan one chunk (partial lines at chunk boundaries are dropped), building context +
        /// tracking the last started/finished
        func scan(_ data: Data, dropLeadingPartial: Bool, dropTrailingPartial: Bool) {
            var lines = data.split(separator: UInt8(ascii: "\n"))[...]
            if dropLeadingPartial, !lines.isEmpty { lines = lines.dropFirst() }
            if dropTrailingPartial, !lines.isEmpty { lines = lines.dropLast() }
            for line in lines {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                      let root = object as? [String: Any]
                else { continue }
                absorb(root, into: &ctx)
                if let usage = contextUsage(root) { lastUsage = usage }
                for event in events(from: root, context: ctx) {
                    switch event.kind {
                    case .taskStarted: lastStarted = event
                    case .taskFinished: lastFinished = event
                    default: break
                    }
                }
            }
        }

        if size <= Self.initialHeadBytes + Self.initialTailBytes {
            // Small files are read whole (a trailing partial line simply fails JSON parsing,
            // matching the old whole-file behavior)
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
        // Tail telemetry reflects the latest context usage (TaskStore drops unknown sessions, so
        // this is safe)
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
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
