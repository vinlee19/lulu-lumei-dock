import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Project session browser: Claude + Codex sources, grouped by project, searchable,
/// with per-session cost.
/// Owns a read-only EurekaStore connection (safe for concurrent WAL reads; UsageService
/// starts first and runs migrations).
final class SessionBrowserService: ObservableObject {
    struct SessionCost: Equatable {
        var totalTokens: Int
        var costUSD: Double?
    }

    struct ProjectGroup: Identifiable {
        var id: String { name }
        var name: String
        var sessions: [AgentSessionInfo]
        var totalBytes: UInt64
        var latestActiveAt: Date
        var totalCostUSD: Double?
        /// Total project duration = sum of the spans of every session in the group
        var totalDuration: TimeInterval
    }

    /// rawValue is the stable persisted token; label is the display copy (decoupled, so
    /// copy edits don't touch saved state).
    /// The first three are sort keys for the flat list; `project` is the grouped-by-project view.
    enum SortMode: String, CaseIterable {
        case time
        case size
        case duration
        case project

        var label: String {
            switch self {
            case .time: return L10n.text("Activity", zhHans: "活跃")      // most recent activity
            case .size: return L10n.text("Size", zhHans: "占用")      // transcript disk usage
            case .duration: return L10n.text("Duration", zhHans: "耗时")  // span between a session's first and last activity
            case .project: return L10n.text("Project", zhHans: "项目")
            }
        }

        /// Tab icon (SF Symbol, same capsule-tab style as the sidebar / Settings page)
        var icon: String {
            switch self {
            case .time: return "clock.fill"
            case .size: return "internaldrive.fill"
            case .duration: return "hourglass"
            case .project: return "folder.fill"
            }
        }
    }

    /// Ledger summary across all sessions (unaffected by search / truncation)
    struct Summary: Equatable {
        var totalBytes: UInt64 = 0
        var sessionCount: Int = 0
        var totalCostUSD: Double?
    }

    /// Full-text search hit (per message); snippet is already trimmed around the query
    struct FullTextHit: Identifiable, Equatable {
        var id: Int64
        var source: AgentSource
        var sessionId: String
        var sessionName: String?
        var messageIdx: Int
        var role: String
        var ts: Date?
        var snippet: String
    }

    @Published private(set) var groups: [ProjectGroup] = []
    /// Flat list (time/size/duration modes; empty in project mode, which uses groups)
    @Published private(set) var flatSessions: [AgentSessionInfo] = []
    /// Session count per source (full set, for the source chip counts; unaffected by
    /// search / filters)
    @Published private(set) var sourceCounts: [AgentSource: Int] = [:]
    @Published private(set) var summary = Summary()
    /// id → session index info (joins session names into the usage "by session" ranking
    /// and drives cross-tab jumps); filled when refresh completes
    @Published private(set) var sessionsById: [String: AgentSessionInfo] = [:]
    @Published private(set) var costs: [String: SessionCost] = [:]
    /// Prompt count per session
    @Published private(set) var promptCounts: [String: Int] = [:]
    /// Session → most recent terminal binding, keyed by `AgentTask.key(source:sessionId:)`
    @Published private(set) var terminals: [String: TerminalBinding] = [:]
    @Published private(set) var scanning = false
    /// Currently selected session (what the detail pane renders)
    @Published private(set) var selected: AgentSessionInfo?
    @Published private(set) var transcript: [TranscriptMessage] = []
    @Published private(set) var transcriptTruncated = false
    @Published private(set) var transcriptLoading = false
    /// Context-usage breakdown by category for the current session (estimated async after
    /// the transcript loads; always nil for trae/antigravity)
    @Published private(set) var contextBreakdown: ContextBreakdown?
    @Published var sortMode: SortMode = .time {
        didSet { if sortMode != oldValue { rebuild() } }
    }
    /// Terminal history of the open session, read on the queue with its transcript (the detail
    /// header used to query SQLite on the main thread on every render)
    @Published private(set) var openTerminalHistory: (
        sessionId: String, entries: [(binding: TerminalBinding, firstSeen: Date, lastSeen: Date)]
    )?
    @Published var searchText = "" {
        didSet {
            rebuild()
            scheduleFullTextSearch()
        }
    }
    /// Full-text search hits (filled async once the query is ≥2 characters)
    @Published private(set) var fullTextHits: [FullTextHit] = []
    /// Message id to jump to after a full-text hit is clicked (consumed by the detail page
    /// once the transcript loads)
    @Published private(set) var pendingJumpMessageId: Int?
    /// Source filter (nil = all)
    @Published var sourceFilter: AgentSource? {
        didSet { rebuild() }
    }
    /// Time range: false = last 30 days (default); true = all time (re-indexes)
    @Published var rangeAll = false {
        // Only a real change rescans: the Sessions tab assigns this on every appear
        didSet { if rangeAll != oldValue { refresh() } }
    }
    /// When the last index scan finished (opening the tab within a minute reuses it)
    private var lastIndexedAt: Date?

