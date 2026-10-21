import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Usage service: owns SQLite + the scanners, scans incrementally on a timer and publishes
/// summaries. The store/scanners are only touched on an internal serial queue; @Published
/// properties are only updated on the main thread.
final class UsageService: ObservableObject {
    @Published private(set) var summary: UsageSummary?
    @Published private(set) var recentHistory: [FinishedTask] = []
    /// Task counts by (day, outcome) over the last 14 days (history page stacked chart; days with
    /// no tasks are absent, the UI fills 0)
    @Published private(set) var historyDailyOutcomes: [(day: Date, outcome: TaskOutcome, count: Int)] = []
    /// Session token totals for history tasks (sessionId → totalTokens; for the inline Tokens
    /// column)
    @Published private(set) var historyTokens: [String: Int] = [:]
    /// Running tasks (pushed by the AppDelegate state machine; for the history page's pinned
    /// "Running" group)
    @Published private(set) var runningTasks: [AgentTask] = []
    @Published private(set) var lastError: String?
    @Published private(set) var exportMessage: String?
    /// Current page of the request log (newest first) and total count (for dashboard paging)
    @Published private(set) var records: [RecordDisplay] = []
    @Published private(set) var recordTotal = 0
    /// Model stats (full breakdown for the selected period/source)
    @Published private(set) var modelTotals: [UsageTotals] = []
    /// Model stats of the comparison range (one period earlier, same elapsed time); nil = the
    /// selected period has nothing to compare against ("All")
    @Published private(set) var comparisonTotals: [UsageTotals]?
    /// Current calendar month across every source (month card, budget alerts); refreshed on every
    /// scan, so budget alerts fire without the dashboard open
    @Published private(set) var monthOverview: MonthOverview?
    /// Turns asked in the selected range/source (turn card)
    @Published private(set) var turnSummary = TurnSummary()

    struct MonthOverview: Equatable {
        var monthToDate: Double
        /// Cost of the last 7 days (the forecast's daily rate)
        var trailingSevenDays: Double
        /// Month-to-date API-equivalent cost per source (subscription payback)
        var bySource: [AgentSource: Double]
        var projected: Double?
    }
    /// Token/cost trend by (time bucket, source) over the selected range (for charts; short ranges
    /// switch to hourly granularity automatically)
    @Published private(set) var trend: [TrendPoint] = []
    @Published private(set) var trendIsHourly = false
    /// Tool/skill/plugin/subagent call stats (selected period/source)
    @Published private(set) var toolCallTotals: [ToolCallsRepo.ToolCallTotal] = []
    /// All-time skill stats (Skills analysis view: total count / last active / tokens at trigger)
    @Published private(set) var skillStats: [ToolCallsRepo.SkillUsageStat] = []
    /// MCP server call stats (key = lowercase server name, aggregated across sources; for the MCP
    /// page's idle detection)
    @Published private(set) var mcpServerStats: [String: MCPServerCallStat] = [:]

    struct MCPServerCallStat: Equatable {
        var calls: Int
        var lastTs: Double
    }
    /// Top skill ranking (Skills page analysis card, filtered by the selected time period)
    @Published private(set) var skillRanking: [ToolCallsRepo.SkillUsageStat] = []
    /// All-time subagent call stats (Agents page "called N times"; kind='agent', data from
    /// Claude/Kimi)
    @Published private(set) var agentStats: [ToolCallsRepo.SkillUsageStat] = []
    /// Vibe coding weekly report (filled by loadWeeklyReport; nil = not loaded)
    @Published private(set) var weeklyReport: WeeklyReport?
    /// Project stats (selected range)
    @Published private(set) var projectTotals: [ProjectTotal] = []
    /// Per-session usage ranking (selected range/source, top 50 by tokens descending)
    @Published private(set) var sessionTotals: [SessionTotal] = []
    /// Active-hours heatmap cells (selected range/source, weekday × 24h)
    @Published private(set) var heatmapCells: [UsageRepo.HeatmapCell] = []
    /// Price table revision (+1 after a price change; the dashboard recomputes costs from it)
    @Published private(set) var pricingRevision = 0
    /// Unpriced / estimated models (Settings → Model pricing; by tokens descending)
    @Published private(set) var pricingDiagnostics: [PricingDiagnostic] = []

    struct PricingDiagnostic: Identifiable, Equatable {
        var id: String { "\(source.rawValue)|\(model)|\(provider ?? "")" }
        var source: AgentSource
        var model: String
        var provider: String?
        var tokens: Int
        var resolution: PriceResolution
    }

    struct ProjectTotal: Identifiable, Equatable {
        var id: String { name }
        var name: String
        var tokens: Int
        var requests: Int
        var costUSD: Double?
    }

    /// Trend chart data point (one per bucket per source; bucket = midnight of the day or top of
    /// the hour)
    struct TrendPoint: Identifiable {
        var id: String { "\(bucket.timeIntervalSince1970)-\(source.rawValue)" }
        var bucket: Date
        var source: AgentSource
        var tokens: Int
        var requests: Int
        var costUSD: Double
    }

    /// Per-session usage ranking row (the view layer joins the session name via
    /// SessionBrowserService.sessionsById)
    struct SessionTotal: Identifiable, Equatable {
        var id: String { sessionId }
        var sessionId: String
        var source: AgentSource
        var project: String?
        var lastActiveAt: Date
        var tokens: Int
        var requests: Int
        var costUSD: Double?
    }

