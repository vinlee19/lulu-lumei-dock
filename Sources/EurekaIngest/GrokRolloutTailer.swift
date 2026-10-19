import Foundation
import EurekaKit

/// Incrementally tails grok session events (~/.grok/sessions/<enc-cwd>/<uuid>/events.jsonl).
/// grok has no hook/notify callback, so this is the live channel (same as the opencode/Codex
/// tailers): poll recently written events.jsonl files, resume at the saved offset, never consume
/// a partial line; newly discovered files only restore their tail state without replaying
/// history. Session id/cwd/title come from the sibling summary.json; context usage is estimated
/// from the sibling updates.jsonl totalTokens ÷ the model's context_window.
public final class GrokRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let sessionsRoot: URL
    private let modelsCacheURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.grok-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        var modelId: String?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    private var contextWindows: [String: Int]?  // models_cache.json, lazily loaded

    static let healthName = "grok 事件监视"

    public init(
        sessionsRoot: URL = GrokPaths.sessionsRoot(),
        modelsCacheURL: URL = GrokPaths.modelsCache(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.modelsCacheURL = modelsCacheURL
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
        for url in recentEventFiles() {
            tail(url)
        }
    }

    // MARK: - File discovery

    /// sessions/<enc-cwd>/<uuid>/events.jsonl files written recently (within recentWindow).
    /// The top-level session_search.sqlite and the cwd-level prompt_history.jsonl are not
    /// directories, so they are skipped naturally.
    private func recentEventFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let events = sessionDir.appendingPathComponent("events.jsonl")
                guard let values = try? events.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                    let mtime = values.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(events)
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
        if size < offset { offset = 0 }  // file was truncated/rewritten
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let ctx = context(for: url)
        let consumed = processLines(data, context: ctx)
        offsets[path] = offset + UInt64(consumed)
        if consumed > 0 { emitContext(for: url, context: ctx) }
    }

    /// Processes complete lines (the trailing partial line is not consumed); returns bytes consumed
    private func processLines(_ data: Data, context: FileContext) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            if !line.isEmpty {
                deliver(
                    GrokEventDecoder.decode(
                        line: Data(line), sessionId: context.sessionId, cwd: context.cwd),
                    context: context)
            }
            cursor = complete.index(after: lineEnd)
        }
        return complete.count
    }

    private func deliver(_ events: [TaskEvent], context: FileContext) {
        for var event in events {
            event.sessionStartedAt = context.sessionStartedAt
            HealthRegistry.shared.event(Self.healthName)
            let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
            handler(event, isStale)
        }
    }

    /// Newly discovered file: restore the "last state" from the tail —
    /// - still in progress (last turn_started later than last turn_ended): emit running
    /// - finished (or no turn records): register as idle via sessionStarted
    /// Both cases also emit the summary.json title so the session card has a name.
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

        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            for event in GrokEventDecoder.decode(
                line: Data(line), sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

        func titleEvent(from base: TaskEvent) {
            guard let title = ctx.title, !title.isEmpty else { return }
            var event = base
            event.kind = .titleUpdate(title: title)
            handler(event, false)
        }

        if let started = lastStarted,
           lastFinished.map({ $0.timestamp < started.timestamp }) ?? true {
            // Still in progress: emit running (real start time, not suppressed as stale)
            var event = started
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        } else {
            // Finished / no turn records: register as an idle session (emitting finished directly
            // would race)
            let base = lastFinished ?? lastStarted ?? TaskEvent(
                source: .grok, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd)
            var event = base
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
        emitContext(for: url, context: ctx)
    }

    // MARK: - Context usage (updates.jsonl totalTokens ÷ model window)

    private func emitContext(for eventsURL: URL, context ctx: FileContext) {
        guard let window = contextWindow(for: ctx.modelId), window > 0,
              let tokens = latestTotalTokens(sessionDir: eventsURL.deletingLastPathComponent())
        else { return }
        let percent = min(100, Double(tokens) / Double(window) * 100)
        // Only re-emit on change, to avoid flooding
        if let last = lastContextPercent[eventsURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[eventsURL.path] = percent
        handler(TaskEvent(
            source: .grok, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// Reads the tail of updates.jsonl and takes the latest `_meta.totalTokens`
    private func latestTotalTokens(sessionDir: URL) -> Int? {
        let updates = sessionDir.appendingPathComponent("updates.jsonl")
        guard let size = fileSize(updates.path), size > 0,
              let handle = FileHandle(forReadingAtPath: updates.path)
        else { return nil }
        defer { try? handle.close() }
        let tailLength = min(size, 16384)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var latest: Int?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any],
                  let params = root["params"] as? [String: Any],
                  let meta = params["_meta"] as? [String: Any],
                  let total = meta["totalTokens"] as? Int
            else { continue }
            latest = total
        }
        return latest
    }

    private func contextWindow(for modelId: String?) -> Int? {
        guard let modelId else { return nil }
        if contextWindows == nil { contextWindows = loadContextWindows() }
        return contextWindows?[modelId] ?? contextWindows?["*default*"]
    }

    /// models_cache.json → { modelId: context_window } (lazily loaded once)
    private func loadContextWindows() -> [String: Int] {
        var map: [String: Int] = ["*default*": 256000]
        guard let data = try? Data(contentsOf: modelsCacheURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let models = root["models"] as? [String: Any]
        else { return map }
        for (id, value) in models {
            guard let entry = value as? [String: Any],
                  let info = entry["info"] as? [String: Any],
                  let window = info["context_window"] as? Int
            else { continue }
            map[id] = window
        }
        return map
    }

    // MARK: - Context (sibling summary.json)

    private func context(for eventsURL: URL) -> FileContext {
        let path = eventsURL.path
        if let cached = contexts[path] { return cached }

        let sessionDir = eventsURL.deletingLastPathComponent()
        // Directory name (uuid) is the fallback session id, matching session_id in
        // active_sessions.json
        var ctx = FileContext(
            sessionId: sessionDir.lastPathComponent, cwd: nil,
            sessionStartedAt: nil, title: nil, modelId: nil)

        let summary = sessionDir.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summary),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any] {
            if let info = root["info"] as? [String: Any] {
                if let id = info["id"] as? String, !id.isEmpty { ctx.sessionId = id }
                ctx.cwd = info["cwd"] as? String
            }
            ctx.cwd = ctx.cwd ?? (root["cwd"] as? String)
            ctx.sessionStartedAt = GrokEventDecoder.parseDate(root["created_at"] as? String)
            ctx.title = (root["generated_title"] as? String)
                ?? (root["session_summary"] as? String)
            ctx.modelId = root["current_model_id"] as? String
        }
        contexts[path] = ctx
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
