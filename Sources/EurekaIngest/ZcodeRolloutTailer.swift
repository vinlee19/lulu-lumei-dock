import Foundation
import EurekaKit
import EurekaStore

/// Incrementally tails the ZCode model IO log (~/.zcode/cli/rollout/model-io-sess_<id>.jsonl).
/// ZCode has no hook/notify callback, so this is the live channel (same idea as the grok/kimi
/// tailers): poll rollout files written recently, resume from the offset, never consume a
/// partial line; newly discovered files only recover the tail state, never replay history.
/// Session cwd is looked up lazily from the db's session table (directory column).
/// Subagent files (`model-io-sess_subagent_*`) are skipped: feeding them line by line into the
/// island would create phantom tasks; their tokens are collected separately by the usage
/// scanner, and ZcodeSubagentScanner snapshots their live state.
public final class ZcodeRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let rolloutRoot: URL
    private let dbPath: URL
    private let modelConfigURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.zcode-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    /// Session context (cwd looked up lazily from the db; cached so each poll doesn't open it)
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var dbMtime: Date?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    /// Per-model limit.context from v2/config.json (lazy; the authoritative ctx% denominator)
    private var contextWindows: [String: Int]?

    static let healthName = "zcode 事件监视"

    public init(
        rolloutRoot: URL = ZcodePaths.rolloutRoot(),
        dbPath: URL = ZcodePaths.db(),
        modelConfigURL: URL = ZcodePaths.modelConfig(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.rolloutRoot = rolloutRoot
        self.dbPath = dbPath
        self.modelConfigURL = modelConfigURL
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Leeway lets the system coalesce wakeups to save power; it must stay below the poll
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

    /// Public so tests and startup can call it synchronously
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for url in recentRolloutFiles() {
            tail(url)
        }
    }

    // MARK: - File discovery

    /// Log files under rollout/ written recently (within recentWindow) whose session id is
    /// not a subagent
    private func recentRolloutFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: rolloutRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var results: [URL] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let id = ZcodeRolloutDecoder.sessionId(fileName: url.lastPathComponent),
                  !id.contains("subagent")
            else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  now.timeIntervalSince(mtime) < recentWindow
            else { continue }
            results.append(url)
        }
        return results
    }

    // MARK: - Incremental reads

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // file truncated / rewritten
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, url: url)
        offsets[path] = offset + UInt64(consumed)
    }

    /// Processes complete lines (a trailing partial line is not consumed) and returns the bytes
    /// consumed. One JSON parse feeds both the lifecycle decoder and the usage side path (-> ctx%).
    private func processLines(_ data: Data, url: URL) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        let ctx = context(for: url)
        var lastUsage: (model: String?, usage: ZcodeRolloutDecoder.Usage)?
        var lastPrompt: String?
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            cursor = complete.index(after: lineEnd)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = ZcodeRolloutDecoder.usageRecord(root) {
                lastUsage = (record.model, record.usage)
            }
            if let prompt = ZcodeRolloutDecoder.userPromptText(root) { lastPrompt = prompt }
            for event in ZcodeRolloutDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                deliver(event)
            }
        }
        // No lifecycle event in this batch but new usage -> emit at least one heartbeat (the
        // model is running)
        if lastUsage != nil {
            deliver(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId, kind: .activity(tool: nil),
                timestamp: Date(), cwd: ctx.cwd))
        }
        if let prompt = lastPrompt.flatMap({ summarizeTitle($0) }) {
            deliver(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId,
                kind: .titleUpdate(title: prompt),
                timestamp: Date(), cwd: ctx.cwd))
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
        return complete.count
    }

    private func deliver(_ event: TaskEvent) {
        var enriched = event
        if enriched.cwd == nil, let key = eventKey(for: event.sessionId),
           let ctx = contexts[key] {
            enriched.cwd = ctx.cwd
        }
        HealthRegistry.shared.event(Self.healthName)
        let isStale = Date().timeIntervalSince(enriched.timestamp) > staleThreshold
        handler(enriched, isStale)
    }

    /// Newly discovered file: recover the "last state" from the tail --
    /// - last completed record is a tool-calls intermediate step (no final stop): emit running
    /// - a final turn exists (stop/error): register as an idle session
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        let ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 262_144)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastEvent: TaskEvent?
        var finished: TaskEvent?
        var lastUsage: (model: String?, usage: ZcodeRolloutDecoder.Usage)?
        var lastPrompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = ZcodeRolloutDecoder.usageRecord(root) {
                lastUsage = (record.model, record.usage)
            }
            if let prompt = ZcodeRolloutDecoder.userPromptText(root) { lastPrompt = prompt }
            for event in ZcodeRolloutDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                lastEvent = event
                if case .taskFinished = event.kind { finished = event }
            }
        }

        func titleEvent(from base: TaskEvent) {
            guard let title = lastPrompt.flatMap({ summarizeTitle($0) }) else { return }
            var event = base
            event.kind = .titleUpdate(title: title)
            handler(event, false)
        }

        if let finished {
            var event = finished
            event.kind = .sessionStarted  // already over: register as idle (emitting finished directly would race)
            event.cwd = event.cwd ?? ctx.cwd
            handler(event, false)
            titleEvent(from: event)
        } else if let last = lastEvent {
            var event = last
            event.cwd = event.cwd ?? ctx.cwd
            handler(event, false)  // intermediate step -> running
            titleEvent(from: event)
        } else {
            handler(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd), false)
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - Context usage (usage.total ÷ per-model limit.context from config.json)

    private func emitContext(
        for url: URL, context ctx: FileContext,
        usage: (model: String?, usage: ZcodeRolloutDecoder.Usage)
    ) {
        if contextWindows == nil {
            contextWindows = ZcodeConfigWindows.parse(configURL: modelConfigURL)
        }
        // The window is the request model's value in config; not found (custom provider with
        // no limit configured) -> emit nothing
        guard let window = usage.model.flatMap({ contextWindows?[$0] }), window > 0
        else { return }
        let percent = min(100, Double(usage.usage.total) / Double(window) * 100)
        // Emit only on change, to avoid flooding
        if let last = lastContextPercent[url.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[url.path] = percent
        handler(TaskEvent(
            source: .zcode, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd), false)
    }

    // MARK: - Session context (cwd looked up lazily, once, from db.session)

    private func eventKey(for sessionId: String) -> String? {
        // Reverse lookup: contexts is keyed by file path, so match on sessionId here (one file
        // per session)
        contexts.first { $0.value.sessionId == sessionId }?.key
    }

    private func context(for url: URL) -> FileContext {
        let path = url.path
        if let cached = contexts[path] { return cached }
        let sessionId = ZcodeRolloutDecoder.sessionId(fileName: url.lastPathComponent) ?? path
        var ctx = FileContext(sessionId: sessionId, cwd: nil, dbMtime: nil)
        // Lazy db lookup: directory column (no db / no such row -> cwd stays empty and the
        // island shows the short id)
        if let db = try? SQLiteDB(path: dbPath.path, readOnly: true) {
            let rows = (try? db.query(
                "SELECT directory FROM session WHERE id = ?", [.text(sessionId)]) { $0.text(0) }) ?? []
            ctx.cwd = rows.first ?? nil
        }
        contexts[path] = ctx
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
