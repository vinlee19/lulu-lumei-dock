import EurekaKit
import Foundation

/// Incrementally tails Qoder sessions (~/.qoder-cn/projects/<slug>/<sessionId>.jsonl).
/// Qoder has no hook/notify callback, so this is the live channel (same as the qwen/kimi tailers).
/// Lifecycle mapping: human user message → taskStarted; assistant text → taskFinished(success);
/// assistant tool_use → activity(tool name); custom-title/ai-title → titleUpdate.
/// Only top-level projects/*/*.jsonl files are watched; subagents are not followed line by line —
/// a snapshot scan (same layout as Claude, reusing ClaudeSubagentScanner) emits
/// .subagentsUpdated for running sessions on each poll.
/// ⚠️ The CN backend reports zero token usage everywhere, so there is no usage scanning.
public final class QoderChatTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.qoder-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        /// custom-title has top priority: once a custom title is seen, ai-title no longer overrides
        /// it
        var titleIsCustom = false
        /// Whether a turn is currently open (subagent snapshots are only scanned while running)
        var running = false
        /// Current turn start (taskStarted time): subagent snapshots are trimmed to this turn by it
        var turnStartedAt: Date?
    }
    private var contexts: [String: FileContext] = [:]
    /// Last subagent snapshot emitted per session (re-emitted only on change; TaskStore dedups
    /// again)
    private var lastSubagents: [String: [SubagentInfo]] = [:]

    static let healthName = "qoder 事件监视"

    public init(
        projectsRoot: URL = QoderPaths.projectsRoot(),
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
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
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
        emitSubagentUpdates()
    }

    /// Top-level projects/*/*.jsonl files (the subagents/ subdirectory is not recursed)
    private func recentChatFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for projectDir in projectDirs
        where (try? projectDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
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
        if size < offset { offset = 0 }  // session resume may rewrite the whole file
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
                switch event.kind {
                case .taskStarted:
                    ctx.running = true
                    ctx.turnStartedAt = event.timestamp
                case .taskFinished:
                    ctx.running = false
                default:
                    break
                }
                HealthRegistry.shared.event(Self.healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
    }

    private func absorb(_ root: [String: Any], into ctx: inout FileContext) {
        if ctx.cwd == nil { ctx.cwd = QoderTranscriptDecoder.cwd(root) }
        if ctx.sessionStartedAt == nil { ctx.sessionStartedAt = QoderTranscriptDecoder.timestamp(root) }
        if let (isCustom, title) = QoderTranscriptDecoder.titleLine(root) {
            // custom-title wins: once customized, ai-title does not override
            if isCustom || !ctx.titleIsCustom {
                ctx.title = title
                ctx.titleIsCustom = isCustom
            }
        } else if ctx.title == nil, let text = QoderTranscriptDecoder.userPromptText(root) {
            ctx.title = summarizeTitle(text)
        }
    }

    private func event(from root: [String: Any], context ctx: FileContext) -> TaskEvent? {
        guard var event = QoderTranscriptDecoder.decode(
            root: root, sessionId: ctx.sessionId, cwd: ctx.cwd)
        else { return nil }
        switch event.kind {
        case .taskFinished(let outcome, _, let detail):
            // The finish carries the current best title (custom > ai > first prompt)
            event.kind = .taskFinished(outcome: outcome, title: ctx.title, detail: detail)
        case .titleUpdate(let title):
            // After a custom-title has been seen, an ai-title titleUpdate is a downgrade; drop it
            if ctx.titleIsCustom && title != ctx.title { return nil }
        default:
            break
        }
        event.sessionStartedAt = ctx.sessionStartedAt
        return event
    }

    /// Newly discovered file: read only the first 64KB to build context (cwd/start time/title are
    /// mostly at the head) + the last 256KB to restore the "last state", without replaying
    /// history; small files (≤320KB) are read in one go.
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        let headLength: UInt64 = 65536
        let tailLength: UInt64 = 256 * 1024
        var chunks: [Data] = []
        if size <= headLength + tailLength {
            guard let data = try? handle.readToEnd() else { return }
            chunks = [data]
        } else {
            // The head only builds context; a possible trailing partial line is simply dropped
            guard let head = try? handle.read(upToCount: Int(headLength)) else { return }
            if let lastNewline = head.lastIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(head[head.startIndex...lastNewline]))
            }
            // The tail start may land mid-line; align to just after the first newline
            guard (try? handle.seek(toOffset: size - tailLength)) != nil,
                  let tail = try? handle.readToEnd()
            else { return }
            if let firstNewline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(tail[tail.index(after: firstNewline)...]))
            }
        }

        var ctx = context(for: url)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        for chunk in chunks {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
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

    // MARK: - Subagent snapshots (reuses the Claude scanner; same on-disk layout)

    /// Scans only tracked, running sessions (phantom-task invariant: never emit for an untracked
    /// session); emits only when the snapshot changes (TaskStore dedups again); clears the cache
    /// once idle so the next turn emits afresh.
    private func emitSubagentUpdates() {
        for (path, ctx) in contexts {
            guard ctx.running else {
                lastSubagents[path] = []
                continue
            }
            let file = URL(fileURLWithPath: path)
            let subagents = ClaudeSubagentScanner.scan(
                sessionDir: file.deletingPathExtension(),
                parentTranscript: file,
                turnStartedAt: ctx.turnStartedAt)
            guard subagents != (lastSubagents[path] ?? []) else { continue }
            lastSubagents[path] = subagents
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .qoder, sessionId: ctx.sessionId,
                kind: .subagentsUpdated(subagents),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt), false)
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