    /// .utility: the index scan walks every agent's history and must not compete with the UI on
    /// the performance cores; opening a transcript enqueues at .userInitiated (see
    /// loadTranscript), which boosts the queue while the user waits
    private let queue = DispatchQueue(label: "com.vinlee.eureka.sessions", qos: .utility)
    private let resolver = ProjectResolver()
    private var sessions: [AgentSessionInfo] = []
    /// Session id waiting to be revealed (recorded while the index isn't ready, consumed
    /// after refresh completes)
    private var pendingRevealId: String?
    /// A refresh request arriving mid-scan (typically switching to "All time") → run one
    /// more pass afterwards.
    /// It can't be silently dropped: the range state has already changed, so clicking the
    /// same option again won't fire didSet, and the UI would sit on "All time" with only
    /// 30 days of data, as if it never finished loading.
    private var refreshPending = false
    /// Full-text search debounce
    private var searchWorkItem: DispatchWorkItem?
    // Accessed only on `queue` from here down
    private var store: EurekaStore?
    private var pricing: PricingTable { PricingCatalogStore.shared.current }
    private var storeLoaded = false

    /// Lazily opens the read-only store connection (shared by refresh and full-text search;
    /// call only on `queue`)
    private func loadStoreIfNeeded() {
        guard !storeLoaded else { return }
        storeLoaded = true
        store = try? EurekaStore(path: EurekaStore.defaultURL())
        PricingCatalogStore.shared.loadIfNeeded(paths: .app)
    }

