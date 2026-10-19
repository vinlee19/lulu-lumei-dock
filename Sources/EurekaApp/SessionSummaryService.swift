import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSummary
import Foundation

/// App-side face of AI session summaries (issue #12): wraps `SessionSummaryCoordinator`,
/// republishes its updates on the main thread, remembers the executor choice, and answers the
/// questions the session views ask (what is running, what is saved, is it stale).
///
/// Runs live here, not in a view, so they keep going while the user switches sessions, changes
/// pages or closes the main window.
final class SessionSummaryService: ObservableObject {
    static let shared = SessionSummaryService()

    /// Compact status for a session row
    enum RowStatus: Equatable {
        case running
        case completed
        case failed
    }

    /// Whether the saved summary still matches the conversation
    enum Freshness: Equatable {
        case unknown
        case current
        /// The conversation changed; `newMessages` > 0 when it grew
        case stale(newMessages: Int)
    }

    /// Detail-pane tab request from outside the detail view (row context menu)
    struct TabRequest: Equatable {
        let sessionKey: String
        let serial: Int
    }

    @Published private(set) var live: [String: SummaryLiveState] = [:]
    /// Latest successful summary per session (loaded on demand)
    @Published private(set) var completed: [String: SummaryRunRecord] = [:]
    /// Most recent finished run per session (may be a failure newer than `completed`)
    @Published private(set) var lastFinished: [String: SummaryRunRecord] = [:]
    @Published private(set) var rowStatus: [String: RowStatus] = [:]
    @Published private(set) var availability: [SummaryExecutorKind: SummaryExecutorAvailability] = [:]
    @Published private(set) var probing = false
    @Published private(set) var freshness: [String: Freshness] = [:]
    @Published private(set) var tabRequest: TabRequest?
    /// Last selected executor (nil until first use, which opens the selector instead)
    @Published var preferredExecutor: SummaryExecutorKind? {
        didSet { defaults.set(preferredExecutor?.rawValue, forKey: Self.executorKey) }
    }
    /// Optional `--model` per executor (empty = the CLI's own default)
    @Published var models: [SummaryExecutorKind: String] {
        didSet {
            defaults.set(
                Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }),
                forKey: Self.modelsKey)
        }
    }

    private static let executorKey = "sessionSummaryExecutor"
    private static let modelsKey = "sessionSummaryModels"
    private let defaults: UserDefaults
    private let resolver = SummaryExecutorResolver()
    private let queue = DispatchQueue(label: "com.vinlee.eureka.summary-service", qos: .utility)
    private var coordinator: SessionSummaryCoordinator?
    private var started = false
    private var tabSerial = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferredExecutor = defaults.string(forKey: Self.executorKey)
            .flatMap(SummaryExecutorKind.init(rawValue:))
        let stored = defaults.dictionary(forKey: Self.modelsKey) as? [String: String] ?? [:]
        models = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            SummaryExecutorKind(rawValue: key).map { ($0, value) }
        })
    }

    // MARK: - Lifecycle

    /// Opens the store, reconciles runs a previous process left unfinished, loads row status and
    /// probes the executors. Idempotent.
    func start() {
        guard !started else { return }
        started = true
        queue.async { [weak self] in
            guard let self, let store = Self.openStore() else { return }
            let coordinator = SessionSummaryCoordinator(
                store: store, launcher: PosixSummaryProcessLauncher(),
                executors: { [weak self] kind in
                    let adapter = Self.adapter(for: kind)
                    let availability = self?.resolver.availability(for: kind, adapter: adapter)
                        ?? SummaryExecutorAvailability(kind: kind, executor: nil, reason: nil)
                    return (availability, adapter)
                },
                onUpdate: { [weak self] update in
                    DispatchQueue.main.async { self?.apply(update) }
                })
            coordinator.reconcileOnLaunch()
            let status = coordinator.statusBySession()
            DispatchQueue.main.async {
                self.coordinator = coordinator
                self.rowStatus = status.compactMapValues(Self.rowStatus)
            }
            self.probeExecutors()
        }
    }

    /// The usage service may still be migrating at launch; retry a few times before giving up
    private static func openStore() -> EurekaStore? {
        for attempt in 0..<5 {
            if let store = try? EurekaStore(path: EurekaStore.defaultURL()) { return store }
            Thread.sleep(forTimeInterval: Double(attempt + 1))
        }
        return nil
    }

    /// App exit: stop managed processes and keep drafts
    func shutdown() {
        coordinator?.shutdown(timeout: 4)
    }

    private static func adapter(for kind: SummaryExecutorKind) -> SummaryExecutorAdapter {
        guard kind == .codex else { return SummaryAdapters.adapter(for: kind) }
        // Codex merges `-c mcp_servers={}`; servers are disabled one by one by name (section
        // headers only, via the existing MCP config indexer)
        let names: [String]
        if let url = MCPConfigIndexer.globalConfigURL(for: .codex),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            names = MCPConfigIndexer.parseTOMLServers(text, source: .codex, configPath: url.path)
                .map(\.name)
        } else {
            names = []
        }
        return SummaryAdapters.adapter(for: .codex, codexMCPServers: names)
    }

    func refreshExecutors() {
        resolver.invalidate()
        queue.async { [weak self] in self?.probeExecutors() }
    }

    /// Call on `queue`
    private func probeExecutors() {
        DispatchQueue.main.async { self.probing = true }
        var results: [SummaryExecutorKind: SummaryExecutorAvailability] = [:]
        for kind in SummaryExecutorKind.allCases {
            results[kind] = resolver.availability(for: kind, adapter: Self.adapter(for: kind))
        }
        DispatchQueue.main.async {
            self.availability = results
            self.probing = false
        }
    }

    private static func rowStatus(_ entry: (latest: SummaryStage, hasCompleted: Bool)) -> RowStatus? {
        if entry.latest.isActive { return nil }  // reconciled already; a live run sets .running
        if entry.hasCompleted { return .completed }
        return entry.latest == .failed ? .failed : nil
    }

    // MARK: - Updates from the coordinator (main thread)

    private func apply(_ update: SessionSummaryCoordinator.Update) {
        switch update {
        case .live(let state):
            // Run-id guard: a late event of an older run never overwrites a newer one
            if let current = live[state.sessionKey], current.runId != state.runId,
               current.startedAt > state.startedAt {
                return
            }
            live[state.sessionKey] = state
            rowStatus[state.sessionKey] = .running
        case .finished(let record):
            let key = record.sessionKey
            if live[key]?.runId == record.id { live[key] = nil }
            lastFinished[key] = record
            if record.status == .completed {
                completed[key] = record
                freshness[key] = .current
                rowStatus[key] = .completed
            } else {
                rowStatus[key] = completed[key] != nil || rowStatus[key] == .completed
                    ? .completed : (record.status == .failed ? .failed : nil)
            }
        }
    }

    // MARK: - Queries and actions

    func isSupported(_ session: AgentSessionInfo) -> Bool {
        SummarySourceSupport.unsupportedReason(session.source) == nil
    }

    func key(_ session: AgentSessionInfo) -> String {
        AgentTask.key(source: session.source, sessionId: session.id)
    }

    /// Loads the saved summary and the last run for a session (on selection)
    func load(_ session: AgentSessionInfo) {
        let key = key(session)
        queue.async { [weak self] in
            guard let self, let coordinator = self.coordinator else { return }
            let latest = coordinator.latestCompleted(source: session.source, sessionId: session.id)
            let last = coordinator.history(source: session.source, sessionId: session.id)
                .first { $0.status.isTerminal }
            DispatchQueue.main.async {
                if let latest { self.completed[key] = latest } else { self.completed[key] = nil }
                self.lastFinished[key] = last
            }
        }
    }

    /// Starts a summary (or reveals the run already active for this session)
    @discardableResult
    func summarize(_ session: AgentSessionInfo, with executor: SummaryExecutorKind) -> SessionSummaryCoordinator.RequestResult? {
        preferredExecutor = executor
        guard let coordinator else { return nil }
        let model = models[executor]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = SessionSummaryCoordinator.Request(
            session: session,
            header: SummaryTemplate.SessionHeader(
                title: session.displayName, sourceName: session.source.displayName,
                project: session.cwd, startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt),
            executor: executor, model: (model?.isEmpty ?? true) ? nil : model,
            language: L10n.current)
        let result = coordinator.request(request)
        revealSummary(for: session)
        return result
    }

    func cancel(_ session: AgentSessionInfo) {
        coordinator?.cancel(sessionKey: key(session))
    }

    /// Asks the detail pane to show the AI Summary tab for this session
    func revealSummary(for session: AgentSessionInfo) {
        tabSerial += 1
        tabRequest = TabRequest(sessionKey: key(session), serial: tabSerial)
    }

    /// Compares the saved summary's fingerprint with the conversation as it is now. Uses the
    /// already loaded transcript when it is complete, otherwise rereads it in full.
    func checkFreshness(
        _ session: AgentSessionInfo, transcript: [TranscriptMessage], truncated: Bool
    ) {
        let key = key(session)
        guard let saved = completed[key] else { return }
        queue.async { [weak self] in
            let messages = truncated
                ? TranscriptReader.load(session: session, maxMessages: Int.max).messages
                : transcript
            let snapshot = ConversationSnapshotBuilder.build(from: messages)
            let state: Freshness = snapshot.fingerprint == saved.fingerprint
                ? .current
                : .stale(newMessages: max(0, snapshot.messages.count - saved.coverage.totalMessages))
            DispatchQueue.main.async {
                guard self?.completed[key]?.id == saved.id else { return }
                self?.freshness[key] = state
            }
        }
    }

    // MARK: - Copy / export

    func copy(_ markdown: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
    }

    /// Markdown export with a provenance header (session, executor, coverage, time)
    func exportDocument(_ record: SummaryRunRecord, session: AgentSessionInfo) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "# \(L10n.text("AI summary", zhHans: "AI 总结")): \(session.displayName)",
            "",
            "- \(L10n.text("Source", zhHans: "来源")): \(session.source.displayName) · `\(session.id)`",
            "- \(L10n.text("Summarized by", zhHans: "总结执行器")): \(record.executor.displayName)"
                + (record.executorVersion.map { " \($0)" } ?? "")
                + (record.model.map { " · \($0)" } ?? ""),
            "- \(L10n.text("Covers", zhHans: "覆盖")): "
                + L10n.format("%@ messages", zhHans: "%@ 条消息", String(record.coverage.totalMessages))
                + (record.coverage.chunkCount > 1
                    ? " · " + L10n.format("%@ parts", zhHans: "%@ 段", String(record.coverage.chunkCount)) : ""),
            "- \(L10n.text("Generated", zhHans: "生成时间")): \(formatter.string(from: record.finishedAt ?? record.updatedAt))",
            "- \(L10n.text("Template", zhHans: "模板")): v\(record.templateVersion)",
            "",
        ]
        lines.append(record.markdown ?? "")
        return lines.joined(separator: "\n")
    }

    func export(_ record: SummaryRunRecord, session: AgentSessionInfo) -> URL? {
        let panel = NSSavePanel()
        let base = session.name.map { TranscriptMarkdown.safeFileName($0) }
            ?? String(session.id.prefix(8))
        panel.nameFieldStringValue = "\(base)-summary.md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try Data(exportDocument(record, session: session).utf8).write(to: url)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - Preview support

    /// Seeds state for offscreen renders (`--render-pages`); never used by the live app
    func seedForPreview(
        availability: [SummaryExecutorAvailability], live: [SummaryLiveState] = [],
        completed: [SummaryRunRecord] = [], lastFinished: [SummaryRunRecord] = [],
        freshness: [String: Freshness] = [:], preferred: SummaryExecutorKind?
    ) {
        self.availability = Dictionary(uniqueKeysWithValues: availability.map { ($0.kind, $0) })
        self.live = Dictionary(uniqueKeysWithValues: live.map { ($0.sessionKey, $0) })
        self.completed = Dictionary(uniqueKeysWithValues: completed.map { ($0.sessionKey, $0) })
        self.lastFinished = Dictionary(uniqueKeysWithValues: lastFinished.map { ($0.sessionKey, $0) })
        self.freshness = freshness
        for state in live { rowStatus[state.sessionKey] = .running }
        for record in lastFinished where record.status == .failed {
            rowStatus[record.sessionKey] = .failed
        }
        for record in completed { rowStatus[record.sessionKey] = .completed }
        started = true
        preferredExecutor = preferred
    }
}
