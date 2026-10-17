import EurekaKit
import Foundation

/// Tails Cursor's session transcripts
/// `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`.
///
/// This is Cursor's **second** live channel, with a clear split of duties versus
/// `CursorStateTailer` (which polls `state.vscdb`):
///   - the transcript has an **explicit `turn_ended`**, so finishing doesn't need the DB side's
///     "status settles + watermark stops moving" debounce (the DB writes `aborted` and then
///     `completed` for the same turn);
///   - the transcript has **no** tokens / ctx% / todos / child sessions; only the DB has those.
/// So: **once a composer has a transcript file, this tailer owns its lifecycle events exclusively**
/// and the DB side yields (see `transcriptOwned` in `CursorStateTailer`), still supplying ctx% and
/// child sessions. Both sides use composerId as the sessionId, so after yielding there are never
/// two cards or two history rows.
///
/// ⚠️ Transcripts only cover turns after this feature shipped (observed: writing started in
/// 3.13.10); historical sessions have none → it can never replace the DB channel, only layer on top
/// of it.
public final class CursorTranscriptTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private struct FileContext {
        var composerId: String
        var cwd: String?
        var title: String?
        var running = false
    }

    private let cliHome: URL
    private let workspaceStorageRoot: URL
    private let staleThreshold: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.cursor-transcript")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private var contexts: [String: FileContext] = [:]

    static let healthName = "Cursor 转录监视"

    public init(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        staleThreshold: TimeInterval = 300,
        handler: @escaping Handler
    ) {
        self.cliHome = cliHome
        self.workspaceStorageRoot = workspaceStorageRoot
        self.staleThreshold = staleThreshold
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
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
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        for entry in CursorTranscriptIndex.entries(
            cliHome: cliHome, workspaceStorageRoot: workspaceStorageRoot, now: now) {
            tail(entry, now: now)
        }
    }

    private func tail(_ entry: CursorTranscriptIndex.Entry, now: Date) {
        let path = entry.url.path
        guard let size = fileSize(path) else { return }
        // Take it out, modify it, then write it back whole: never write it as
        // `contexts[path]?.cwd = entry.cwd ?? contexts[path]?.cwd` ——
        // The left side is an exclusive modifying access to the dictionary while the right side
        // reads the same key; the overlapping access makes Swift abort outright. (`??`
        // short-circuits when cwd is non-nil, so only cwd-less sessions like empty-window blow up,
        // and tests always had a non-nil cwd, so they missed this path.)
        var stored = contexts[path] ?? FileContext(composerId: entry.composerId, cwd: entry.cwd)
        if let cwd = entry.cwd { stored.cwd = cwd }
        contexts[path] = stored

        guard var offset = offsets[path] else {
            initialScan(entry, size: size, now: now)
            return
        }
        if size < offset { offset = 0 }  // Rewritten wholesale (same session reopened) → start over
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
            let data = try? handle.readToEnd(), !data.isEmpty
        else { return }
        // Don't consume a partial line: the line Cursor is still writing is only complete next pass
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        let complete = data[data.startIndex...lastNewline]

        var ctx = contexts[path] ?? FileContext(composerId: entry.composerId, cwd: entry.cwd)
        for line in complete.split(separator: UInt8(ascii: "\n")) {
            guard var event = CursorTranscriptDecoder.decode(
                line: Data(line), sessionId: ctx.composerId, cwd: ctx.cwd) else { continue }
            switch event.kind {
            case .taskStarted(let title):
                ctx.running = true
                if let title { ctx.title = title }
            case .taskFinished(let outcome, _, let detail):
                ctx.running = false
                // The finishing line carries no title; attach this turn's prompt summary so history
                // shows what the turn did
                event.kind = .taskFinished(outcome: outcome, title: ctx.title, detail: detail)
            default:
                break
            }
            HealthRegistry.shared.event(Self.healthName)
            handler(event, now.timeIntervalSince(event.timestamp) > staleThreshold)
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
    }

    /// First sight of a transcript file: only set the watermark, **never replay history**.
    /// The one exception is "the file exists but this turn hasn't finished": the app launched
    /// mid-turn, so post a running card, or the island shows nothing for this turn until it ends.
    private func initialScan(_ entry: CursorTranscriptIndex.Entry, size: UInt64, now: Date) {
        let path = entry.url.path
        offsets[path] = size
        var ctx = FileContext(composerId: entry.composerId, cwd: entry.cwd)
        defer { contexts[path] = ctx }

        guard let handle = FileHandle(forReadingAtPath: path),
            let data = try? handle.readToEnd()
        else { return }
        try? handle.close()

        var lastKind: TaskEvent.Kind?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let event = CursorTranscriptDecoder.decode(
                line: Data(line), sessionId: ctx.composerId, cwd: ctx.cwd) else { continue }
            if case .taskStarted(let title) = event.kind, let title { ctx.title = title }
            lastKind = event.kind
        }
        guard let lastKind else { return }
        if case .taskFinished = lastKind { return }  // Historical turn already finished: stay silent

        // Launched mid-turn: this turn is still running
        ctx.running = true
        HealthRegistry.shared.event(Self.healthName)
        handler(
            TaskEvent(
                source: .cursor, sessionId: ctx.composerId,
                kind: .taskStarted(title: ctx.title), timestamp: now, cwd: ctx.cwd),
            false)
    }

    private func fileSize(_ path: String) -> UInt64? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        return UInt64(info.st_size)
    }
}
