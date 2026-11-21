import EurekaKit
import Foundation

/// Incrementally tails CodeBuddy sessions (~/.codebuddy/projects/<cwd-slug>/<sessionId>.jsonl).
/// CodeBuddy has no hook/notify callback, so this is the live channel (same as the qwen/kimi
/// tailers).
/// Only top-level session files are read; `<sessionId>/subagents/` is not tailed (subagent tokens
/// are merged by CodeBuddyUsageScanner and the event stream follows the main session). Live
/// subagent state is a CodeBuddySubagentScanner snapshot (derived from the parent transcript's
/// function_call/result pairs), emitted as .subagentsUpdated on each poll for running sessions.
/// Lifecycle mapping (CodeBuddyTranscriptDecoder): user message (not skipRun) → taskStarted;
/// function_call → activity(tool name); assistant completed → taskFinished(success);
/// ai-title/summary → titleUpdate (only retitles existing tasks, never creates phantom tasks).
/// Context usage: the normalized usage on function_call lines (reusing the decoder's usage
/// extraction; input + cacheRead ≈ current context size) ÷ the ContextWindows window.
///
/// The same tailer runs WorkBuddy (`dialect: .workbuddy`, `~/.workbuddy/projects`), which embeds
/// this engine. Its differences: turn rules from `CodeBuddyDialect`; an AskUserQuestion call waits
/// for input; `lookup` reads WorkBuddy's own database for the title, the session's real context
/// window and whether it is a scheduled automation run. Automation runs and WorkBuddy's internal
/// host / warm-up sessions are excluded: they emit no event at all, because TaskStore registers a
/// task for any activity or waiting event of a session it doesn't know.
public final class CodeBuddyChatTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let dialect: CodeBuddyDialect
    private let lookup: CodeBuddySessionLookup?
    private let healthName: String
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        /// Title source priority: ai-title(2) > summary(1) > first user text(0); higher wins
        var titleRank: Int = -1
        /// Whether there is an unfinished turn (subagent snapshots are only scanned while running)
        var running = false
        /// Start of the current turn (taskStarted time); subagent snapshots are clipped to it
        var turnStartedAt: Date?
        /// The product's database knows the session's context window (WorkBuddy)
        var contextWindow: Int?
        /// Scheduled automation run / internal session: tracked for offsets, never emitted
        var excluded = false
        /// Whether `excluded` is settled (by the database, the id, or the first prompt)
        var exclusionDecided = false
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    /// Last subagent snapshot emitted per session (re-emitted on change; TaskStore dedups again)
    private var lastSubagents: [String: [SubagentInfo]] = [:]

    /// Health-registry key per product (stable keys, displayed through `L10n.healthTitle`)
    static func healthName(for dialect: CodeBuddyDialect) -> String {
        switch dialect {
        case .codebuddyCode: return "codebuddy 事件监视"
        case .workbuddy: return "workbuddy 事件监视"
        }
    }

    public init(
        projectsRoot: URL = CodeBuddyPaths.projectsRoot(),
        dialect: CodeBuddyDialect = .codebuddyCode,
        lookup: CodeBuddySessionLookup? = nil,
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.projectsRoot = projectsRoot
        self.dialect = dialect
        self.lookup = lookup
        self.healthName = Self.healthName(for: dialect)
        self.queue = DispatchQueue(label: "com.vinlee.eureka.\(dialect.source.rawValue)-tailer")
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(healthName, expectedInterval: pollInterval)
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

    /// Public for tests and for the synchronous call at launch
    public func scanOnce() {
        HealthRegistry.shared.beat(healthName)
        for url in recentSessionFiles() {
            tail(url)
        }
        emitSubagentUpdates()
    }

    /// Top-level projects/<slug>/*.jsonl files (does not descend into <sessionId>/subagents/)
    private func recentSessionFiles(now: Date = Date()) -> [URL] {
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
        if size < offset { offset = 0 }  // a session resume may rewrite the whole file
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
            if let event = event(from: root, context: ctx) {
                switch event.kind {
                case .taskStarted:
                    ctx.running = true
                    ctx.turnStartedAt = event.timestamp
                    refreshHints(into: &ctx)
                case .taskFinished:
                    ctx.running = false
                    refreshHints(into: &ctx)
                default:
                    break
                }
                guard !ctx.excluded else { continue }
                HealthRegistry.shared.event(healthName)
                let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
                handler(event, isStale)
            }
        }
        contexts[path] = ctx
        offsets[path] = offset + UInt64(complete.count)
        if let lastUsage, !ctx.excluded {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    private func absorb(_ root: [String: Any], into ctx: inout FileContext) {
        if ctx.cwd == nil { ctx.cwd = root["cwd"] as? String }
        if ctx.sessionStartedAt == nil {
            ctx.sessionStartedAt = CodeBuddyTranscriptDecoder.timestamp(root)
        }
        // WorkBuddy scheduled runs: settled by the database when it knows the session, otherwise
        // by the first prompt, which wraps the query in <automation_system_reminder>
        if dialect == .workbuddy, !ctx.exclusionDecided, dialect.startsTurn(root) {
            ctx.excluded = CodeBuddyDialect.inputText(root)?
                .contains(CodeBuddyDialect.automationPromptMarker) == true
            ctx.exclusionDecided = true
        }
        // Title priority: database title (3) > ai-title / session-meta (2) > summary (1) > first
        // user text (0)
        switch root["type"] as? String {
        case "ai-title", "summary", "session-meta":
            let rank = CodeBuddyTranscriptDecoder.titleRank(root)
            // CodeBuddy keeps the first title of a rank; WorkBuddy's session-meta is a timeline
            // whose newest entry is the current title
            let replaces = dialect == .workbuddy ? rank >= ctx.titleRank : rank > ctx.titleRank
            if replaces, let title = CodeBuddyTranscriptDecoder.title(root, dialect: dialect) {
                ctx.title = title
                ctx.titleRank = rank
            }
        case "message":
            if ctx.titleRank < 0,
               let text = CodeBuddyTranscriptDecoder.userText(root, dialect: dialect),
               let title = summarizeTitle(text) {
                ctx.title = title
                ctx.titleRank = 0
            }
        default:
            break
        }
    }

    /// Reads the product's own record of the session (WorkBuddy's database): the title it shows,
    /// the context window and the automation flag. Called when a file is first seen and at turn
    /// boundaries, not on every poll. A failed or missing read leaves everything as it was.
    private func refreshHints(into ctx: inout FileContext) {
        guard let hints = lookup?(ctx.sessionId) else { return }
        if let isAutomation = hints.isAutomation, !ctx.exclusionDecided {
            ctx.excluded = isAutomation
            ctx.exclusionDecided = true
        }
        if let title = hints.title.flatMap({ summarizeTitle($0) }) {
            ctx.title = title
            ctx.titleRank = 3
        }
        if let window = hints.contextWindow, window > 0 { ctx.contextWindow = window }
    }

    private func event(from root: [String: Any], context ctx: FileContext) -> TaskEvent? {
        guard var event = CodeBuddyTranscriptDecoder.decode(
            root: root, sessionId: ctx.sessionId, cwd: ctx.cwd, dialect: dialect)
        else { return nil }
        // taskFinished gets its title from the context (the line carries none)
        if case .taskFinished(let outcome, nil, let detail) = event.kind {
            event.kind = .taskFinished(outcome: outcome, title: ctx.title, detail: detail)
        }
        event.sessionStartedAt = ctx.sessionStartedAt
        return event
    }

    /// Context-usage side channel for function_call lines: reuses the decoder's normalized usage;
    /// input + cacheRead = the full prompt including cache reads ≈ current context size
    private func contextUsage(_ root: [String: Any]) -> (model: String?, used: Int)? {
        guard let (model, usage) = CodeBuddyTranscriptDecoder.usage(root, dialect: dialect)
        else { return nil }
        let used = usage.input + usage.cacheRead
        return used > 0 ? (model, used) : nil
    }

    // MARK: - Context usage (function_call usage ÷ ContextWindows window)

    /// Same as the kimi/grok tailers: events are stamped fresh at emit time (the stale gate would
    /// drop an outdated contextUpdate) and re-emitted only on a change ≥0.5 to avoid spam.
    /// TaskStore never creates a task for contextUpdate, and this only emits for tracked sessions,
    /// so no phantom tasks.
    private func emitContext(
        for chatURL: URL, context ctx: FileContext,
        usage: (model: String?, used: Int)
    ) {
        // WorkBuddy's database stores the window the session actually runs with; prefer it over
        // the per-model table
        let percent = min(100, ctx.contextWindow.map { Double(usage.used) / Double($0) * 100 }
            ?? ContextWindows.percent(used: usage.used, model: usage.model))
        if let last = lastContextPercent[chatURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[chatURL.path] = percent
        HealthRegistry.shared.event(healthName)
        handler(TaskEvent(
            source: dialect.source, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// Newly discovered file: read only the first 64KB to build context (cwd/start time/title are
    /// mostly at the head) + the last 256KB to recover the "last state", without replaying history;
    /// small files (≤320KB) are read in one go.
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
            // The head only builds context; drop any trailing partial line
            guard let head = try? handle.read(upToCount: Int(headLength)) else { return }
            if let lastNewline = head.lastIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(head[head.startIndex...lastNewline]))
            }
            // The tail start may land mid-line; align to just past the first newline
            guard (try? handle.seek(toOffset: size - tailLength)) != nil,
                  let tail = try? handle.readToEnd()
            else { return }
            if let firstNewline = tail.firstIndex(of: UInt8(ascii: "\n")) {
                chunks.append(Data(tail[tail.index(after: firstNewline)...]))
            }
        }

        var ctx = context(for: url)
        refreshHints(into: &ctx)
        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, used: Int)?
        for chunk in chunks {
            for line in chunk.split(separator: UInt8(ascii: "\n")) {
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
        // Running state and turn start: subagent snapshots are clipped per turn and only scanned
        // while running
        ctx.running = lastStarted != nil
            && (lastFinished.map { $0.timestamp < lastStarted!.timestamp } ?? true)
        ctx.turnStartedAt = lastStarted?.timestamp
        contexts[path] = ctx
        guard !ctx.excluded else { return }

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
        // The tail usage reflects the latest context usage (TaskStore drops unknown sessions, so
        // this is safe)
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - Subagent snapshot (derived from the parent transcript's function_call/result pairs)

    /// Scans only tracked, running sessions (phantom-task invariant: never emit for untracked
    /// sessions); emits only when the snapshot changes (TaskStore dedups again); clears the cache
    /// on going idle so the next turn emits afresh.
    private func emitSubagentUpdates() {
        for (path, ctx) in contexts where !ctx.excluded {
            guard ctx.running else {
                lastSubagents[path] = []
                continue
            }
            let file = URL(fileURLWithPath: path)
            let subagents = CodeBuddySubagentScanner.scan(
                sessionDir: file.deletingPathExtension(),
                parentTranscript: file,
                turnStartedAt: ctx.turnStartedAt,
                dialect: dialect)
            guard subagents != (lastSubagents[path] ?? []) else { continue }
            lastSubagents[path] = subagents
            HealthRegistry.shared.event(healthName)
            handler(TaskEvent(
                source: dialect.source, sessionId: ctx.sessionId,
                kind: .subagentsUpdated(subagents),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt), false)
        }
    }

    private func context(for url: URL) -> FileContext {
        if let existing = contexts[url.path] { return existing }
        let sessionId = url.deletingPathExtension().lastPathComponent
        var ctx = FileContext(sessionId: sessionId, cwd: nil, sessionStartedAt: nil, title: nil)
        if dialect == .workbuddy, CodeBuddyDialect.isWorkBuddyInternalSession(sessionId) {
            ctx.excluded = true
            ctx.exclusionDecided = true
        }
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
            .flatMap { ($0 as? NSNumber)?.uint64Value }
    }
}
