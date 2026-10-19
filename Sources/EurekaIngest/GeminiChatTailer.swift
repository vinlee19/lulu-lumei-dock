import EurekaKit
import Foundation

/// Incrementally tails Gemini CLI sessions (~/.gemini/tmp/<slug>/chats/session-*.jsonl).
/// Gemini has no hook/notify callback, so this is the live channel (same as the grok/kimi
/// tailers): poll recently written session files, resume reading at the saved offset, never
/// consume a partial line; newly discovered files only restore their tail state.
/// Lifecycle mapping: user message (not a session_context injection) → taskStarted;
/// gemini message → taskFinished(success); error message → taskFinished(error).
/// Context usage: tokens.input + tokens.cached on a gemini line ≈ current context size;
/// the window comes from ContextWindows by the line's model (gemini-2.5/3 → 1M).
/// Tool activity is not mapped: local ~/.gemini/tmp/*/chats/*.jsonl (surveyed 2026-07, CLI 0.52)
/// only has header/$set/user/info/gemini/error lines; tool calls are never written to disk
/// (no functionCall/toolCall-like field), so there is nothing to map to activity(tool:).
/// cwd is resolved from the slug via projects.json; title = summary of the first real user message.
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
    private var lastContextPercent: [String: Double] = [:]

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
        // leeway lets the system coalesce wakeups to save power; must stay below the poll interval
        // (100ms for the 1s tier)
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

    /// Public so tests and launch can call it synchronously
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for url in recentChatFiles() {
            tail(url)
        }
    }

    // MARK: - File discovery

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

    // MARK: - Incremental reading

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // session resume may rewrite the whole file
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, url: url, replay: true)
        offsets[path] = offset + UInt64(consumed)
    }

    /// Processes complete lines (the trailing partial line is not consumed); returns bytes
    /// consumed. One JSON parse feeds both the lifecycle decoder and the side channel (gemini line
    /// tokens → ctx%).
    @discardableResult
    private func processLines(_ data: Data, url: URL, replay: Bool) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var ctx = context(for: url)
        var lastUsage: (model: String?, used: Int)?
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
            if let usage = contextUsage(root) { lastUsage = usage }
            if replay, let event = event(from: root, context: ctx) {
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[url.path] = ctx
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
        return complete.count
    }

    /// header / first real user message → context (sessionId / start time / title)
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

    /// Message line → lifecycle event
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

    /// Context-usage side channel for gemini lines: input + cached ≈ current context size (the full
    /// prompt incl. cache reads)
    private func contextUsage(_ root: [String: Any]) -> (model: String?, used: Int)? {
        guard let message = GeminiChatDecoder.parseMessage(root),
              message.type == "gemini",
              let tokens = message.tokens
        else { return nil }
        let used = tokens.input + tokens.cached
        return used > 0 ? (message.model, used) : nil
    }

    // MARK: - Context usage (gemini line tokens ÷ ContextWindows window)

    /// Same as the kimi/grok tailers: events are fresh as of emission (the stale gate would drop
    /// an expired contextUpdate), and only re-emitted on a change ≥0.5 to avoid flooding.
    /// TaskStore never creates a task for contextUpdate, and this only emits for tracked
    /// sessions, so no phantom tasks appear.
    private func emitContext(
        for chatURL: URL, context ctx: FileContext,
        usage: (model: String?, used: Int)
    ) {
        let percent = min(100, ContextWindows.percent(used: usage.used, model: usage.model))
        if let last = lastContextPercent[chatURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[chatURL.path] = percent
        HealthRegistry.shared.event(Self.healthName)
        handler(TaskEvent(
            source: .gemini, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// First-scan read limits: the first 64KB builds context (header / first real user message
    /// sit at the head), the last 256KB restores the "last state"; smaller files are read whole.
    /// Large transcripts are no longer loaded and parsed in full.
    private static let initialHeadBytes: UInt64 = 64 * 1024
    private static let initialTailBytes: UInt64 = 256 * 1024

    /// Newly discovered file: the first 64KB builds context (header on the first line, title near
    /// the head); the "last state" is restored only from the last 256KB, without replaying
    /// history. Still in progress (last user later than last gemini/error) → emit running;
    /// otherwise register as idle.
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        var ctx = context(for: url)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, used: Int)?

        /// Scans one chunk (partial lines at chunk edges are dropped), builds context and tracks
        /// the last started/finished
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
                guard let event = event(from: root, context: ctx) else { continue }
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

        if size <= Self.initialHeadBytes + Self.initialTailBytes {
            // Small files are read whole (a trailing partial JSON line simply fails to parse, as
            // the old whole-read did)
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
        // Tail tokens reflect the latest context usage (a gemini line means session state is
        // already registered, so this is safe)
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - Context

    private func context(for url: URL) -> FileContext {
        if let cached = contexts[url.path] { return cached }
        // slug = name of the directory above chats; cwd is resolved via projects.json
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
