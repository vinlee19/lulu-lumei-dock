import Foundation
import EurekaKit

/// Incrementally tails Codex rollout files (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl).
/// A resumed old session appends in place under its creation-date directory (mtime refreshes,
/// no new dated directory), so each tick enumerates the whole date tree and only tails files
/// whose mtime falls inside recentWindow (tracked files are always tailed). Reads resume from
/// the offset and leave a trailing partial line unconsumed. Newly discovered files are streamed
/// to find the last lifecycle state without replaying intermediate history to the UI.
public final class CodexRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void
    public typealias RateLimitHandler = (RateLimitSnapshot) -> Void

    /// Defaults to ~/.codex/sessions; override with EUREKA_CODEX_SESSIONS (for tests)
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
    private let sessionIndexURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
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
    private var threadNames: [String: String] = [:]
    private var loadedThreadNames = false
    /// mtime+size fingerprint of session_index.jsonl; skip re-parsing the whole file if unchanged
    private var sessionIndexFingerprint: (mtime: TimeInterval, size: UInt64)?

    public init(
        sessionsRoot: URL,
        sessionIndexURL: URL? = nil,
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        rateLimitHandler: RateLimitHandler? = nil,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.sessionIndexURL = sessionIndexURL
            ?? CodexThreadNameIndex.resolvedURL(for: sessionsRoot)
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.rateLimitHandler = rateLimitHandler
        self.handler = handler
    }

    static let healthName = "Codex rollout 监视"

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

    /// Public for tests and for the synchronous call at launch
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        refreshThreadNames()
        for url in recentRolloutFiles() {
            tail(url)
        }
    }

    /// session_index.jsonl is the append-only index of official thread names; on change, emit
    /// titleUpdate for active tasks. The per-second poll compares the mtime+size fingerprint first
    /// (a cheap stat) and only rereads the whole file when it really changed.
    private func refreshThreadNames() {
        let attrs = try? FileManager.default.attributesOfItem(atPath: sessionIndexURL.path)
        let fingerprint = attrs.flatMap { dict -> (mtime: TimeInterval, size: UInt64)? in
            guard let mtime = (dict[.modificationDate] as? Date)?.timeIntervalSince1970,
                  let size = dict[.size] as? UInt64
            else { return nil }
            return (mtime, size)
        }
        // Same fingerprint (including a file that stays missing) → no re-parse needed
        if loadedThreadNames, fingerprint?.mtime == sessionIndexFingerprint?.mtime,
           fingerprint?.size == sessionIndexFingerprint?.size {
            return
        }
        sessionIndexFingerprint = fingerprint

        let latest = CodexThreadNameIndex.load(sessionIndexURL)
        if loadedThreadNames {
            for (sessionId, name) in latest where threadNames[sessionId] != name {
                handler(TaskEvent(
                    source: .codex,
                    sessionId: sessionId,
                    kind: .titleUpdate(title: name),
                    timestamp: Date()
                ), false)
            }
        }
        threadNames = latest
        loadedThreadNames = true
    }

    // MARK: - File discovery

    /// Enumerates rollout files across every date directory but only tails those whose mtime
    /// falls inside recentWindow. A resumed old session appends in place under its creation-date
    /// directory and refreshes its mtime, so the mtime filter never misses a re-activated session;
    /// files already tracked in offsets ignore the window and are always tailed. Cold history only
    /// costs a directory listing + stat per tick.
    private func recentRolloutFiles(now: Date = Date()) -> [URL] {
        CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot).compactMap { entry in
            if offsets[entry.url.path] != nil { return entry.url }
            guard let mtime = entry.mtime, now.timeIntervalSince(mtime) < recentWindow
            else { return nil }
            return entry.url
        }
    }

    // MARK: - Incremental reads

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // file truncated/rewritten
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, context: context(for: url))
        offsets[path] = offset + UInt64(consumed)
    }

    /// Processes complete lines (the trailing partial line is left for the next poll); returns
    /// bytes consumed
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
                break  // context was built when the file was discovered
            case .event(var event):
                event.sessionStartedAt = context.sessionStartedAt
                switch event.kind {
                case .titleUpdate(let title):
                    threadNames[event.sessionId] = title
                case .taskStarted:
                    if let name = threadNames[event.sessionId] {
                        event.kind = .taskStarted(title: name)
                    }
                case .taskFinished(let outcome, _, let detail):
                    if let name = threadNames[event.sessionId] {
                        event.kind = .taskFinished(outcome: outcome, title: name, detail: detail)
                    }
                default:
                    break
                }
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            case .rateLimits(let snapshot):
                rateLimitHandler?(snapshot)
            case .tokenUsage:
                break  // consumed by the M5 usage engine
            }
        }
    }

    /// Newly discovered file: read the full first line to build context, then stream through to
    /// recover the "last state":
    /// - still in progress (last task_started later than last task_complete): emit a running event
    /// - finished (last task_complete later than last task_started): emit a finished event so a
    ///   recently finished task still gets its card (past staleThreshold it only goes to history,
    ///   no island)
    /// No fixed tail window: a long turn's latest prompt can easily sit before the last 64KB.
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        let ctx = context(for: url)

        var lastStartedEvent: TaskEvent?
        var lastFinishedEvent: TaskEvent?
        var lastTitle: String?
        var lastRateLimits: RateLimitSnapshot?
        let consumed = CodexJSONLReader.forEachCompleteLine(url) { line in
            for item in CodexRolloutDecoder.decode(
                line: line, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch item {
                case .event(let event):
                    switch event.kind {
                    case .taskStarted(let title) where title != nil:
                        lastTitle = title
                    case .taskStarted:
                        lastStartedEvent = event
                    case .taskFinished:
                        lastFinishedEvent = event
                    case .titleUpdate(let title):
                        lastTitle = title
                        threadNames[event.sessionId] = title
                    default:
                        break
                    }
                case .rateLimits(let snapshot):
                    lastRateLimits = snapshot
                case .sessionMeta, .tokenUsage:
                    break
                }
            }
            return true
        }
        // Leave the partial line unconsumed; reread from its start once the append completes.
        offsets[path] = min(consumed, size)

        if let snapshot = lastRateLimits {
            rateLimitHandler?(snapshot)
        }

        let resolvedTitle = threadNames[ctx.sessionId] ?? lastTitle

        if let started = lastStartedEvent {
            if let finished = lastFinishedEvent, finished.timestamp >= started.timestamp {
                // Task already finished: register it as idle via sessionStarted (the notify channel
                // owns the notice card). Avoid taskFinished: with no existing task in the store,
                // idle cannot be established; it also avoids duplicate cards or a race with the
                // dedup window.
                var ev = started
                ev.kind = .sessionStarted
                ev.sessionStartedAt = ctx.sessionStartedAt
                handler(ev, false)
                if let title = resolvedTitle {
                    var titleEv = ev
                    titleEv.kind = .titleUpdate(title: title)
                    handler(titleEv, false)
                }
            } else {
                // Still in progress: emit running (not suppressed as stale; timestamp is the real
                // start time)
                var event = started
                event.sessionStartedAt = ctx.sessionStartedAt
                if let title = resolvedTitle { event.kind = .taskStarted(title: title) }
                handler(event, false)
            }
        } else if let finished = lastFinishedEvent {
            // Tail window has no task_started (very long session) but the task has finished:
            // register idle too
            var ev = finished
            ev.kind = .sessionStarted
            ev.sessionStartedAt = ctx.sessionStartedAt
            handler(ev, false)
            if let title = resolvedTitle {
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
        // The first line should be session_meta; current Codex puts instructions on the same line,
        // often over 16KB.
        CodexJSONLReader.forEachCompleteLine(url) { line in
            let decoded = CodexRolloutDecoder.decode(
                line: line, sessionId: ctx.sessionId, cwd: nil)
            for case .sessionMeta(let id, let cwd, let startedAt) in decoded {
                ctx = FileContext(sessionId: id, cwd: cwd, sessionStartedAt: startedAt)
            }
            return false
        }
        contexts[path] = ctx
        return ctx
    }

    /// rollout-2026-06-08T23-36-02-<uuid>.jsonl → uuid as fallback
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
