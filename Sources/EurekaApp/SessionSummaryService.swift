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

    /// Templates the person made (built-ins come from `SummaryTemplateSpec.builtIns`)
    @Published private(set) var customTemplates: [SummaryTemplateSpec] = []
    /// Template used for the next run
    @Published var selectedTemplateId: String {
        didSet { defaults.set(selectedTemplateId, forKey: Self.templateKey) }
    }
    /// Objective numbers about a session for the prompt header (prompts, tokens, cost, duration),
    /// supplied by the session browser that knows them
    var factsProvider: ((AgentSessionInfo) -> [String])?

    /// Model suggestions per executor, loaded on demand (`loadModelOptions`)
    @Published private(set) var modelOptions: [SummaryExecutorKind: [SummaryModelOption]] = [:]
    @Published private(set) var loadingModels: Set<SummaryExecutorKind> = []

    private static let executorKey = "sessionSummaryExecutor"
    private static let templateKey = "sessionSummaryTemplate"
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
        selectedTemplateId = defaults.string(forKey: Self.templateKey) ?? SummaryTemplateSpec.defaultId
        let stored = defaults.dictionary(forKey: Self.modelsKey) as? [String: String] ?? [:]
        models = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            SummaryExecutorKind(rawValue: key).map { ($0, value) }
        })
        customTemplates = Self.loadTemplates()
    }

    // MARK: - Templates

    /// Built-ins first, then the person's own
    var templates: [SummaryTemplateSpec] { SummaryTemplateSpec.builtIns + customTemplates }

    /// The selected template; falls back to the default when it was deleted
    var selectedTemplate: SummaryTemplateSpec {
        templates.first { $0.id == selectedTemplateId } ?? SummaryTemplateSpec.collabReview
    }

    func template(id: String?) -> SummaryTemplateSpec? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    /// Adds or replaces a custom template (built-ins are copied first, never edited)
    func saveTemplate(_ template: SummaryTemplateSpec) {
        guard !template.isBuiltIn else { return }
        if let index = customTemplates.firstIndex(where: { $0.id == template.id }) {
            customTemplates[index] = template
        } else {
            customTemplates.append(template)
        }
        persistTemplates()
    }

    func deleteTemplate(id: String) {
        customTemplates.removeAll { $0.id == id }
        if selectedTemplateId == id { selectedTemplateId = SummaryTemplateSpec.defaultId }
        persistTemplates()
    }

    /// `summary-templates.json` beside the database (Application Support/Eureka)
    private static var templatesURL: URL {
        EurekaStore.defaultURL().deletingLastPathComponent().appendingPathComponent("summary-templates.json")
    }

    private static func loadTemplates() -> [SummaryTemplateSpec] {
        guard let data = try? Data(contentsOf: templatesURL),
              let list = try? JSONDecoder().decode([SummaryTemplateSpec].self, from: data) else { return [] }
        return list.filter { !$0.isBuiltIn }
    }

    private func persistTemplates() {
        let list = customTemplates
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(list) else { return }
            try? FileManager.default.createDirectory(
                at: Self.templatesURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.templatesURL, options: .atomic)
        }
    }

    // MARK: - Worth keeping

    /// Saves a (possibly edited) candidate into the project's Claude memory library and records
    /// it on the run. Returns the file, or an error message for the UI.
    func saveCandidate(
        _ candidate: SummaryDocument.Candidate, title: String, content: String,
        run: SummaryRunRecord, session: AgentSessionInfo
    ) -> Result<URL, SaveFailure> {
        let file: URL
        do {
            file = try ClaudeProjectMemoryWriter.write(
                title: title, content: content,
                kind: candidate.kind == .rule ? .feedback : .project,
                originSessionId: session.id, projectPath: session.cwd)
        } catch ClaudeProjectMemoryWriter.WriteError.noProjectDirectory {
            return .failure(SaveFailure(message: L10n.text(
                "This session has no project directory, so there is no memory library to save into.",
                zhHans: "这个会话没有项目目录，找不到可以写入的记忆库。")))
        } catch ClaudeProjectMemoryWriter.WriteError.emptyContent {
            return .failure(SaveFailure(message: L10n.text("The content is empty.", zhHans: "内容是空的。")))
        } catch {
            return .failure(SaveFailure(message: error.localizedDescription))
        }
        record(.init(status: .saved, path: file.path, decidedAt: Date()), for: candidate, run: run)
        return .success(file)
    }

    func dismissCandidate(_ candidate: SummaryDocument.Candidate, run: SummaryRunRecord) {
        record(.init(status: .dismissed, decidedAt: Date()), for: candidate, run: run)
    }

    /// Undo a dismissal (a saved file stays where it is; it is managed on the Memory page)
    func restoreCandidate(_ candidate: SummaryDocument.Candidate, run: SummaryRunRecord) {
        var decisions = completed[run.sessionKey]?.candidateDecisions ?? run.candidateDecisions
        guard decisions[candidate.id]?.status == .dismissed else { return }
        decisions[candidate.id] = nil
        apply(decisions, to: run)
    }

    struct SaveFailure: Error {
        var message: String
    }

    private func record(
        _ decision: SummaryCandidateDecision, for candidate: SummaryDocument.Candidate,
        run: SummaryRunRecord
    ) {
        var decisions = completed[run.sessionKey]?.candidateDecisions ?? run.candidateDecisions
        decisions[candidate.id] = decision
        apply(decisions, to: run)
    }

    private func apply(_ decisions: [String: SummaryCandidateDecision], to run: SummaryRunRecord) {
        if completed[run.sessionKey]?.id == run.id {
            completed[run.sessionKey]?.candidateDecisions = decisions
        }
        let runId = run.id
        queue.async { [weak self] in
            self?.coordinator?.updateCandidateDecisions(runId: runId, decisions: decisions)
        }
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
        modelOptions = [:]
        queue.async { [weak self] in self?.probeExecutors() }
    }

    /// Fetches an executor's model suggestions once (until the CLIs are re-checked). Runs off the
    /// service queue: `opencode models` can take ~11 s and must not hold up a summary start.
    func loadModelOptions(for kind: SummaryExecutorKind) {
        guard modelOptions[kind] == nil, !loadingModels.contains(kind),
              let executor = availability[kind]?.executor else { return }
        loadingModels.insert(kind)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let options = SummaryModelCatalog.load(
                for: executor, codexConfigURL: MCPConfigIndexer.globalConfigURL(for: .codex))
            DispatchQueue.main.async {
                self?.modelOptions[kind] = options
                self?.loadingModels.remove(kind)
            }
        }
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
                lastActiveAt: session.lastActiveAt, facts: factsProvider?(session) ?? []),
            executor: executor, model: (model?.isEmpty ?? true) ? nil : model,
            language: L10n.current, template: selectedTemplate)
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
            "- \(L10n.text("Template", zhHans: "模板")): "
                + (record.templateName.map { "\($0) · " } ?? "") + "v\(record.templateVersion)",
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
        freshness: [String: Freshness] = [:], preferred: SummaryExecutorKind?,
        modelOptions: [SummaryExecutorKind: [SummaryModelOption]] = [:]
    ) {
        self.modelOptions = modelOptions
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
