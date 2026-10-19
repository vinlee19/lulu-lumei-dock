import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSummary
import Foundation

/// `eureka --summarize <session-id> [--executor claude|codex|opencode] [--model m]
/// [--budget tokens] [--cancel-after seconds] [--executors]`
///
/// Runs one AI summary through the same coordinator, adapters and process launcher as the app,
/// printing progress and the stored record. Meant for adapter smoke checks; point
/// `EUREKA_DB_PATH` at a copy of the database.
enum SummaryCLI {
    static func run(_ args: [String]) {
        var sessionId: String?
        var executor = SummaryExecutorKind.claude
        var model: String?
        var budget = SummaryChunker.defaultBudget
        var cancelAfter: TimeInterval?
        var listOnly = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            let next = index + 1 < args.count ? args[index + 1] : nil
            switch arg {
            case "--executor":
                guard let raw = next, let kind = SummaryExecutorKind(rawValue: raw) else { usage() }
                executor = kind
                index += 1
            case "--model":
                model = next
                index += 1
            case "--budget":
                guard let value = next.flatMap(Int.init), value > 0 else { usage() }
                budget = value
                index += 1
            case "--cancel-after":
                guard let value = next.flatMap(Double.init), value > 0 else { usage() }
                cancelAfter = value
                index += 1
            case "--executors":
                listOnly = true
            default:
                if arg.hasPrefix("--") { usage() }
                sessionId = arg
            }
            index += 1
        }

        let resolver = SummaryExecutorResolver()
        func adapter(_ kind: SummaryExecutorKind) -> SummaryExecutorAdapter {
            guard kind == .codex, let url = MCPConfigIndexer.globalConfigURL(for: .codex),
                  let text = try? String(contentsOf: url, encoding: .utf8)
            else { return SummaryAdapters.adapter(for: kind) }
            let names = MCPConfigIndexer.parseTOMLServers(text, source: .codex, configPath: url.path)
                .map(\.name)
            return SummaryAdapters.adapter(for: .codex, codexMCPServers: names)
        }
        if listOnly {
            for kind in SummaryExecutorKind.allCases {
                let availability = resolver.availability(for: kind, adapter: adapter(kind))
                let detail = availability.executor.map { "\($0.path) \($0.version ?? "?")" }
                    ?? (availability.reason ?? "")
                print("\(kind.rawValue): \(availability.isAvailable ? "available" : "unavailable") — \(detail)")
            }
            return
        }
        guard let sessionId else { usage() }
        guard let session = findSession(sessionId) else {
            print("session not found: \(sessionId)")
            exit(1)
        }
        guard let store = try? EurekaStore(path: EurekaStore.defaultURL()) else {
            print("cannot open \(EurekaStore.defaultURL().path)")
            exit(1)
        }
        print("db: \(EurekaStore.defaultURL().path)")
        print("session: \(session.source.rawValue):\(session.id) \(session.displayName)")

        let finished = DispatchSemaphore(value: 0)
        var lastStage: SummaryStage?
        var lastText = 0
        var result: SummaryRunRecord?
        var configuration = SessionSummaryCoordinator.Configuration()
        configuration.budget = budget
        let started = Date()
        func stamp() -> String { String(format: "%6.1fs", Date().timeIntervalSince(started)) }
        let coordinator = SessionSummaryCoordinator(
            store: store, launcher: PosixSummaryProcessLauncher(),
            executors: { kind in
                let made = adapter(kind)
                return (resolver.availability(for: kind, adapter: made), made)
            },
            configuration: configuration,
            onUpdate: { update in
                switch update {
                case .live(let live):
                    if live.stage != lastStage {
                        lastStage = live.stage
                        let chunk = live.chunkTotal > 1 && live.stage != .merging
                            ? " [\(live.chunksDone + 1)/\(live.chunkTotal)]" : ""
                        print("\(stamp()) stage: \(live.stage.rawValue)\(chunk)")
                    }
                    if live.streamedText.count >= lastText + 400 {
                        lastText = live.streamedText.count
                        print("\(stamp()) streamed \(lastText) chars")
                    }
                case .finished(let record):
                    result = record
                    finished.signal()
                }
            })
        coordinator.reconcileOnLaunch()
        let request = SessionSummaryCoordinator.Request(
            session: session,
            header: SummaryTemplate.SessionHeader(
                title: session.displayName, sourceName: session.source.displayName,
                project: session.cwd, startedAt: session.startedAt,
                lastActiveAt: session.lastActiveAt),
            executor: executor, model: model, language: L10n.current)
        print("request: \(coordinator.request(request))")
        if let cancelAfter {
            DispatchQueue.global().asyncAfter(deadline: .now() + cancelAfter) {
                print("\(stamp()) cancelling")
                coordinator.cancel(sessionKey: AgentTask.key(source: session.source, sessionId: session.id))
            }
        }
        finished.wait()
        guard let record = result else { exit(1) }
        print("\(stamp()) status: \(record.status.rawValue) error: \(record.errorKind?.rawValue ?? "-") \(record.errorMessage ?? "")")
        print("executor: \(record.executor.rawValue) \(record.executorVersion ?? "?") model: \(record.model ?? "-") tokens in/out: \(record.inputTokens.map(String.init) ?? "-")/\(record.outputTokens.map(String.init) ?? "-")")
        let c = record.coverage
        print("coverage: messages \(c.totalMessages) (#\(c.firstMessageId ?? -1)–#\(c.lastMessageId ?? -1)) chunks \(c.chunkCount) split \(c.splitMessages) toolSteps \(c.compactedToolSteps) thinking \(c.excludedThinking) estTokens \(c.estimatedTokens) refs \(c.validReferences)/-\(c.droppedReferences)")
        print("fingerprint: \(record.fingerprint)")
        print("----- markdown -----")
        print(record.markdown ?? "(none)")
        exit(record.status == .completed ? 0 : 3)
    }

    /// Looks the session up in the sources an executor can read (all time)
    private static func findSession(_ id: String) -> AgentSessionInfo? {
        let window = TimeInterval.greatestFiniteMagnitude
        var sessions = ClaudeSessionIndexer.index(
            projectsRoot: ClaudeSessionBootstrap.defaultProjectsRoot(), window: window, maxSessions: .max)
        sessions += CodexSessionIndexer.index(
            sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), window: window, maxSessions: .max)
        sessions += OpencodeSessionIndexer.index(dbPath: OpencodePaths.db(), window: window, maxSessions: .max)
        return sessions.first { $0.id == id }
    }

    private static func usage() -> Never {
        print("usage: eureka --summarize <session-id> [--executor claude|codex|opencode] [--model m] [--budget tokens] [--cancel-after seconds]")
        print("       eureka --summarize --executors")
        exit(2)
    }
}
