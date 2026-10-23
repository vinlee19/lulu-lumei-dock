import Foundation
import EurekaKit

/// Event pipeline: merges the spool (Claude hooks + Codex notify) and the Codex rollout tailer,
/// applies dedup and enrichment (error sniffing / session title), then serializes into a single
/// handler.
public final class EventPipeline {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void
    /// Audit side channel: operation events decoded from Claude PostToolUse hooks (bypass
    /// TaskStore)
    public typealias AuditHandler = (AuditEvent, _ isStale: Bool) -> Void

    private let queue = DispatchQueue(label: "com.vinlee.eureka.pipeline")
    private let dedup = EventDeduplicator()
    private let handler: Handler
    private let auditHandler: AuditHandler?
    private var spool: SpoolConsumer?
    private var tailer: CodexRolloutTailer?
    private var claudeWatcher: ClaudeTranscriptWatcher?
    private var opencodeTailer: OpencodeEventTailer?
    private var grokTailer: GrokRolloutTailer?
    private var antigravityTailer: AntigravityActivityTailer?
    private var kimiTailer: KimiWireTailer?
    private var geminiTailer: GeminiChatTailer?
    private var qwenTailer: QwenChatTailer?
    private var hermesTailer: HermesStateTailer?
    private var codeBuddyTailer: CodeBuddyChatTailer?
    private var qoderTailer: QoderChatTailer?
    private var cursorTailer: CursorStateTailer?
    private var cursorTranscriptTailer: CursorTranscriptTailer?
    private var zcodeTailer: ZcodeRolloutTailer?

    /// Latest Codex rate-limit snapshot (consumed by the M6 panel)
    public private(set) var latestCodexRateLimits: RateLimitSnapshot?

    private let claudeProjectsRoot: URL
    private var codexThreadNames: [String: String]

