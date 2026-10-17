import Foundation
import EurekaKit

/// Incrementally tails Kimi session events
/// (~/.kimi-code/sessions/<ws>/<session>/agents/main/wire.jsonl). Kimi has no hook/notify callback,
/// so this is the live channel (same as the grok/opencode tailers): poll recently written
/// main-agent wire.jsonl files, resume at the saved offset, never consume a partial line; newly
/// discovered files only restore their tail state without replaying history. Session id/cwd/title
/// come from the parent state.json (re-read when its mtime changes — Kimi only generates the title
/// after the first turn); context usage is estimated from the accumulated usage.record ÷
/// max_context_size in config.toml. Only the main agent's event stream is tailed (feeding subagent
/// wires line by line into the island would create phantom tasks; the usage scanner collects their
/// tokens separately). Subagents get a lightweight snapshot from KimiSubagentScanner (head + tail
/// window of each agents/<id>/wire.jsonl), emitted as .subagentsUpdated for running sessions on
/// each poll.
public final class KimiWireTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let sessionsRoot: URL
    private let configTomlURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.kimi-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        var modelAlias: String?
        var stateMtime: Date?
        /// Whether a turn is currently open (subagent snapshots are only scanned while running)
        var running = false
        /// Current turn start (taskStarted time): subagent snapshots are trimmed to this turn by it
        var turnStartedAt: Date?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    private var contextWindows: [String: Int]?  // config.toml max_context_size, lazily loaded
    /// Last subagent snapshot emitted per session (re-emitted only on change; TaskStore dedups
    /// again)
    private var lastSubagents: [String: [SubagentInfo]] = [:]

    static let healthName = "kimi 事件监视"

    public init(
        sessionsRoot: URL = KimiPaths.sessionsRoot(),
        configTomlURL: URL = KimiPaths.configToml(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.configTomlURL = configTomlURL
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
        for url in recentWireFiles() {
            tail(url)
        }
        emitSubagentUpdates()
    }

    // MARK: - File discovery

    /// sessions/<ws>/<session>/agents/main/wire.jsonl files written recently (within recentWindow)
    private func recentWireFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let wire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
                guard let values = try? wire.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                    let mtime = values.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(wire)
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
        // Refresh state.json even without new bytes (the title is generated after the first turn
        // and written after the wire append)
        refreshContextIfStateChanged(url)
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, url: url)
        offsets[path] = offset + UInt64(consumed)
    }

    /// Processes complete lines (the trailing partial line is not consumed); returns bytes
    /// consumed. One JSON parse feeds both the lifecycle decoder and the side channel (modelAlias /
    /// usage → ctx%).
    private func processLines(_ data: Data, url: URL) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var ctx = context(for: url)
        var lastUsage: (model: String?, usage: KimiWireDecoder.Usage)?
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            cursor = complete.index(after: lineEnd)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            // Side channel: model alias tracking (config.update / llm.request) + the latest usage
            if let alias = KimiWireDecoder.modelAlias(root) { ctx.modelAlias = alias }
            if let record = KimiWireDecoder.usageRecord(root) { lastUsage = record }
            let events = KimiWireDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd)
            for event in events {
                switch event.kind {
                case .taskStarted:
                    ctx.running = true
                    ctx.turnStartedAt = event.timestamp
                case .taskFinished:
                    ctx.running = false
                default:
                    break
                }
            }
            deliver(events, context: ctx)
        }
        contexts[url.path] = ctx
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
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
    /// - still in progress (last turn.prompt later than the last final-turn step.end): emit running
    /// - finished (or no turn records): register as idle via sessionStarted
    /// Both cases also emit the state.json title so the session card has a name.
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        var ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 65536)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, usage: KimiWireDecoder.Usage)?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = KimiWireDecoder.usageRecord(root) { lastUsage = record }
            for event in KimiWireDecoder.decode(
                root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

        // Running state and turn start: subagent snapshots are trimmed per turn and only scanned
        // while running
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
            // Still in progress: emit running (real start time, not suppressed as stale)
            var event = started
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        } else {
            // Finished / no turn records: register as an idle session (emitting finished directly
            // would race)
            let base = lastFinished ?? lastStarted ?? TaskEvent(
                source: .kimi, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd)
            var event = base
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - Subagent snapshots (head + tail window of agents/<id>/wire.jsonl, lightweight)

    /// Scans only tracked, running sessions (phantom-task invariant: never emit for an untracked
    /// session); emits only when the snapshot changes (TaskStore dedups again); clears the cache
    /// once idle so the next turn emits afresh.
    private func emitSubagentUpdates() {
        for (path, ctx) in contexts {
            guard ctx.running else {
                lastSubagents[path] = []
                continue
            }
            let sessionDir = Self.sessionDir(of: URL(fileURLWithPath: path))
            let subagents = KimiSubagentScanner.scan(
                sessionDir: sessionDir,
                turnStartedAt: ctx.turnStartedAt)
            guard subagents != (lastSubagents[path] ?? []) else { continue }
            lastSubagents[path] = subagents
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .kimi, sessionId: ctx.sessionId,
                kind: .subagentsUpdated(subagents),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt), false)
        }
    }

    // MARK: - Context usage (accumulated usage.record ÷ config.toml max_context_size)

    private func emitContext(
        for wireURL: URL, context ctx: FileContext,
        usage: (model: String?, usage: KimiWireDecoder.Usage)
    ) {
        let alias = usage.model ?? ctx.modelAlias
        guard let window = contextWindow(for: alias), window > 0 else { return }
        let percent = min(100, Double(usage.usage.total) / Double(window) * 100)
        // Only re-emit on change, to avoid flooding
        if let last = lastContextPercent[wireURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[wireURL.path] = percent
        handler(TaskEvent(
            source: .kimi, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    private func contextWindow(for modelAlias: String?) -> Int? {
        guard let modelAlias else { return nil }
        if contextWindows == nil { contextWindows = loadContextWindows() }
        return contextWindows?[modelAlias] ?? contextWindows?["*default*"]
    }

    /// config.toml → { "kimi-code/k3": max_context_size } (parsing lives in KimiConfigWindows)
    private func loadContextWindows() -> [String: Int] {
        KimiConfigWindows.parse(configURL: configTomlURL)
    }

    // MARK: - Session context (parent state.json, re-read on mtime change → title event)

    /// wire.jsonl → session directory (wire.jsonl ← main ← agents ← session_<uuid>)
    private static func sessionDir(of wireURL: URL) -> URL {
        wireURL
            .deletingLastPathComponent()  // main/
            .deletingLastPathComponent()  // agents/
            .deletingLastPathComponent()  // session_<uuid>/
    }

    private func context(for wireURL: URL) -> FileContext {
        let path = wireURL.path
        if let cached = contexts[path] { return cached }
        let ctx = readState(wireURL: wireURL, previous: nil)
        contexts[path] = ctx
        return ctx
    }

    /// state.json mtime changed → re-read; if the title changed (and is not the default) emit
    /// titleUpdate
    private func refreshContextIfStateChanged(_ wireURL: URL) {
        let path = wireURL.path
        guard let cached = contexts[path] else { return }
        let stateURL = Self.sessionDir(of: wireURL).appendingPathComponent("state.json")
        let mtime = (try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let mtime, mtime != cached.stateMtime else { return }
        let fresh = readState(wireURL: wireURL, previous: cached)
        contexts[path] = fresh
        if let title = fresh.title, !title.isEmpty, title != cached.title {
            handler(TaskEvent(
                source: .kimi, sessionId: fresh.sessionId,
                kind: .titleUpdate(title: title),
                timestamp: Date(), cwd: fresh.cwd,
                sessionStartedAt: fresh.sessionStartedAt), false)
        }
    }

    private func readState(wireURL: URL, previous: FileContext?) -> FileContext {
        let sessionDir = Self.sessionDir(of: wireURL)
        var ctx = FileContext(
            sessionId: sessionDir.lastPathComponent,
            cwd: previous?.cwd,
            sessionStartedAt: previous?.sessionStartedAt,
            title: previous?.title,
            modelAlias: previous?.modelAlias,
            stateMtime: previous?.stateMtime)

        let stateURL = sessionDir.appendingPathComponent("state.json")
        ctx.stateMtime = (try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return ctx }

        ctx.cwd = (root["workDir"] as? String) ?? ctx.cwd
        ctx.sessionStartedAt = (root["createdAt"] as? String)
            .flatMap(KimiWireDecoder.parseISO) ?? ctx.sessionStartedAt
        let rawTitle = (root["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The default title "New Session" is not a name (Kimi replaces it with a real title after
        // the first turn)
        if let rawTitle, !rawTitle.isEmpty, rawTitle != "New Session" {
            ctx.title = rawTitle
        }
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