    /// Tab-open refresh: skipped while a scan runs or one finished within `maxAge`. Every open used
    /// to queue a full re-index of every agent (twice, via `rangeAll`), the heaviest thing the
    /// Sessions tab does.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        if scanning { return }
        if let lastIndexedAt, Date().timeIntervalSince(lastIndexedAt) < maxAge { return }
        refresh()
    }

    func refresh() {
        if scanning {
            refreshPending = true
            return
        }
        scanning = true
        // rangeAll is a main-thread @Published; capture it before dispatching so the closure
        // never reads it across threads
        let rangeAll = self.rangeAll
        queue.async { [weak self] in
            guard let self else { return }
            self.loadStoreIfNeeded()
            // Time range: last 30 days by default; "All time" sets no window.
            // No cap on count: the old limits (300/2000, truncated by mtime) silently pushed older
            // sessions out of the list (observed: long sessions with 300+ turns "disappeared").
            // Head parsing reads only 64KB per file on a background queue, so even tens of
            // thousands of files take seconds; downstream batch queries (cost / prompt counts)
            // are already chunked by 500, and the list renders through LazyVStack.
            let window: TimeInterval = rangeAll ? .greatestFiniteMagnitude : 30 * 86400
            let maxSessions = Int.max
            var indexed = ClaudeSessionIndexer.index(
                projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(),
                window: window, maxSessions: maxSessions)
            indexed += CodexSessionIndexer.index(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
                window: window, maxSessions: maxSessions)
            indexed += OpencodeSessionIndexer.index(
                dbPath: OpencodePaths.db(), window: window, maxSessions: maxSessions)
            indexed += GrokSessionIndexer.index(
                sessionsRoot: GrokPaths.sessionsRoot(), window: window, maxSessions: maxSessions)
            indexed += AntigravitySessionIndexer.index(
                conversationsRoot: AntigravityPaths.conversationsRoot(),
                window: window, maxSessions: maxSessions)
            indexed += KimiSessionIndexer.index(
                sessionsRoot: KimiPaths.sessionsRoot(), window: window, maxSessions: maxSessions)
            indexed += GeminiSessionIndexer.index(
                tmpRoot: GeminiPaths.tmpRoot(), projectsFile: GeminiPaths.projectsFile(),
                window: window, maxSessions: maxSessions)
            indexed += QwenSessionIndexer.index(
                projectsRoot: QwenPaths.projectsRoot(), window: window, maxSessions: maxSessions)
            // hermes: every session lives in state.db (plus a separate DB per profile)
            indexed += HermesSessionIndexer.indexAll(window: window, maxSessions: maxSessions)
            indexed += CodeBuddySessionIndexer.index(
                projectsRoot: CodeBuddyPaths.projectsRoot(), window: window, maxSessions: maxSessions)
            indexed += QoderSessionIndexer.index(
                projectsRoot: QoderPaths.projectsRoot(), window: window, maxSessions: maxSessions)
            // zcode: every session lives in cli/db/db.sqlite (shared DB, no transcript files)
            indexed += ZcodeSessionIndexer.index(
                dbPath: ZcodePaths.db(), window: window, maxSessions: maxSessions)
            // cursor: every session lives in state.vscdb (the IDE has no transcript files)
            indexed += CursorSessionIndexer.index(window: window, maxSessions: maxSessions)
            // trae: the session DB is SQLCipher-encrypted; titles/times can only be inferred from
            // the plaintext memory library (delayed, possibly empty)
            indexed += TraeSessionIndexer.index(window: window, maxSessions: maxSessions)
            // Dedup by id (e.g. Claude's nested subagent dirs can index the same session twice;
            // duplicate ids in ForEach render blank rows)
            var seenIds = Set<String>()
            indexed = indexed.filter { seenIds.insert($0.id).inserted }

            // Per-session cost: aggregate per session × model, then price through the pricing table
            var costMap: [String: SessionCost] = [:]
            if let store = self.store,
               let totals = try? store.usage.totalsForSessions(indexed.map(\.id)) {
                for (sessionId, rows) in totals {
                    var tokens = 0
                    var cost: Double?
                    for row in rows {
                        tokens += row.inputTokens + row.outputTokens
                            + row.cacheReadTokens + row.cacheCreationTokens
                        if let rowCost = self.pricing.cost(of: row) {
                            cost = (cost ?? 0) + rowCost
                        }
                    }
                    costMap[sessionId] = SessionCost(totalTokens: tokens, costUSD: cost)
                }
            }

            let prompts = (try? self.store?.sessionStats.promptCounts(
                for: indexed.map(\.id))) ?? [:]

            // Terminal ownership: fetch the whole table once (keyed source:sessionId) instead of
            // one query per row
            let terminals = (try? self.store?.sessionTerminals.latestBySession()) ?? [:]

            DispatchQueue.main.async {
                self.sessions = indexed
                self.sessionsById = Dictionary(
                    indexed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.costs = costMap
                self.promptCounts = prompts
                self.terminals = terminals
                self.scanning = false
                self.lastIndexedAt = Date()
                self.rebuild()
                // Consume a pending reveal once the index is ready (the usage "by session" ranking
                // may be clicked before it's built)
                if let pending = self.pendingRevealId {
                    self.pendingRevealId = nil
                    if let hit = self.sessionsById[pending] {
                        self.select(hit)
                    }
                }
                // A refresh request arrived during the scan (e.g. the time range changed) → rescan
                // automatically with the latest state rather than leaving the user's click with no
                // effect
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    private func rebuild() {
        // Summary: all sessions, no filtering, no truncation
        let allCosts = sessions.compactMap { costs[$0.id]?.costUSD }
        summary = Summary(
            totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
            sessionCount: sessions.count,
            totalCostUSD: allCosts.isEmpty ? nil : allCosts.reduce(0, +))
        sourceCounts = sessions.reduce(into: [:]) { $0[$1.source, default: 0] += 1 }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        var visible = sessions
        if let filter = sourceFilter {
            visible = visible.filter { $0.source == filter }
        }
        if !query.isEmpty {
            // Searching: match everything, no truncation
            visible = visible.filter { session in
                let haystack = [
                    session.name, session.id, session.cwd,
                ].compactMap { $0?.lowercased() }.joined(separator: " ")
                return haystack.contains(query)
            }
        }

        // Flat modes: sort only, no project grouping, no count cap (the range is set by the
        // indexing window)
        if sortMode != .project {
            switch sortMode {
            case .time: visible.sort { $0.lastActiveAt > $1.lastActiveAt }
            case .size: visible.sort { $0.sizeBytes > $1.sizeBytes }
            case .duration: visible.sort { ($0.duration ?? 0) > ($1.duration ?? 0) }
            case .project: break
            }
            flatSessions = visible
            groups = []
            return
        }

        // Project mode: group by project (groups, and sessions within them, sorted by most
        // recent activity)
        visible.sort { $0.lastActiveAt > $1.lastActiveAt }
        var byProject: [String: [AgentSessionInfo]] = [:]
        for session in visible {
            let name = resolver.projectName(forCwd: session.cwd) ?? L10n.text("(Unknown project)", zhHans: "（未知项目）")
            byProject[name, default: []].append(session)
        }
        var result: [ProjectGroup] = byProject.map { name, sessions in
            let groupCosts = sessions.compactMap { costs[$0.id]?.costUSD }
            return ProjectGroup(
                name: name,
                sessions: sessions.sorted { $0.lastActiveAt > $1.lastActiveAt },
                totalBytes: sessions.reduce(0) { $0 + $1.sizeBytes },
                latestActiveAt: sessions.map(\.lastActiveAt).max() ?? .distantPast,
                totalCostUSD: groupCosts.isEmpty ? nil : groupCosts.reduce(0, +),
                totalDuration: sessions.reduce(0) { $0 + ($1.duration ?? 0) }
            )
        }
        result.sort { $0.latestActiveAt > $1.latestActiveAt }
        flatSessions = []
        groups = result
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Full-text search

    /// Queries the FTS index on the background queue after a 250ms debounce; queries under
    /// 2 characters just clear the results
    private func scheduleFullTextSearch() {
        searchWorkItem?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            fullTextHits = []
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadStoreIfNeeded()
            let hits = (try? self.store?.search.search(query, limit: 50)) ?? []
            let mapped = hits.map { hit in
                FullTextHit(
                    id: hit.docId,
                    source: AgentSource(rawValue: hit.source) ?? .claude,
                    sessionId: hit.sessionId,
                    sessionName: nil,
                    messageIdx: hit.messageIdx,
                    role: hit.role,
                    ts: hit.ts,
                    snippet: Self.snippet(around: query, in: hit.text))
            }
            DispatchQueue.main.async {
                // The query changed before results landed → drop the stale results
                guard self.searchText.trimmingCharacters(in: .whitespaces) == query else { return }
                self.fullTextHits = mapped.map { hit in
                    var enriched = hit
                    enriched.sessionName = self.sessionsById[hit.sessionId]?.name
                    return enriched
                }
            }
        }
        searchWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Trims a hit snippet around the match: keeps `radius` characters on each side, adding
    /// ellipses when cut
    static func snippet(around query: String, in text: String, radius: Int = 40) -> String {
        let collapsed = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = collapsed.range(of: query, options: [.caseInsensitive]) else {
            return String(collapsed.prefix(radius * 2))
        }
        let start = collapsed.index(
            range.lowerBound, offsetBy: -radius, limitedBy: collapsed.startIndex)
            ?? collapsed.startIndex
        let end = collapsed.index(
            range.upperBound, offsetBy: radius, limitedBy: collapsed.endIndex)
            ?? collapsed.endIndex
        var result = String(collapsed[start..<end])
        if start > collapsed.startIndex { result = "…" + result }
        if end < collapsed.endIndex { result += "…" }
        return result
    }

    /// Full-text hit clicked: select the session and record the message to jump to
    /// (consumed by the detail page once the transcript loads)
    func revealMessage(sessionId: String, messageIdx: Int) {
        pendingJumpMessageId = messageIdx
        reveal(sessionId: sessionId)
    }

    /// Called by the detail page after the transcript loads to take the pending jump
    /// message id (taking clears it)
    func consumePendingJump() -> Int? {
        defer { pendingJumpMessageId = nil }
        return pendingJumpMessageId
    }

    /// Cross-page jump to "turn N's lineage graph of a session". Mirrors `revealMessage`
    /// one-to-one:
    /// records the target and goes through the same reveal path (including the fallback
    /// for an unready index).
    @Published private(set) var pendingTurnIndex: Int?

    func revealTurn(sessionId: String, turnIndex: Int) {
        pendingTurnIndex = turnIndex
        reveal(sessionId: sessionId)
    }

    /// Takes the pending turn after the transcript loads (taking clears it)
    func consumePendingTurn() -> Int? {
        defer { pendingTurnIndex = nil }
        return pendingTurnIndex
    }

    // MARK: - Selection and transcript

    /// Token total of one session × model aggregate row (used to pick the window model;
    /// same basis as costs)
    private static func totalTokens(_ row: UsageTotals) -> Int {
        row.inputTokens + row.outputTokens + row.cacheReadTokens + row.cacheCreationTokens
    }

    /// Cross-tab jump: select a session by id (recorded if the index isn't ready,
    /// auto-selected after refresh completes)
    func reveal(sessionId: String) {
        if let hit = sessionsById[sessionId] {
            select(hit)
            return
        }
        pendingRevealId = sessionId
        refresh()
    }

    /// Selects a session and loads its transcript in the background
    func select(_ session: AgentSessionInfo?) {
        selected = session
        transcript = []
        transcriptTruncated = false
        contextBreakdown = nil  // cleared on every session switch; filled back after estimation, checked by id
        guard let session else { return }
        loadTranscript(session)
    }

    /// Truncation fallback: reload the whole thing with no budget (for the detail page's
    /// "Load all" button).
    /// The whole file is read into memory for parsing anyway; the budget only bounds the
    /// size of the message array,
    /// so lifting it on explicit user request is safe.
    func loadFullTranscript() {
        guard let session = selected else { return }
        loadTranscript(session, maxMessages: Int.max)
    }

    /// Summary citation pointing past the loaded budget: load everything, then jump (consumed by
    /// the detail page's existing pending-jump path)
    func loadFullTranscript(thenJumpTo messageId: Int) {
        pendingJumpMessageId = messageId
        loadFullTranscript()
    }

    private func loadTranscript(
        _ session: AgentSessionInfo,
        maxMessages: Int = TranscriptReader.defaultMaxMessages
    ) {
        transcriptLoading = true
        queue.async(qos: .userInitiated) { [weak self] in
            let result = TranscriptReader.load(session: session, maxMessages: maxMessages)
            self?.loadStoreIfNeeded()
            let terminalHistory = (try? self?.store?.sessionTerminals.bindings(
                source: session.source, sessionId: session.id)) ?? []
            // Context-usage estimate: trae/antigravity have no readable message bodies, so nil
            var breakdown: ContextBreakdown?
            if session.source != .trae && session.source != .antigravity {
                self?.loadStoreIfNeeded()
                // Window size comes from the model with the most tokens in this session; no records
                // → nil → default window
                let rows = (try? self?.store?.usage.totalsForSessions([session.id]))?[session.id] ?? []
                let model = rows.max(by: { Self.totalTokens($0) < Self.totalTokens($1) })?.model
                // The window denominator prefers the real value carried by the session's own data:
                // codex's token_count events carry model_context_window; kimi uses the per-model
                // max_context_size in config.toml, zcode uses the per-model limit.context in
                // v2/config.json (both real configs the apps maintain themselves); other sources
                // fall back to the built-in ContextWindows table. zcode's transcriptPath is the
                // shared sqlite DB; the real usage is in the per-session rollout. The last usage
                // entry also carries the model name: the ledger row may not be written yet (60s
                // tick), and without it the window denominator would skip the config and fall to
                // the built-in default
                let zcodeLast = session.source == .zcode
                    ? LastTurnUsageReader.lastZcodeContext(
                        rolloutPath: ZcodePaths.rolloutRoot()
                            .appendingPathComponent("model-io-\(session.id).jsonl").path)
                    : nil
                let realWindow = LastTurnUsageReader.lastContextWindow(
                    source: session.source, transcriptPath: session.transcriptPath)
                    ?? (session.source == .kimi
                        ? KimiConfigWindows.window(forModel: model) : nil)
                    ?? (session.source == .zcode
                        ? ZcodeConfigWindows.window(forModel: model ?? zcodeLast?.model) : nil)
                breakdown = ContextBreakdownEstimator.estimate(
                    source: session.source,
                    cwd: session.cwd,
                    messages: result.messages,
                    model: model,
                    lastTurnTotalTokens: zcodeLast?.tokens
                        ?? LastTurnUsageReader.lastContextTokens(
                            source: session.source, transcriptPath: session.transcriptPath),
                    windowOverride: realWindow)
            }
            DispatchQueue.main.async {
                guard let self, self.selected?.id == session.id else { return }
                self.transcript = result.messages
                self.transcriptTruncated = result.truncated
                self.transcriptLoading = false
                self.contextBreakdown = breakdown
                self.openTerminalHistory = (session.id, terminalHistory)
            }
        }
    }

    // MARK: - Resume and delete

    /// Resume command (shared by the detail pane display, copy, and run-in-terminal) Most recent
    /// terminal for a session (for list rows; reads the published batch result, not the DB)
    func terminal(for session: AgentSessionInfo) -> TerminalBinding? {
        terminals[AgentTask.key(source: session.source, sessionId: session.id)]
    }

    /// **All** terminal bindings for a session (for the detail page's "ran in N terminals").
    /// Loaded with the transcript (see `openTerminalHistory`); the list needs only the latest
    /// binding, not history.
    func terminalHistory(
        for session: AgentSessionInfo
    ) -> [(binding: TerminalBinding, firstSeen: Date, lastSeen: Date)] {
        guard let open = openTerminalHistory, open.sessionId == session.id else { return [] }
        return open.entries
    }

    func resumeCommand(for session: AgentSessionInfo) -> String {
        let resume: String
        switch session.source {
        case .claude: resume = "claude --resume \(session.id)"
        case .codex: resume = "codex resume \(session.id)"
        case .opencode: resume = "opencode --session \(session.id)"  // --session re-enters the given session (opencode 1.17+)
        case .grok: resume = "grok --resume \(session.id)"
        case .antigravity: resume = "agy --conversation \(session.id)"
        case .kimi: resume = "kimi --session \(session.id)"
        case .gemini: resume = "gemini --resume \(session.id)"
        case .qwen: resume = "qwen --resume \(session.id)"
        case .hermes: resume = "hermes --resume \(session.id)"
        case .codebuddy: resume = "codebuddy --resume \(session.id)"
        case .qoder:
            // The CLI binary has its version in the filename; glob for the newest, falling back to
            // the bare command name
            let binary = QoderPaths.cliBinary()?.path ?? "qoderclicn"
            resume = "\(binary) --resume \(session.id)"
        case .cursor:
            // Cursor is an IDE with no command-line entry to resume a session; we can only open the
            // workspace and the user picks the session from the sidebar history. The `cursor`
            // command is installed via Cmd+Shift+P inside the IDE.
            return session.cwd.map { "cursor '\($0)'" } ?? "cursor"
        case .trae:
            // Trae is like Cursor: an IDE with no per-session resume command, so only open the
            // workspace. Sessions come from the CN edition's memory library (the international
            // edition has no memory dir), so always use `trae-cn`.
            return session.cwd.map { "trae-cn '\($0)'" } ?? "trae-cn"
        case .zcode:
            // ZCode has no known per-session resume flag, so only open the workspace directory
            return session.cwd.map { "open '\($0)'" } ?? "open ."
        }
        guard let cwd = session.cwd else { return resume }
        return "cd '\(cwd)' && " + resume
    }

    /// Copies the resume command to the clipboard
    func copyResumeCommand(_ session: AgentSessionInfo) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resumeCommand(for: session), forType: .string)
    }

    /// Runs the resume command in a new Terminal window/tab (osascript; double quotes /
    /// backslashes in the command are escaped)
    func resumeInTerminal(_ session: AgentSessionInfo) {
        let command = resumeCommand(for: session)
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Terminal"
            activate
            do script "\(escaped)"
        end tell
        """
        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try? process.run()
            process.waitUntilExit()
        }
    }

    /// Deletes sessions (moved to the Trash, recoverable); deletability is
    /// `AgentSource.supportsSessionDeletion`
    /// (opencode / hermes live in shared DBs and aren't supported).
    /// A Claude session's nested subagent dir (<session>/…) is cleaned up too; grok removes
    /// the whole <uuid>/ dir;
    /// antigravity removes <uuid>.db (plus -wal/-shm); kimi removes the whole session_<uuid>/ dir.
    /// codebuddy / qoder take the default branch: delete <sessionId>.jsonl and the same-named
    /// <sessionId>/ companion dir (subagents etc., same logic as Claude's nested dir).
    func deleteSessions(_ toDelete: [AgentSessionInfo], completion: ((Int) -> Void)? = nil) {
        let deletable = toDelete.filter { $0.source.supportsSessionDeletion }
        guard !deletable.isEmpty else {
            completion?(0)
            return
        }
        if let selectedId = selected?.id, deletable.contains(where: { $0.id == selectedId }) {
            select(nil)
        }
        queue.async { [weak self] in
            let fm = FileManager.default
            var trashed = 0
            for session in deletable {
                let fileURL = URL(fileURLWithPath: session.transcriptPath)
                // grok: transcriptPath = <uuid>/chat_history.jsonl; delete the whole session dir
                if session.source == .grok {
                    let sessionDir = fileURL.deletingLastPathComponent()
                    if (try? fm.trashItem(at: sessionDir, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    continue
                }
                // kimi: transcriptPath = session_<uuid>/agents/main/wire.jsonl; go up three levels
                // and delete the whole session dir
                if session.source == .kimi {
                    let sessionDir = fileURL
                        .deletingLastPathComponent()   // main/
                        .deletingLastPathComponent()   // agents/
                        .deletingLastPathComponent()   // session_<uuid>/
                    if (try? fm.trashItem(at: sessionDir, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    continue
                }
                // antigravity: transcriptPath = <uuid>.db; delete it together with -wal/-shm
                if session.source == .antigravity {
                    if (try? fm.trashItem(at: fileURL, resultingItemURL: nil)) != nil {
                        trashed += 1
                    }
                    for suffix in ["-wal", "-shm"] {
                        let sidecar = URL(fileURLWithPath: session.transcriptPath + suffix)
                        if fm.fileExists(atPath: sidecar.path) {
                            try? fm.trashItem(at: sidecar, resultingItemURL: nil)
                        }
                    }
                    continue
                }
                if (try? fm.trashItem(at: fileURL, resultingItemURL: nil)) != nil {
                    trashed += 1
                }
                // Claude nested dir (subagents etc.): <dir>/<sessionId>/
                let nested = fileURL.deletingPathExtension()
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: nested.path, isDirectory: &isDir), isDir.boolValue {
                    try? fm.trashItem(at: nested, resultingItemURL: nil)
                }
            }
            DispatchQueue.main.async { completion?(trashed) }
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }
}