    /// Dashboard period (same basis as UsageAggregator: day = today's midnight, week = Monday,
    /// month = first of month, all = all-time)
    enum DashboardPeriod: String, CaseIterable {
        case today = "今日"
        case week = "本周"
        case month = "本月"
        case all = "全部"
        case custom = "自定义"

        /// Fixed-period start (custom is decided by the view from picked dates; returns today's
        /// midnight here as a fallback)
        var startDate: Date {
            var calendar = Calendar.current
            let now = Date()
            switch self {
            case .today, .custom:
                return calendar.startOfDay(for: now)
            case .week:
                calendar.firstWeekday = 2
                let components = calendar.dateComponents(
                    [.yearForWeekOfYear, .weekOfYear], from: now)
                return calendar.date(from: components) ?? calendar.startOfDay(for: now)
            case .month:
                let components = calendar.dateComponents([.year, .month], from: now)
                return calendar.date(from: components) ?? calendar.startOfDay(for: now)
            case .all:
                return Date(timeIntervalSince1970: 0)
            }
        }
    }

    /// Request log display row (cost already converted via the price table)
    struct RecordDisplay: Identifiable {
        let id = UUID()
        var row: UsageRepo.UsageRecordRow
        var costUSD: Double?
    }

    /// Daily skill call point (detail page trend chart)
    struct SkillDayCount: Identifiable {
        var id: Double { day.timeIntervalSince1970 }
        var day: Date
        var count: Int
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.usage", qos: .utility)
    private var timer: DispatchSourceTimer?

    /// Full-text indexing cadence, **independent of usage's 60s**.
    ///
    /// Search isn't real-time data, while the session discovery it pays for is a big cost on this background queue. The two used to share 60s:
    /// one discovery pass once took 72s (see the comment on `CodexSessionIndexer.headScanLimit`), so the queue was never idle.
    /// The indexers keep fingerprint watermarks internally, so running more often only re-pays the discovery cost with no extra output.
    ///
    /// Cost: full-text search can lag the newest sessions by up to 5 minutes. Usage, rate limits and history stay at 60s.
    static let indexInterval: TimeInterval = 300
    /// When indexing last ran (accessed only on queue). Starts at distantPast so the first pass
    /// after launch indexes.
    private var lastIndexRun = Date.distantPast
    /// Sessions one index pass may rebuild (see `TranscriptSearchIndexer.indexOnce`)
    static let indexBatch = 120
    /// Discovery reused while a truncated first index is still being worked through (discovery
    /// itself costs seconds; the backfill runs on every scan tick until it catches up)
    private var indexBacklog: (sessions: [AgentSessionInfo], at: Date)?
    /// A scan is already queued: `refreshNow` callers (window shown, tab opened, price change)
    /// coalesce into it instead of stacking full passes in front of the dashboard's loads
    private let scanQueuedLock = NSLock()
    private var scanQueued = false

    // The members below are accessed only on queue
    private var store: EurekaStore?
    private var claudeScanner: ClaudeTranscriptScanner?
    private var codexScanner: CodexUsageScanner?
    private var opencodeScanner: OpencodeUsageScanner?
    private var grokScanner: GrokUsageScanner?
    private var kimiScanner: KimiUsageScanner?
    private var geminiScanner: GeminiUsageScanner?
    private var qwenScanner: QwenUsageScanner?
    private var hermesScanner: HermesUsageScanner?
    private var codeBuddyScanner: CodeBuddyUsageScanner?
    private var cursorScanner: CursorUsageScanner?
    private var zcodeScanner: ZcodeUsageScanner?
    /// Antigravity (experimental, off by default): each pass decides whether to scan based on the
    /// toggle
    private var antigravityScanner: AntigravityUsageScanner?
    /// The health entry is registered only when the toggle is first turned on (it shouldn't show
    /// red on the health page while off); accessed only on queue
    private var antigravityHealthRegistered = false
    private var searchIndexer: TranscriptSearchIndexer?
    /// Shared price table (atomically swapped when a remote catalog arrives; reads are locked, safe
    /// for both main-thread rendering and background scans)
    private var pricing: PricingTable { PricingCatalogStore.shared.current }

    private static let claudeHealthName = "用量扫描 Claude"
    private static let codexHealthName = "用量扫描 Codex"
    private static let opencodeHealthName = "用量扫描 OpenCode"
    private static let grokHealthName = "用量扫描 Grok"
    private static let kimiHealthName = "用量扫描 Kimi"
    private static let geminiHealthName = "用量扫描 Gemini"
    private static let qwenHealthName = "用量扫描 Qwen"
    private static let hermesHealthName = "用量扫描 Hermes"
    private static let codeBuddyHealthName = "用量扫描 CodeBuddy"
    private static let cursorHealthName = "用量扫描 Cursor"
    private static let zcodeHealthName = "用量扫描 ZCode"
    private static let antigravityHealthName = "用量扫描 Antigravity（实验）"

