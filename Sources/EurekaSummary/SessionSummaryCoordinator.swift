import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// The summary service boundary: queueing, run lifecycle, persistence and recovery.
///
/// - one run executes at a time app-wide (a serial work queue); others wait as `queued`
/// - at most one active run per `source:sessionId`; a repeated request returns the existing run
/// - every update carries its run id, so a late event can't overwrite another run
/// - a new run is a new row: the previous successful summary stays until a regeneration succeeds
/// - unfinished rows left by a previous process are reconciled to `interrupted` on launch
///
/// Thread-safe. `onUpdate` is called on background threads; the app hops to the main thread.
public final class SessionSummaryCoordinator {
    public struct Request {
        public var session: AgentSessionInfo
        public var header: SummaryTemplate.SessionHeader
        public var executor: SummaryExecutorKind
        public var model: String?
        public var language: AppLanguage

        public init(
            session: AgentSessionInfo, header: SummaryTemplate.SessionHeader,
            executor: SummaryExecutorKind, model: String?, language: AppLanguage
        ) {
            self.session = session
            self.header = header
            self.executor = executor
            self.model = model
            self.language = language
        }
    }

    public enum RequestResult: Equatable {
        case started(runId: String)
        /// A run for this session is already queued or running; it is revealed instead
        case alreadyActive(runId: String)
        case rejected(SummaryFailureKind, String)
    }

    public enum Update {
        case live(SummaryLiveState)
        case finished(SummaryRunRecord)
    }

    public struct Configuration {
        public var budget = SummaryChunker.defaultBudget
        public var invocationTimeout: TimeInterval = 15 * 60
        /// Minimum spacing of text-only progress updates (stage changes are never throttled)
        public var textThrottle: TimeInterval = 0.25
        /// How often an in-flight draft is saved, so a crash still leaves something behind
        public var draftSaveInterval: TimeInterval = 10

        public init() {}
    }

    public typealias SnapshotLoader = (AgentSessionInfo) -> ConversationSnapshotBuilder.Outcome
    public typealias ExecutorProvider = (SummaryExecutorKind) -> (SummaryExecutorAvailability, SummaryExecutorAdapter)

    private final class Job {
        let runId: String
        let request: Request
        let cancel = SummaryCancelToken()
        var record: SummaryRunRecord
        var live: SummaryLiveState
        var shuttingDown = false
        var lastTextEmit = Date.distantPast
        var lastDraftSave = Date()
        let done = DispatchSemaphore(value: 0)

        init(runId: String, request: Request, record: SummaryRunRecord, live: SummaryLiveState) {
            self.runId = runId
            self.request = request
            self.record = record
            self.live = live
        }
    }

    private let store: EurekaStore
    private let launcher: SummaryProcessLaunching
    private let executors: ExecutorProvider
    private let loadSnapshot: SnapshotLoader
    private let workspaceRoot: URL
    private let configuration: Configuration
    private let now: () -> Date
    private let onUpdate: (Update) -> Void

    private let lock = NSLock()
    private var jobs: [String: Job] = [:]  // sessionKey → active job
    private let storeQueue = DispatchQueue(label: "com.vinlee.eureka.summary-store")
    private let workQueue = DispatchQueue(label: "com.vinlee.eureka.summary-work", qos: .utility)

    public init(
        store: EurekaStore, launcher: SummaryProcessLaunching, executors: @escaping ExecutorProvider,
        loadSnapshot: @escaping SnapshotLoader = ConversationSnapshotBuilder.load,
        workspaceRoot: URL = SummaryWorkspacePaths.root(),
        configuration: Configuration = Configuration(), now: @escaping () -> Date = Date.init,
        onUpdate: @escaping (Update) -> Void
    ) {
        self.store = store
        self.launcher = launcher
        self.executors = executors
        self.loadSnapshot = loadSnapshot
        self.workspaceRoot = workspaceRoot
        self.configuration = configuration
        self.now = now
        self.onUpdate = onUpdate
    }

    // MARK: - Store access (serialized)

    private func withStore<T>(_ body: (EurekaStore) throws -> T) -> T? {
        storeQueue.sync { try? body(store) }
    }

    /// Launch-time reconciliation; returns how many rows were marked interrupted
    @discardableResult
    public func reconcileOnLaunch() -> Int {
        withStore { try $0.summaryRuns.markUnfinishedInterrupted(at: now()) } ?? 0
    }