    public init(
        spoolRoot: URL,
        codexSessionsRoot: URL = CodexRolloutTailer.defaultSessionsRoot(),
        codexSessionIndexURL: URL? = nil,
        claudeProjectsRoot: URL = ClaudeSessionBootstrap.defaultProjectsRoot(),
        opencodeDbPath: URL = OpencodePaths.db(),
        grokSessionsRoot: URL = GrokPaths.sessionsRoot(),
        antigravityConversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        kimiSessionsRoot: URL = KimiPaths.sessionsRoot(),
        geminiTmpRoot: URL = GeminiPaths.tmpRoot(),
        geminiProjectsFile: URL = GeminiPaths.projectsFile(),
        qwenProjectsRoot: URL = QwenPaths.projectsRoot(),
        codeBuddyProjectsRoot: URL = CodeBuddyPaths.projectsRoot(),
        qoderProjectsRoot: URL = QoderPaths.projectsRoot(),
        cursorStateDB: URL = CursorPaths.globalStateDB(),
        cursorWorkspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        cursorCLIHome: URL = CursorPaths.cliHome(),
        zcodeRolloutRoot: URL = ZcodePaths.rolloutRoot(),
        zcodeDbPath: URL = ZcodePaths.db(),
        auditHandler: AuditHandler? = nil,
        handler: @escaping Handler
    ) {
        self.handler = handler
        self.auditHandler = auditHandler
        self.claudeProjectsRoot = claudeProjectsRoot
        let resolvedSessionIndexURL = codexSessionIndexURL
            ?? CodexThreadNameIndex.resolvedURL(for: codexSessionsRoot)
        self.codexThreadNames = CodexThreadNameIndex.load(resolvedSessionIndexURL)
        // Audit only PostToolUse from the hook channels (inject also uses these two channels). Trae
        // CN's payload has the same shape as Claude's, so the same decoder works with a different
        // source.
        let hookAuditSources: [String: AgentSource] = [
            "claude-hook": .claude, "trae-hook": .trae,
        ]
        let rawObserver: SpoolConsumer.RawObserver? = auditHandler.map { audit in
            { raw, isStale in
                guard let source = hookAuditSources[raw.channel],
                      let event = ClaudeAuditDecoder.decode(
                        payload: raw.payload, receivedAt: raw.receivedAt, source: source)
                else { return }
                audit(event, isStale)
            }
        }
        spool = SpoolConsumer(root: spoolRoot, rawObserver: rawObserver) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        tailer = CodexRolloutTailer(
            sessionsRoot: codexSessionsRoot,
            sessionIndexURL: resolvedSessionIndexURL,
            rateLimitHandler: { [weak self] snapshot in
                self?.queue.async { self?.latestCodexRateLimits = snapshot }
            },
            handler: { [weak self] event, isStale in
                self?.ingest(event, isStale: isStale)
            }
        )
        // opencode has no hook/notify; tail the opencode.db event table for live updates
        opencodeTailer = OpencodeEventTailer(dbPath: opencodeDbPath) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // grok has no hook/notify; tail ~/.grok/sessions/*/*/events.jsonl for live updates
        grokTailer = GrokRolloutTailer(sessionsRoot: grokSessionsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // antigravity content is protobuf; judge running/idle only from writes to
        // conversations/<uuid>.db
        antigravityTailer = AntigravityActivityTailer(
            conversationsRoot: antigravityConversationsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // kimi has no hook/notify; tail sessions/*/*/agents/main/wire.jsonl for live updates
        kimiTailer = KimiWireTailer(sessionsRoot: kimiSessionsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // gemini has no hook/notify; tail tmp/*/chats/session-*.jsonl for live updates
        geminiTailer = GeminiChatTailer(
            tmpRoot: geminiTmpRoot, projectsFile: geminiProjectsFile) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // qwen has no hook/notify; tail projects/*/chats/*.jsonl for live updates
        qwenTailer = QwenChatTailer(projectsRoot: qwenProjectsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // hermes shell hooks block the agent thread synchronously and need interactive approval →
        // poll state.db (all profiles). Cost: no "awaiting approval" state (the sessions table
        // lacks it), so Hermes shows no permission card.
        hermesTailer = HermesStateTailer { [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // codebuddy has no hook/notify; tail projects/<cwd-slug>/*.jsonl for live updates
        codeBuddyTailer = CodeBuddyChatTailer(projectsRoot: codeBuddyProjectsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // qoder has no hook/notify; tail projects/<slug>/*.jsonl for live updates
        qoderTailer = QoderChatTailer(projectsRoot: qoderProjectsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // cursor is an IDE with no hook/notify and no transcript file → poll state.vscdb read-only
        cursorTailer = CursorStateTailer(
            dbPath: cursorStateDB, workspaceStorageRoot: cursorWorkspaceStorageRoot,
            transcriptOwned: { now in
                CursorTranscriptIndex.ownedComposerIds(
                    cliHome: cursorCLIHome,
                    workspaceStorageRoot: cursorWorkspaceStorageRoot, now: now)
            }
        ) { [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // cursor's second channel: agent-transcripts has an explicit turn_ended, so it closes turns
        // more accurately than the DB. For sessions with a transcript it owns the lifecycle
        // exclusively (the DB-side closure above yields); both sides use composerId as sessionId,
        // so no duplicate cards.
        cursorTranscriptTailer = CursorTranscriptTailer(
            cliHome: cursorCLIHome, workspaceStorageRoot: cursorWorkspaceStorageRoot
        ) { [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        // zcode has no hook/notify; tail cli/rollout/model-io-sess_*.jsonl for live updates
        zcodeTailer = ZcodeRolloutTailer(
            rolloutRoot: zcodeRolloutRoot, dbPath: zcodeDbPath,
            modelConfigURL: ZcodePaths.modelConfig()) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
    }

    public func start() {
        spool?.start()
        tailer?.start(pollInterval: 1)
        opencodeTailer?.start(pollInterval: 2)
        grokTailer?.start(pollInterval: 2)
        antigravityTailer?.start(pollInterval: 2)
        kimiTailer?.start(pollInterval: 2)
        geminiTailer?.start(pollInterval: 2)
        qwenTailer?.start(pollInterval: 2)
        hermesTailer?.start(pollInterval: 5)
        codeBuddyTailer?.start(pollInterval: 2)
        qoderTailer?.start(pollInterval: 2)
        cursorTailer?.start(pollInterval: 2)
        cursorTranscriptTailer?.start(pollInterval: 2)
        zcodeTailer?.start(pollInterval: 2)
        // Always-on Claude transcript watch (including state rebuild on the launch scan): old
        // sessions started before hooks were installed emit no hook events, so this is their only
        // visible channel
        let watcher = ClaudeTranscriptWatcher(projectsRoot: claudeProjectsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        watcher.start(pollInterval: 2)
        claudeWatcher = watcher
    }

    public func stop() {
        spool?.stop()
        tailer?.stop()
        opencodeTailer?.stop()
        grokTailer?.stop()
        antigravityTailer?.stop()
        kimiTailer?.stop()
        geminiTailer?.stop()
        qwenTailer?.stop()
        hermesTailer?.stop()
        codeBuddyTailer?.stop()
        qoderTailer?.stop()
        cursorTailer?.stop()
        cursorTranscriptTailer?.stop()
        zcodeTailer?.stop()
        claudeWatcher?.stop()
    }

    /// Throttle for Claude context estimation (at most once per 20s per session; reading the file
    /// tail has a cost)
    private var lastContextEstimate: [String: Date] = [:]
    /// Cache of session first-start time (each session's file head is read only once)
    private var sessionFirstAt: [String: Date] = [:]

    private func ingest(_ event: TaskEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.dedup.isDuplicate(event) else { return }
            for enriched in self.enrich(event) {
                self.handler(enriched, isStale)
            }
        }
    }

    /// A Claude "success" finish, checked against the transcript tail (public for tests):
    /// - an API error line upgrades it to an error finish with the error text
    /// - background agents / workflows that have not reported back turn it into
    ///   `awaitingBackgroundTasks`: Stop fires the same way when the main agent ends its turn to
    ///   wait for them, and each report starts another turn, so the work is not finished yet. They
    ///   are counted over the background window directly: Stop means the turn has ended even if
    ///   its end_turn line is not on disk yet.
    /// - the session name (custom-title) upgrades the title; a deferred finish carries it as a
    ///   separate `titleUpdate`
    public static func enrichClaudeFinish(_ event: TaskEvent) -> [TaskEvent] {
        guard case .taskFinished(outcome: .success, let title, let detail) = event.kind,
              let transcriptPath = event.transcriptPath
        else { return [event] }
        let findings = ClaudeErrorSniffer.sniff(transcriptPath: transcriptPath)
        let newTitle = findings.sessionTitle ?? title
        var enriched = event
        if findings.isError {
            enriched.kind = .taskFinished(
                outcome: .error,
                title: newTitle,
                detail: findings.errorDetail ?? detail
            )
            return [enriched]
        }
        let awaiting = ClaudeBackgroundTasks.scan(
            fileURL: URL(fileURLWithPath: transcriptPath)).pendingCount
        if awaiting > 0 {
            enriched.kind = .awaitingBackgroundTasks(count: awaiting)
            guard let newTitle, newTitle != title else { return [enriched] }
            var titled = event
            titled.kind = .titleUpdate(title: newTitle)
            return [titled, enriched]
        }
        if newTitle != title {
            enriched.kind = .taskFinished(outcome: .success, title: newTitle, detail: detail)
        }
        return [enriched]
    }

    private func enrich(_ event: TaskEvent) -> [TaskEvent] {
        var events = [event]

        // Codex's official thread_name outranks the prompt summary; shared by notify and rollout.
        if event.source == .codex {
            var enriched = event
            switch event.kind {
            case .titleUpdate(let title):
                codexThreadNames[event.sessionId] = title
            case .taskStarted:
                if let title = codexThreadNames[event.sessionId] {
                    enriched.kind = .taskStarted(title: title)
                }
            case .taskFinished(let outcome, _, let detail):
                if let title = codexThreadNames[event.sessionId] {
                    enriched.kind = .taskFinished(
                        outcome: outcome, title: title, detail: detail)
                }
            default:
                break
            }
            events[0] = enriched
        }

        // Session first-start time: filled in for every Claude event with a transcript (head read
        // once, cached)
        if event.source == .claude, event.sessionStartedAt == nil,
           let transcriptPath = event.transcriptPath {
            let firstAt: Date?
            if let cached = sessionFirstAt[event.sessionId] {
                firstAt = cached
            } else {
                firstAt = ClaudeSessionFirstTimestamp.read(transcriptPath: transcriptPath)
                if let firstAt { sessionFirstAt[event.sessionId] = firstAt }
                if sessionFirstAt.count > 128 {
                    sessionFirstAt.removeAll()  // simple bound on growth; rereading is very cheap
                }
            }
            if let firstAt {
                events[0].sessionStartedAt = firstAt
            }
        }

        // Claude "success" finish → sniff the tail (see `enrichClaudeFinish`)
        if event.source == .claude, case .taskFinished(outcome: .success, _, _) = event.kind {
            events = Self.enrichClaudeFinish(event)
        }

        // Claude heartbeat (throttled to 20s) / awaiting confirmation (immediate, when the user
        // most needs to identify the session) → read the transcript tail: context usage + session
        // name (custom-title)
        if event.source == .claude, let transcriptPath = event.transcriptPath {
            let now = Date()
            var shouldInspect = false
            switch event.kind {
            case .activity:
                if now.timeIntervalSince(lastContextEstimate[event.sessionId] ?? .distantPast) > 20 {
                    lastContextEstimate[event.sessionId] = now
                    shouldInspect = true
                }
            case .waiting:
                shouldInspect = true
            default:
                break
            }
            if shouldInspect {
                if lastContextEstimate.count > 64 {
                    lastContextEstimate = lastContextEstimate.filter {
                        now.timeIntervalSince($0.value) < 3600
                    }
                }
                let info = ClaudeContextEstimator.inspect(transcriptPath: transcriptPath)
                func extra(_ kind: TaskEvent.Kind) -> TaskEvent {
                    TaskEvent(
                        source: .claude, sessionId: event.sessionId,
                        kind: kind, timestamp: now, cwd: event.cwd,
                        transcriptPath: transcriptPath)
                }
                // The title arrives before the waiting event, so the waiting card shows the session
                // name right away
                if let title = info.sessionTitle {
                    events.insert(extra(.titleUpdate(title: title)), at: 0)
                }
                if let percent = info.contextPercent {
                    events.append(extra(.contextUpdate(percent: percent)))
                }
            }
        }
        return events
    }
}