    func start() {
        HealthRegistry.shared.register(Self.claudeHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codexHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.opencodeHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.grokHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.kimiHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.geminiHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.qwenHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.hermesHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codeBuddyHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.cursorHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.zcodeHealthName, expectedInterval: 60)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                self.store = store
                self.claudeScanner = ClaudeTranscriptScanner(
                    projectsRoot: ClaudeTranscriptScanner.defaultProjectsRoot(), store: store)
                self.codexScanner = CodexUsageScanner(
                    sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), store: store)
                self.opencodeScanner = OpencodeUsageScanner(
                    dbPath: OpencodePaths.db(), store: store)
                self.grokScanner = GrokUsageScanner(
                    sessionsRoot: GrokPaths.sessionsRoot(), store: store)
                self.kimiScanner = KimiUsageScanner(
                    sessionsRoot: KimiPaths.sessionsRoot(), store: store)
                self.geminiScanner = GeminiUsageScanner(
                    tmpRoot: GeminiPaths.tmpRoot(),
                    projectsFile: GeminiPaths.projectsFile(), store: store)
                self.qwenScanner = QwenUsageScanner(
                    projectsRoot: QwenPaths.projectsRoot(), store: store)
                // hermes: tokens/cost are all in state.db (including each profile's separate DB)
                self.hermesScanner = HermesUsageScanner(
                    stateDBs: { HermesPaths.allStateDBs() }, store: store)
                // codebuddy: tokens are in the function_call lines of projects/**/*.jsonl
                // (qoder's CN backend reports all-zero tokens, so it has no usage scanner)
                self.codeBuddyScanner = CodeBuddyUsageScanner(
                    projectsRoot: CodeBuddyPaths.projectsRoot(), store: store)
                // cursor: tokens are in state.vscdb's assistant bubbles, with cache attributed by
                // adjacent differencing (cost is always 0 -- the cursor/ prefix is marked unknown
                // in pricing.json, see the scanner's header comment)
                self.cursorScanner = CursorUsageScanner(
                    dbPath: CursorPaths.globalStateDB(), store: store,
                    workspaceStorageRoot: CursorPaths.workspaceStorageRoot(),
                    sessions: { now in
                        // Full history: each composer has its own watermark, so revisiting old
                        // sessions costs almost nothing; truncating at 30 days would mean Cursor
                        // usage older than a month never enters the ledger
                        CursorSessionIndexer.index(
                            window: CursorSessionIndexer.fullHistoryWindow,
                            maxSessions: 2000, now: now)
                            .map { ($0.id, $0.cwd, $0.lastActiveAt) }
                    })
                // zcode: tokens are in the model_io lines of cli/rollout (including subagent
                // streams)
                self.zcodeScanner = ZcodeUsageScanner(
                    rolloutRoot: ZcodePaths.rolloutRoot(),
                    dbPath: ZcodePaths.db(), store: store)
                try? self.zcodeScanner?.recordPromptCounts()
                self.antigravityScanner = AntigravityUsageScanner(
                    conversationsRoot: AntigravityPaths.conversationsRoot(), store: store,
                    cwdResolver: { AntigravityPaths.cwd(dbURL: $0) })
                self.searchIndexer = TranscriptSearchIndexer(store: store)
                // First index pass ~90s after launch: the first seconds belong to the usage backfill
                // and the pages the user opens, not to parsing every transcript for search
                self.lastIndexRun = Date().addingTimeInterval(-Self.indexInterval + 90)
                PricingCatalogStore.shared.loadIfNeeded(paths: .app)
                self.scanAndPublish()
            } catch {
                self.publish { $0.lastError = L10n.format("Failed to open database: %@", zhHans: "数据库打开失败: %@", String(describing: error)) }
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power
        timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.scanAndPublish() }
        timer.resume()
        self.timer = timer
    }

    /// Opens the existing SQLite store on the service queue without starting background usage
    /// scanners. Used by offscreen preview rendering to read persisted skill/MCP/agent stats.
    func openStoreForPreview() {
        queue.async { [weak self] in
            guard let self, self.store == nil else { return }
            self.store = try? EurekaStore(path: EurekaStore.defaultURL())
        }
    }

    /// Aggregates a weekly report ([weekStart, weekEnd)) and publishes it to weeklyReport when done
    func loadWeeklyReport(weekStart: Date, weekEnd: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let report = try? WeeklyReportBuilder.build(
                store: store, pricing: self.pricing,
                weekStart: weekStart, weekEnd: weekEnd)
            self.publish { $0.weeklyReport = report }
        }
    }

    /// Callback after the knowledge index is cleared (AppDelegate wires it to trigger a reindex --
    /// the knowledge side is only driven by lastScanAt events, so after clearing no timer heals it;
    /// it must be kicked explicitly)
    var onSearchIndexCleared: (() -> Void)?

    /// Clears the full-text index (Settings' "Clear full-text index"; the next scan rebuilds it
    /// automatically per the toggle)
    func clearSearchIndex() {
        queue.async { [weak self] in
            try? self?.store?.search.clearAll()
            try? self?.store?.knowledge.clearAll()
            DispatchQueue.main.async { self?.onSearchIndexCleared?() }
        }
    }

    /// Task finished → write history (state machine side effect, called on the main thread)
    func recordFinished(_ task: FinishedTask) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.history.insert(task)
            self.publishHistory(store: store)
        }
    }

    /// Records "which terminal a session runs in". Same-key upsert, so calling it on every event
    /// doesn't grow the table. Stale/backlogged events are recorded too: terminal ownership is a
    /// historical fact, treated the same as history writes.
    func recordTerminal(
        source: AgentSource, sessionId: String, binding: TerminalBinding, at: Date
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.sessionTerminals.record(
                source: source, sessionId: sessionId, binding: binding, at: at)
        }
    }

    /// Proactively refreshes once when the popover opens
    func refreshNow() {
        scanQueuedLock.lock()
        defer { scanQueuedLock.unlock() }
        guard !scanQueued else { return }
        scanQueued = true
        queue.async { [weak self] in
            guard let self else { return }
            self.scanQueuedLock.lock()
            self.scanQueued = false
            self.scanQueuedLock.unlock()
            self.scanAndPublish()
        }
    }

    /// Scans every (source, model, provider) seen in the ledger and picks out unpriced and
    /// estimated ones (called when the settings page opens)
    func loadPricingDiagnostics() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let pricing = self.pricing
            let rows = ((try? store.usage.distinctModels()) ?? []).compactMap { totals -> PricingDiagnostic? in
                let resolution = pricing.resolution(for: totals.model, provider: totals.provider)
                guard resolution.price == nil || resolution.estimated else { return nil }
                return PricingDiagnostic(
                    source: totals.source, model: totals.model, provider: totals.provider,
                    tokens: totals.inputTokens + totals.outputTokens
                        + totals.cacheCreationTokens + totals.cacheReadTokens,
                    resolution: resolution)
            }
            .sorted { $0.tokens > $1.tokens }
            self.publish { $0.pricingDiagnostics = rows }
        }
    }

    /// The price table changed (remote catalog arrived / user edited pricing.json): costs are
    /// computed at read time, so republishing summaries is enough; incrementing pricingRevision
    /// makes the dashboard's .onChange reload details
    func pricingDidChange() {
        pricingRevision += 1
        refreshNow()
    }

    /// Paged loading of the request log (page starts at 1); row costs are converted via the price
    /// table
    func loadRecords(
        page: Int, pageSize: Int = 50, source: AgentSource?, from: Date, to: Date
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let total = try store.usage.recordCount(from: from, to: to, source: source)
                let rows = try store.usage.recentRecords(
                    from: from, to: to, source: source,
                    limit: pageSize, offset: (max(1, page) - 1) * pageSize)
                let displays = rows.map { row in
                    RecordDisplay(row: row, costUSD: self.pricing.cost(of: UsageTotals(
                        source: row.source, model: row.model,
                        inputTokens: row.inputTokens, outputTokens: row.outputTokens,
                        cacheCreationTokens: row.cacheCreationTokens,
                        cacheCreation1hTokens: row.cacheCreation1hTokens,
                        cacheReadTokens: row.cacheReadTokens, requestCount: 1,
                        provider: row.provider, reportedCostUSD: row.reportedCostUSD)))
                }
                self.publish {
                    $0.records = displays
                    $0.recordTotal = total
                }
            } catch {
                self.publish { $0.lastError = L10n.format("Failed to read request log: %@", zhHans: "读取请求日志失败: %@", String(describing: error)) }
            }
        }
    }

    /// Aggregates the token/cost trend by (time bucket, source) over the selected range (the
    /// chart's "by date", following the range). Ranges ≤48h (today/short custom) switch to hourly
    /// granularity; cost must be priced at model granularity before folding.
    func loadTrend(from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let hourly = to.timeIntervalSince(from) <= 2 * 86400
            let granularity: UsageRepo.TrendGranularity = hourly ? .hour : .day
            let rows = (try? store.usage.dailyRows(
                from: from, to: to, granularity: granularity)) ?? []
            let formatter = DateFormatter()
            formatter.dateFormat = hourly ? "yyyy-MM-dd HH:mm" : "yyyy-MM-dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            // (bucket string, source) → token/cost sums (rows are model-granular; cost is computed
            // per row, then accumulated)
            var buckets: [String: [AgentSource: (tokens: Int, requests: Int, cost: Double)]] = [:]
            for row in rows {
                let t = row.totals
                let total = t.inputTokens + t.outputTokens
                    + t.cacheCreationTokens + t.cacheReadTokens
                var entry = buckets[row.day, default: [:]][t.source]
                    ?? (tokens: 0, requests: 0, cost: 0)
                entry.tokens += total
                entry.requests += t.requestCount
                entry.cost += self.pricing.cost(of: t) ?? 0
                buckets[row.day, default: [:]][t.source] = entry
            }
            var points: [TrendPoint] = []
            for (bucketString, bySource) in buckets {
                guard let bucket = formatter.date(from: bucketString) else { continue }
                for (source, entry) in bySource where entry.tokens > 0 {
                    points.append(TrendPoint(
                        bucket: bucket, source: source,
                        tokens: entry.tokens, requests: entry.requests, costUSD: entry.cost))
                }
            }
            points.sort { $0.bucket < $1.bucket }
            self.publish {
                $0.trend = points
                $0.trendIsHourly = hourly
            }
        }
    }

    /// Per-session usage ranking (selected range/source; folded by sessionId, cost computed per
    /// model row, top 50 by tokens descending)
    func loadSessionTotals(from: Date, to: Date, source: AgentSource?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = (try? store.usage.totalsBySession(
                from: from, to: to, source: source)) ?? []
            var bySession: [String: SessionTotal] = [:]
            for row in rows {
                let t = row.totals
                let tokens = t.inputTokens + t.outputTokens
                    + t.cacheCreationTokens + t.cacheReadTokens
                let cost = self.pricing.cost(of: t)
                var entry = bySession[row.sessionId] ?? SessionTotal(
                    sessionId: row.sessionId, source: t.source, project: row.project,
                    lastActiveAt: row.lastTs, tokens: 0, requests: 0, costUSD: nil)
                entry.tokens += tokens
                entry.requests += t.requestCount
                entry.lastActiveAt = max(entry.lastActiveAt, row.lastTs)
                if let cost { entry.costUSD = (entry.costUSD ?? 0) + cost }
                if entry.project == nil { entry.project = row.project }
                bySession[row.sessionId] = entry
            }
            let result = Array(
                bySession.values.sorted { $0.tokens > $1.tokens }.prefix(50))
            self.publish { $0.sessionTotals = result }
        }
    }

    /// Active-hours heatmap (selected range/source, weekday × 24h in one SQL aggregation)
    func loadHeatmap(from: Date, to: Date, source: AgentSource?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let cells = (try? store.usage.hourlyHeatmap(
                from: from, to: to, source: source)) ?? []
            self.publish { $0.heatmapCells = cells }
        }
    }

    /// Tool/skill/plugin call stats (selected range/source, count descending)
    func loadToolCalls(source: AgentSource?, from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let totals = (try? store.toolCalls.totals(
                from: from, to: to, source: source)) ?? []
            self.publish { $0.toolCallTotals = totals }
        }
    }

    /// All-time skill stats (matched by skill cards' "last active" and the detail page;
    /// kind='skill', total count descending). Hermes's message stream has no skill-call events (the
    /// audit stream can never cover it), so rows are filled from its own `skills/.usage.json`
    /// counts; when a same-name audit row exists, the audit row wins.
    func loadSkillStats(source: AgentSource? = nil) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            var stats = (try? store.toolCalls.skillStats(source: source)) ?? []
            if source == nil || source == .hermes {
                let counted = Set(stats.filter { $0.source == .hermes }.map(\.name))
                let extras = HermesSkillUsage.read(
                    url: HermesPaths.skillsRoot().appendingPathComponent(".usage.json"))
                    .filter { !counted.contains($0.slug) }
                    .map {
                        ToolCallsRepo.SkillUsageStat(
                            source: .hermes, name: $0.slug, count: $0.useCount,
                            lastTs: $0.lastUsedAt, tokens: 0)
                    }
                stats.append(contentsOf: extras)
            }
            self.publish { $0.skillStats = stats }
        }
    }

    /// MCP calls aggregated by server (MCP page "N calls / last used / idle hint"). Raw name
    /// shapes: codex/kimi `server.tool` (take the prefix before the first .), Claude
    /// `mcp__server__tool`.
    func loadMCPStats() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let totals = (try? store.toolCalls.mcpNameTotals()) ?? []
            var stats: [String: MCPServerCallStat] = [:]
            for total in totals {
                let key = Self.mcpServerKey(total.name)
                guard !key.isEmpty else { continue }
                var stat = stats[key] ?? MCPServerCallStat(calls: 0, lastTs: 0)
                stat.calls += total.count
                stat.lastTs = max(stat.lastTs, total.lastTs)
                stats[key] = stat
            }
            self.publish { $0.mcpServerStats = stats }
        }
    }

    /// `server.tool` / `mcp__server__tool` → server name (lowercase)
    static func mcpServerKey(_ raw: String) -> String {
        if raw.hasPrefix("mcp__") {
            let rest = raw.dropFirst("mcp__".count)
            return rest.components(separatedBy: "__").first?.lowercased() ?? ""
        }
        return raw.split(separator: ".").first.map { String($0).lowercased() } ?? ""
    }

    /// Call activity of one MCP server (detail page "call activity" card): daily series over the
    /// last N days + top tools
    struct MCPServerActivity {
        /// N consecutive days (old → new, days without calls filled with 0), day is that day's
        /// midnight
        var series: [(day: Date, count: Int)]
        /// All-time top tools (count descending; tool name = raw name minus the server prefix)
        var topTools: [(name: String, count: Int)]
    }

    /// Tool name: raw name minus the server prefix (`mcp__s__t` → t; `s.t` → t; unchanged without a
    /// prefix)
    static func mcpToolLabel(_ raw: String) -> String {
        if raw.hasPrefix("mcp__") {
            let parts = raw.components(separatedBy: "__")
            return parts.count >= 3 ? parts[2...] .joined(separator: "__") : raw
        }
        if let dot = raw.firstIndex(of: "."), dot != raw.startIndex {
            return String(raw[raw.index(after: dot)...])
        }
        return raw
    }

    func loadMCPServerActivity(
        server: String, days: Int = 30,
        completion: @escaping (MCPServerActivity?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let rows = (try? store.toolCalls.mcpDailyTotals()) ?? []
            let key = server.lowercased()
            var byDay: [String: Int] = [:]
            var byTool: [String: Int] = [:]
            for row in rows {
                guard Self.mcpServerKey(row.name) == key else { continue }
                byDay[row.day, default: 0] += row.count
                byTool[Self.mcpToolLabel(row.name), default: 0] += row.count
            }
            // Zero-filled series of N consecutive days (old → new): same local yyyy-MM-dd as the
            // scanners write to the DB
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            let calendar = Calendar.current
            let today = calendar.startOfDay(for: Date())
            var series: [(day: Date, count: Int)] = []
            for offset in stride(from: days - 1, through: 0, by: -1) {
                guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
                series.append((day, byDay[formatter.string(from: day)] ?? 0))
            }
            let topTools = byTool.sorted { $0.value > $1.value }.prefix(5)
                .map { (name: $0.key, count: $0.value) }
            let activity = MCPServerActivity(series: series, topTools: topTools)
            DispatchQueue.main.async { completion(activity) }
        }
    }

    /// All-time subagent call stats (Agents page "called N times"; kind='agent', total count
    /// descending)
    func loadAgentStats(source: AgentSource? = nil) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let stats = (try? store.toolCalls.agentStats(source: source)) ?? []
            self.publish { $0.agentStats = stats }
        }
    }

    /// Top skill ranking (Skills page analysis card): date window from the time period + source
    /// filter
    func loadSkillRanking(source: AgentSource? = nil, from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let stats = (try? store.toolCalls.skillStats(
                source: source, from: from, to: to)) ?? []
            self.publish { $0.skillRanking = stats }
        }
    }

    /// A skill's call rank this week (detail page "this week's rank #N"; callback on the main
    /// thread, doesn't touch the list page's ranking state)
    func loadSkillWeeklyRank(
        source: AgentSource, name: String,
        completion: @escaping (Int?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let from = DashboardPeriod.week.startDate
            let stats = (try? store.toolCalls.skillStats(source: nil, from: from, to: Date())) ?? []
            let key = SkillMemoryService.normalizeSkillName(name)
            let rank = stats.firstIndex {
                $0.source == source && SkillMemoryService.normalizeSkillName($0.name) == key
            }.map { $0 + 1 }
            DispatchQueue.main.async { completion(rank) }
        }
    }

    /// A skill's daily call series (detail page trend chart; callback on the main thread, avoiding
    /// cross-skill published-state bleed)
    func loadSkillDailySeries(
        source: AgentSource, name: String, from: Date, to: Date,
        completion: @escaping ([SkillDayCount]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let series = (try? store.toolCalls.dailySeries(
                source: source, kind: "skill", name: name, from: from, to: to)) ?? []
            let points = series.map { SkillDayCount(day: $0.day, count: $0.count) }
            DispatchQueue.main.async { completion(points) }
        }
    }

    /// Sessions that recently called a skill (detail page "recent sessions" card; callback on the
    /// main thread)
    func loadSkillSessions(
        source: AgentSource, name: String, limit: Int = 8,
        completion: @escaping ([(sessionId: String, lastTs: Date, count: Int)]) -> Void
    ) {
        queue.async { [weak self] in
            guard let self, let store = self.store else {
                DispatchQueue.main.async { completion([]) }
                return
            }
            let rows = (try? store.toolCalls.recentSkillSessions(
                source: source, name: name, limit: limit)) ?? []
            DispatchQueue.main.async { completion(rows) }
        }
    }

    /// Model stats (full breakdown for the selected range, by tokens descending) -- also the data
    /// source for the hero card/four tiles/hit rate
    func loadModelTotals(from: Date, to: Date) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let totals = (try? store.usage.totalsByModel(from: from, to: to)) ?? []
            let sorted = totals.sorted {
                ($0.inputTokens + $0.outputTokens + $0.cacheReadTokens + $0.cacheCreationTokens)
                    > ($1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens)
            }
            self.publish { $0.modelTotals = sorted }
        }
    }

    /// Project table for the selected range: tokens + cost folded per project, tokens
    /// descending. `source` nil = every source.
    func loadProjectTotals(from: Date, to: Date, source: AgentSource? = nil) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = (try? store.usage.totalsByProject(from: from, to: to, source: source)) ?? []
            var byProject: [String: (tokens: Int, requests: Int, cost: Double?)] = [:]
            for (project, totals) in rows {
                let name = project ?? L10n.text("(Unknown project)", zhHans: "（未知项目）")
                let tokens = totals.inputTokens + totals.outputTokens
                    + totals.cacheCreationTokens + totals.cacheReadTokens
                let cost = self.pricing.cost(of: totals)
                var entry = byProject[name] ?? (0, 0, nil)
                entry.tokens += tokens
                entry.requests += totals.requestCount
                if let cost { entry.cost = (entry.cost ?? 0) + cost }
                byProject[name] = entry
            }
            let result = byProject
                .map {
                    ProjectTotal(
                        name: $0.key, tokens: $0.value.tokens,
                        requests: $0.value.requests, costUSD: $0.value.cost)
                }
                .sorted { $0.tokens > $1.tokens }
            self.publish { $0.projectTotals = result }
        }
    }

    /// Comparison-range model stats (hero card deltas); nil range clears them
    func loadComparisonTotals(from: Date?, to: Date?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            guard let from, let to else {
                self.publish { $0.comparisonTotals = nil }
                return
            }
            let totals = (try? store.usage.totalsByModel(from: from, to: to)) ?? []
            self.publish { $0.comparisonTotals = totals }
        }
    }

    /// Row cost conversion (for the model stats total row)
    func cost(of totals: UsageTotals) -> Double? {
        pricing.cost(of: totals)
    }

    /// Headline metrics of a set of aggregates, priced with the current table
    func metrics(of totals: [UsageTotals]) -> UsageMetrics {
        UsageMetrics(totals: totals, pricing: pricing)
    }

    /// Price provenance (hover on the dashboard's cost cell)
    func priceResolution(of totals: UsageTotals) -> PriceResolution {
        pricing.resolution(of: totals)
    }

    /// Exports the last 30 days of usage as CSV to ~/Downloads and reveals it in Finder
    func exportCSV() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let now = Date()
                let rows = try store.usage.dailyRows(
                    from: now.addingTimeInterval(-30 * 86400), to: now)
                var csv = "date,source,model,project,input_tokens,output_tokens,"
                    + "cache_write_tokens,cache_read_tokens,requests,est_cost_usd\n"
                for row in rows {
                    let cost = self.pricing.cost(of: row.totals)
                        .map { String(format: "%.4f", $0) } ?? ""
                    let project = row.project.replacingOccurrences(of: ",", with: "_")
                    csv += "\(row.day),\(row.totals.source.rawValue),\(row.totals.model),"
                        + "\(project),\(row.totals.inputTokens),\(row.totals.outputTokens),"
                        + "\(row.totals.cacheCreationTokens),\(row.totals.cacheReadTokens),"
                        + "\(row.totals.requestCount),\(cost)\n"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Downloads/eureka-usage-\(formatter.string(from: now)).csv")
                try Data(csv.utf8).write(to: url)
                self.publish { $0.exportMessage = L10n.format("Exported %@", zhHans: "已导出 %@", String(url.lastPathComponent)) }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.publish { $0.exportMessage = L10n.format("Export failed: %@", zhHans: "导出失败: %@", String(describing: error)) }
            }
        }
    }

    // MARK: - Queue internals

    private func scanAndPublish() {
        guard let store else { return }
        do {
            let claudeNew = try autoreleasepool { try claudeScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.claudeHealthName)
            if claudeNew > 0 { HealthRegistry.shared.event(Self.claudeHealthName) }
            let codexNew = try autoreleasepool { try codexScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.codexHealthName)
            if codexNew > 0 { HealthRegistry.shared.event(Self.codexHealthName) }
            let opencodeNew = try autoreleasepool { try opencodeScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.opencodeHealthName)
            if opencodeNew > 0 { HealthRegistry.shared.event(Self.opencodeHealthName) }
            let grokNew = try autoreleasepool { try grokScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.grokHealthName)
            if grokNew > 0 { HealthRegistry.shared.event(Self.grokHealthName) }
            let kimiNew = try autoreleasepool { try kimiScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.kimiHealthName)
            if kimiNew > 0 { HealthRegistry.shared.event(Self.kimiHealthName) }
            let geminiNew = try autoreleasepool { try geminiScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.geminiHealthName)
            if geminiNew > 0 { HealthRegistry.shared.event(Self.geminiHealthName) }
            let qwenNew = try autoreleasepool { try qwenScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.qwenHealthName)
            if qwenNew > 0 { HealthRegistry.shared.event(Self.qwenHealthName) }
            let hermesNew = try autoreleasepool { try hermesScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.hermesHealthName)
            if hermesNew > 0 { HealthRegistry.shared.event(Self.hermesHealthName) }
            let codeBuddyNew = try autoreleasepool { try codeBuddyScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.codeBuddyHealthName)
            if codeBuddyNew > 0 { HealthRegistry.shared.event(Self.codeBuddyHealthName) }
            let cursorNew = try autoreleasepool { try cursorScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.cursorHealthName)
            if cursorNew > 0 { HealthRegistry.shared.event(Self.cursorHealthName) }
            let zcodeNew = try autoreleasepool { try zcodeScanner?.scanOnce() ?? 0 }
            HealthRegistry.shared.beat(Self.zcodeHealthName)
            if zcodeNew > 0 { HealthRegistry.shared.event(Self.zcodeHealthName) }
            try? zcodeScanner?.recordPromptCounts()
            if AntigravityExperiment.isEnabled {
                if !antigravityHealthRegistered {
                    antigravityHealthRegistered = true
                    HealthRegistry.shared.register(Self.antigravityHealthName, expectedInterval: 60)
                }
                // Experimental source: a parse failure is only recorded in health, never aborting
                // the whole scan
                do {
                    let agyNew = try autoreleasepool { try antigravityScanner?.scanOnce() ?? 0 }
                    HealthRegistry.shared.beat(Self.antigravityHealthName)
                    if agyNew > 0 { HealthRegistry.shared.event(Self.antigravityHealthName) }
                } catch {
                    HealthRegistry.shared.failure(Self.antigravityHealthName, note: "\(error)")
                }
            }
            try store.scanState.pruneDedupKeys(
                before: Date().addingTimeInterval(-8 * 86400))
            let summary = try UsageAggregator.summarize(store: store, pricing: pricing)
            // One successful pass clears the previous error: occasional lock contention (during
            // launch warm-up/large-file indexing, another connection's write transaction exceeds
            // busy_timeout) recovers by the next pass, so the red text shouldn't linger.
            // Published before full-text indexing, which on a first install is the longest step
            // and used to keep the dashboard on its spinner until it finished.
            publish { $0.summary = summary; $0.lastError = nil }
            publishHistory(store: store)
            publishMonthOverview(store: store)
            indexIfDue()
        } catch {
            HealthRegistry.shared.failure(Self.claudeHealthName, note: "\(error)")
            publish { $0.lastError = L10n.format("Scan failed: %@", zhHans: "扫描失败: %@", String(describing: error)) }
        }
    }

    /// Full-text indexing does **not run at usage's cadence** (see indexInterval), except while a
    /// capped pass left a backlog: then every scan tick takes the next batch, newest sessions
    /// first, reusing one discovery.
    private func indexIfDue() {
        guard UserDefaults.standard.object(forKey: "fullTextSearchEnabled") as? Bool ?? true,
              let searchIndexer
        else { return }
        let now = Date()
        let catchingUp = indexBacklog != nil
        guard catchingUp || now.timeIntervalSince(lastIndexRun) >= Self.indexInterval else { return }
        lastIndexRun = now
        let sessions: [AgentSessionInfo]
        if let backlog = indexBacklog, now.timeIntervalSince(backlog.at) < 600 {
            sessions = backlog.sessions
        } else {
            sessions = AgentSessionDiscovery.forIndexing()
        }
        searchIndexer.indexOnce(sessions: sessions, maxRebuilds: Self.indexBatch)
        indexBacklog = searchIndexer.lastPassTruncated ? (sessions, indexBacklog?.at ?? now) : nil
    }

    private func publishMonthOverview(store: EurekaStore) {
        let now = Date()
        guard let month = Calendar.current.dateInterval(of: .month, for: now) else { return }
        let monthRows = (try? store.usage.totalsByModel(from: month.start, to: now)) ?? []
        let weekRows = (try? store.usage.totalsByModel(
            from: now.addingTimeInterval(-7 * 86_400), to: now)) ?? []
        var bySource: [AgentSource: Double] = [:]
        for row in monthRows {
            if let cost = pricing.cost(of: row) { bySource[row.source, default: 0] += cost }
        }
        let monthToDate = bySource.values.reduce(0, +)
        let trailing = weekRows.compactMap { pricing.cost(of: $0) }.reduce(0, +)
        let overview = MonthOverview(
            monthToDate: monthToDate, trailingSevenDays: trailing, bySource: bySource,
            projected: MonthForecast.projected(
                monthToDate: monthToDate, trailingSevenDays: trailing, now: now))
        publish { $0.monthOverview = overview }
    }

    /// Turn card: prompts asked in the range, with their evaluated duration / outcome
    func loadTurnSummary(from: Date, to: Date, source: AgentSource?) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            let rows = (try? store.prompts.turnRows(from: from, to: to, source: source)) ?? []
            let summary = TurnSummary(rows: rows)
            self.publish { $0.turnSummary = summary }
        }
    }

    /// Cost split by token type for a set of aggregates (dashboard cost-structure card)
    func costBreakdown(of totals: [UsageTotals]) -> CostBreakdown {
        CostBreakdown(totals: totals, pricing: pricing)
    }

    /// History page window: last 14 days, capped at 200 entries (replacing the old fixed 50)
    private static let historyWindow: TimeInterval = 14 * 86400
    private static let historyLimit = 200

    private func publishHistory(store: EurekaStore) {
        let since = Date().addingTimeInterval(-Self.historyWindow)
        let history = (try? store.history.tasks(since: since, limit: Self.historyLimit)) ?? []
        let dailyRows = (try? store.history.dailyOutcomeCounts(since: since)) ?? []
        // Token totals associated by session (session_id → sum of the four token segments)
        var tokensBySession: [String: Int] = [:]
        if let totals = try? store.usage.totalsForSessions(history.map(\.sessionId)) {
            for (sessionId, rows) in totals {
                tokensBySession[sessionId] = rows.reduce(0) {
                    $0 + $1.inputTokens + $1.outputTokens
                        + $1.cacheReadTokens + $1.cacheCreationTokens
                }
            }
        }
        let dayFormatter = Self.historyDayFormatter
        let daily = dailyRows.compactMap { row -> (day: Date, outcome: TaskOutcome, count: Int)? in
            guard let day = dayFormatter.date(from: row.day),
                  let outcome = TaskOutcome(rawValue: row.outcome)
            else { return nil }
            return (day, outcome, row.count)
        }
        publish {
            $0.recentHistory = history
            $0.historyDailyOutcomes = daily
            $0.historyTokens = tokensBySession
        }
    }

    /// Date parsing for the history page's per-day aggregation (dailyOutcomeCounts' '%Y-%m-%d'
    /// local-time-zone strings)
    private static let historyDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Running-task push (AppDelegate calls it synchronously on .activeTasksChanged, main thread)
    func publishRunningTasks(_ tasks: [AgentTask]) {
        runningTasks = tasks
    }

    /// Exports the history page's current window (last 14 days) as CSV to ~/Downloads and reveals
    /// it in Finder. Columns: outcome/title/source/project/start time/end time/duration/Tokens
    /// (same pattern as AuditService.exportCSV).
    func exportHistoryCSV() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let since = Date().addingTimeInterval(-Self.historyWindow)
                let tasks = try store.history.tasks(since: since, limit: Self.historyLimit)
                let totals = (try? store.usage.totalsForSessions(
                    tasks.map(\.sessionId))) ?? [:]
                let isoFormatter = ISO8601DateFormatter()
                var csv = L10n.text(
                    "Outcome,Title,Source,Project,Started,Finished,Duration seconds,Tokens\n",
                    zhHans: "结局,标题,来源,项目,开始时间,结束时间,耗时秒,Tokens\n")
                for task in tasks {
                    let tokens = totals[task.sessionId]?.reduce(0) {
                        $0 + $1.inputTokens + $1.outputTokens
                            + $1.cacheReadTokens + $1.cacheCreationTokens
                    }
                    csv += [
                        task.outcome.label,
                        Self.csvField(task.title ?? ""),
                        task.source.displayName,
                        Self.csvField(task.projectName ?? ""),
                        (task.sessionStartedAt ?? task.startedAt)
                            .map { isoFormatter.string(from: $0) } ?? "",
                        isoFormatter.string(from: task.finishedAt),
                        task.duration.map { String(format: "%.0f", $0) } ?? "",
                        tokens.map(String.init) ?? "",
                    ].joined(separator: ",") + "\n"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Downloads/eureka-history-\(formatter.string(from: Date())).csv")
                try Data(csv.utf8).write(to: url)
                self.publish {
                    $0.exportMessage = L10n.format("Exported %@ (%@ records)", zhHans: "已导出 %@（%@ 条）", String(url.lastPathComponent), String(tasks.count))
                }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.publish { $0.exportMessage = L10n.format("Export failed: %@", zhHans: "导出失败: %@", String(describing: error)) }
            }
        }
    }

    /// CSV field escaping (quoted when containing commas/quotes/newlines)
    private static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func publish(_ apply: @escaping (UsageService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }
}
