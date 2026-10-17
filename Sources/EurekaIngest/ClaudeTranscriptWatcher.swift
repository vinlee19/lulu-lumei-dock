import Foundation
import EurekaKit

/// Resident Claude transcript watcher: a fallback event source that doesn't depend on hooks (the
/// counterpart of CodexRolloutTailer).
///
/// Why it must exist: hooks load at session start, so old sessions opened before hooks were
/// installed, or sessions with a broken hooks config, never emit any events. This watcher polls
/// transcript writes and detects start/finish with the tail-window classification
/// (ClaudeSessionBootstrap.classify). For sessions with hooks it is a redundant signal: TaskStore's
/// idempotent semantics + the "repeat finish events on an idle session don't produce a card" rule
/// take care of dedup.
public final class ClaudeTranscriptWatcher {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let projectsRoot: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.claude-watcher")
    private var timer: DispatchSourceTimer?

    private struct FileState {
        var mtime: Date
        var running: Bool
        var knownTitle: String?
        var contextBucket: Int?
        var lastSubagents: [SubagentInfo] = []
    }
    private var states: [String: FileState] = [:]

    public init(projectsRoot: URL, handler: @escaping Handler) {
        self.projectsRoot = projectsRoot
        self.handler = handler
    }

    static let healthName = "Claude transcript 监视"

    public func start(pollInterval: TimeInterval = 5) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power; it must stay below the poll
        // interval (100ms for the 1s tier)
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

    /// Public for tests and the initial scan at launch
    public func scanOnce(now: Date = Date(), idleWindow: TimeInterval = 1800) {
        HealthRegistry.shared.beat(Self.healthName)
        let fm = FileManager.default
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mtime) < idleWindow else { continue }
                inspect(file, mtime: mtime, now: now)
            }
        }
        // Prune state for files that went quiet long ago
        states = states.filter { now.timeIntervalSince($0.value.mtime) < idleWindow * 2 }
    }

    private func inspect(_ file: URL, mtime: Date, now: Date) {
        let path = file.path
        let previous = states[path]
        // No new writes, no read
        if let previous, previous.mtime >= mtime { return }
        guard let snapshot = ClaudeSessionBootstrap.classify(fileURL: file) else { return }

        func emit(_ kind: TaskEvent.Kind, at date: Date) {
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: path
            ), false)
        }

        let wasRunning = previous?.running
        if snapshot.running {
            if wasRunning == true {
                // State unchanged: keep the task alive (prevents a false 4h reap)
                emit(.activity(tool: nil), at: mtime)
            } else {
                // Running on first sight / new turn started after idle
                emit(.taskStarted(title: snapshot.promptText.flatMap { summarizeTitle($0) }),
                     at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime)
            }
        } else if wasRunning == nil {
            emit(.sessionStarted, at: mtime)
        } else if wasRunning == true {
            // Turn finished: for sessions without hooks this is the only finish signal; with hooks,
            // Stop arrives first and the session is already idle → the store suppresses the
            // duplicate card
            emit(.taskFinished(outcome: .success, title: nil, detail: nil),
                 at: snapshot.turnEndAt ?? mtime)
        }

        // Emit only when the title/context changed
        if let aiTitle = snapshot.aiTitle, aiTitle != previous?.knownTitle {
            emit(.titleUpdate(title: aiTitle), at: mtime)
        }
        let bucket = snapshot.contextPercent.map { Int($0.rounded()) }
        if let percent = snapshot.contextPercent, bucket != previous?.contextBucket {
            emit(.contextUpdate(percent: percent), at: mtime)
        }

        // Subagent live state: scanned only while running (subagents/ accumulates across turns, so
        // it is trimmed to this turn by prompt time) and emitted only when the list changes; the
        // cache is cleared when the turn ends so the next turn emits afresh.
        var subagents: [SubagentInfo] = []
        if snapshot.running {
            subagents = ClaudeSubagentScanner.scan(
                sessionDir: file.deletingPathExtension(),
                parentTranscript: file,
                turnStartedAt: snapshot.promptAt)
            if subagents != (previous?.lastSubagents ?? []) {
                emit(.subagentsUpdated(subagents), at: mtime)
            }
        }

        states[path] = FileState(
            mtime: mtime,
            running: snapshot.running,
            knownTitle: snapshot.aiTitle ?? previous?.knownTitle,
            contextBucket: bucket ?? previous?.contextBucket,
            lastSubagents: subagents
        )
    }
}