    public func latestCompleted(source: AgentSource, sessionId: String) -> SummaryRunRecord? {
        withStore { try $0.summaryRuns.latestCompleted(source: source, sessionId: sessionId) } ?? nil
    }

    public func history(source: AgentSource, sessionId: String) -> [SummaryRunRecord] {
        withStore { try $0.summaryRuns.runs(source: source, sessionId: sessionId) } ?? []
    }

    public func statusBySession() -> [String: (latest: SummaryStage, hasCompleted: Bool)] {
        withStore { try $0.summaryRuns.statusBySession() } ?? [:]
    }

    // MARK: - Requests

    public func liveState(sessionKey: String) -> SummaryLiveState? {
        lock.lock()
        defer { lock.unlock() }
        return jobs[sessionKey]?.live
    }

    public func request(_ request: Request) -> RequestResult {
        let session = request.session
        if let reason = SummarySourceSupport.unsupportedReason(session.source) {
            return .rejected(.unsupportedSource, reason)
        }
        let key = AgentTask.key(source: session.source, sessionId: session.id)
        let startedAt = now()
        let runId = UUID().uuidString.lowercased()
        let record = SummaryRunRecord(
            id: runId, source: session.source, sessionId: session.id, status: .queued,
            executor: request.executor, model: request.model, language: request.language.rawValue,
            startedAt: startedAt, updatedAt: startedAt)
        let live = SummaryLiveState(
            runId: runId, sessionKey: key, executor: request.executor, stage: .queued,
            startedAt: startedAt)

        lock.lock()
        if let existing = jobs[key] {
            lock.unlock()
            return .alreadyActive(runId: existing.runId)
        }
        let job = Job(runId: runId, request: request, record: record, live: live)
        jobs[key] = job
        lock.unlock()

        _ = withStore { try $0.summaryRuns.save(record) }
        onUpdate(.live(live))
        workQueue.async { [weak self] in self?.execute(job) }
        return .started(runId: runId)
    }

    /// Cancels the active run of a session (queued or running). Returns false when there is none.
    @discardableResult
    public func cancel(sessionKey: String) -> Bool {
        lock.lock()
        let job = jobs[sessionKey]
        lock.unlock()
        guard let job else { return false }
        job.cancel.cancel()
        return true
    }

    /// App exit: stop every managed process and keep drafts. Runs that don't wind down within
    /// `timeout` are written as interrupted directly (and launch reconciliation covers the rest).
    public func shutdown(timeout: TimeInterval = 5) {
        lock.lock()
        let active = Array(jobs.values)
        for job in active { job.shuttingDown = true }
        lock.unlock()
        for job in active { job.cancel.cancel() }
        let deadline = Date().addingTimeInterval(timeout)
        for job in active where job.done.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .timedOut {
            var record = job.record
            record.status = .interrupted
            record.errorKind = .interrupted
            record.updatedAt = now()
            record.finishedAt = now()
            if record.markdown == nil, !job.live.streamedText.isEmpty {
                record.markdown = job.live.streamedText
            }
            _ = withStore { try $0.summaryRuns.save(record) }
        }
    }

    // MARK: - Execution (work queue)

    private func execute(_ job: Job) {
        defer { job.done.signal() }
        if job.cancel.isCancelled {
            finish(job, kind: job.shuttingDown ? .interrupted : .cancelled, message: nil, markdown: nil)
            return
        }

        setStage(job, .reading)
        let snapshot: SummarySnapshot
        switch loadSnapshot(job.request.session) {
        case .snapshot(let value):
            snapshot = value
        case .unsupported(let reason):
            finish(job, kind: .unsupportedSource, message: reason, markdown: nil)
            return
        case .readFailed(let reason):
            finish(job, kind: .readFailed, message: reason, markdown: nil)
            return
        case .empty:
            finish(job, kind: .emptyConversation, message: nil, markdown: nil)
            return
        }
        job.record.fingerprint = snapshot.fingerprint

        let (availability, adapter) = executors(job.request.executor)
        guard let executor = availability.executor else {
            finish(job, kind: .executorUnavailable, message: availability.reason, markdown: nil)
            return
        }
        job.record.executorVersion = executor.version
        mutateLive(job) { $0.streams = adapter.streams }

        let workingDirectory = workspaceRoot.appendingPathComponent(job.runId, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: workingDirectory, withIntermediateDirectories: true)
        } catch {
            finish(job, kind: .launchFailed, message: "\(error)", markdown: nil)
            return
        }
        let engine = SessionSummaryEngine(
            invoker: SummaryInvoker(launcher: launcher, timeout: configuration.invocationTimeout),
            budget: configuration.budget)
        let input = SessionSummaryEngine.Input(
            snapshot: snapshot, header: job.request.header, executor: executor, adapter: adapter,
            model: job.request.model, workingDirectory: workingDirectory.path,
            language: job.request.language)
        let result = engine.run(input, cancel: job.cancel) { [weak self] progress in
            self?.handle(progress, job: job)
        }
        // Clean up before publishing the outcome: observers may act (or the process may exit)
        // as soon as `finish` reports it
        try? FileManager.default.removeItem(at: workingDirectory)

        job.record.coverage = result.coverage
        job.record.model = result.model ?? job.request.model
        job.record.inputTokens = result.inputTokens
        job.record.outputTokens = result.outputTokens
        switch result.outcome {
        case .success(let text):
            finish(job, kind: nil, message: nil, markdown: text)
        case .failure(let kind, let message):
            let resolved: SummaryFailureKind = kind == .cancelled && job.shuttingDown ? .interrupted : kind
            finish(job, kind: resolved, message: message, markdown: result.markdown)
        }
    }

    private func handle(_ progress: SessionSummaryEngine.Progress, job: Job) {
        switch progress {
        case .stage(let stage, let done, let total):
            mutateLive(job) {
                $0.stage = stage
                $0.chunksDone = done
                $0.chunkTotal = total
            }
            persistStage(job, stage)
        case .activity:
            mutateLive(job, emit: false) { $0.lastEventAt = self.now() }
        case .text(let text):
            let at = now()
            let emit = at.timeIntervalSince(job.lastTextEmit) >= configuration.textThrottle
                || text.isEmpty
            if emit { job.lastTextEmit = at }
            mutateLive(job, emit: emit) { $0.streamedText = text }
            if !text.isEmpty, at.timeIntervalSince(job.lastDraftSave) >= configuration.draftSaveInterval {
                job.lastDraftSave = at
                var draft = job.record
                draft.markdown = text
                draft.updatedAt = at
                _ = withStore { try $0.summaryRuns.save(draft) }
            }
        case .coverage(let coverage):
            job.record.coverage = coverage
            mutateLive(job) { $0.coverage = coverage }
        }
    }

    private func setStage(_ job: Job, _ stage: SummaryStage) {
        mutateLive(job) { $0.stage = stage }
        persistStage(job, stage)
    }

    private func persistStage(_ job: Job, _ stage: SummaryStage) {
        guard job.record.status != stage else { return }
        job.record.status = stage
        job.record.updatedAt = now()
        let id = job.runId
        let at = job.record.updatedAt
        _ = withStore { try $0.summaryRuns.updateStatus(id: id, status: stage, at: at) }
    }

    private func mutateLive(_ job: Job, emit: Bool = true, _ change: (inout SummaryLiveState) -> Void) {
        lock.lock()
        change(&job.live)
        let snapshot = job.live
        // A run that already left the table must not publish again
        let current = jobs[snapshot.sessionKey] === job
        lock.unlock()
        if emit && current { onUpdate(.live(snapshot)) }
    }

    private func finish(
        _ job: Job, kind: SummaryFailureKind?, message: String?, markdown: String?
    ) {
        let at = now()
        var record = job.record
        record.updatedAt = at
        record.finishedAt = at
        record.errorKind = kind
        record.errorMessage = message
        let trimmed = markdown?.trimmingCharacters(in: .whitespacesAndNewlines)
        record.markdown = (trimmed?.isEmpty ?? true) ? (kind == nil ? nil : job.record.markdown) : trimmed
        switch kind {
        case nil: record.status = .completed
        case .cancelled?: record.status = .cancelled
        case .interrupted?: record.status = .interrupted
        default: record.status = .failed
        }
        job.record = record
        _ = withStore { try $0.summaryRuns.save(record) }
        lock.lock()
        if jobs[record.sessionKey] === job { jobs[record.sessionKey] = nil }
        lock.unlock()
        onUpdate(.finished(record))
    }
}
