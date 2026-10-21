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
        var sessionId: String
        var cwd: String?
        var running: Bool
        /// The writer was judged to have exited (sessionEnded emitted); a further write means a
        /// resume, handled as first sight
        var ended = false
        /// The tail already ends with cost-state but a live process carrying this id was still
        /// around: either a resume just started, or the process is still tearing down (cost-state
        /// hits the disk a few hundred ms to two seconds before the process really exits) → re-check
        /// the process once the file stops changing
        var exitPending = false
        /// When the process was last re-checked (every `exitProbeInterval` while exitPending, not on
        /// every poll)
        var lastProbeAt: Date
        /// Last real prompt time seen: idle on both polls but this changed = a whole short turn ran
        /// in between
        var promptAt: Date?
        var knownTitle: String?
        var contextBucket: Int?
        var lastSubagents: [SubagentInfo] = []
    }
    private var states: [String: FileState] = [:]
    /// Minimum interval between process re-checks of an exitPending file (3 polls; the upper bound
    /// on how long an archived resumed session stays on the island)
    public static let exitProbeInterval: TimeInterval = 6
    /// Ids of the resumed sessions currently alive (claude processes whose argv carries `--resume`);
    /// tests inject it. Called at most once per scanOnce: every file that needs it shares one
    /// process table.
    private let liveResumedSessionIds: () -> Set<String>

    /// The `sessionEnded` reason when the transcript shows the process exited
    public static var exitReason: String {
        L10n.text("process exited", zhHans: "进程已退出")
    }

    public init(
        projectsRoot: URL,
        liveResumedSessionIds: @escaping () -> Set<String> = ClaudeResumeProbe.liveResumedSessionIds,
        handler: @escaping Handler
    ) {
        self.projectsRoot = projectsRoot
        self.liveResumedSessionIds = liveResumedSessionIds
        self.handler = handler
    }

    static let healthName = "Claude transcript 监视"

    /// 2s per round: an unchanged file costs one stat, the work is parsing the 256KB tail of files
    /// that did change. This is also the upper bound on how long the island takes to notice an
    /// archive / a finished turn (resumed sessions add one `exitProbeInterval`).
    public func start(pollInterval: TimeInterval = 2) {
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
        // The process table is fetched lazily, once per round: only files whose tail ends with
        // cost-state ever ask for it
        var liveIds: Set<String>?
        func isResumedAlive(_ sessionId: String) -> Bool {
            if liveIds == nil { liveIds = liveResumedSessionIds() }
            return liveIds?.contains(sessionId) == true
        }
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mtime) < idleWindow else { continue }
                inspect(file, mtime: mtime, now: now, isResumedAlive: isResumedAlive)
            }
        }
        // Prune state for files that went quiet long ago
        states = states.filter { now.timeIntervalSince($0.value.mtime) < idleWindow * 2 }
    }

    private func inspect(
        _ file: URL, mtime: Date, now: Date, isResumedAlive: (String) -> Bool
    ) {
        let path = file.path
        var previous = states[path]
        // No new writes, no read. The one exception: the tail already ended with cost-state but the
        // resumed process was still alive back then — the file will never change again, so the
        // only way to learn the process is gone is to re-check it (throttled, not every poll)
        if let previous, previous.mtime >= mtime {
            if previous.exitPending,
               now.timeIntervalSince(previous.lastProbeAt) >= Self.exitProbeInterval {
                states[path]?.lastProbeAt = now
                if !isResumedAlive(previous.sessionId) {
                    HealthRegistry.shared.event(Self.healthName)
                    handler(TaskEvent(
                        source: .claude, sessionId: previous.sessionId,
                        kind: .sessionEnded(reason: Self.exitReason),
                        timestamp: mtime, cwd: previous.cwd, transcriptPath: path
                    ), false)
                    states[path]?.exitPending = false
                    states[path]?.ended = true
                    states[path]?.running = false
                }
            }
            return
        }
        guard let snapshot = ClaudeSessionBootstrap.classify(fileURL: file) else { return }

        func emit(_ kind: TaskEvent.Kind, at date: Date) {
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: path
            ), false)
        }

        func emitFinished() {
            let outcome = snapshot.turnEndOutcome ?? .success
            emit(.taskFinished(outcome: outcome, title: nil,
                               detail: outcome == .interrupted ? L10n.text("Interrupted", zhHans: "已中断") : nil),
                 at: snapshot.turnEndAt ?? mtime)
        }

        // The writer has exited (archive / Desktop's idle sweep / a scheduled task finishing): the
        // trailing cost-state is written on exit. A resumed process writes one at startup too, so a
        // live process carrying this id must also be ruled out.
        var exitPending = false
        if snapshot.exitMarkerLast {
            if isResumedAlive(snapshot.sessionId) {
                // Really alive (resume just started) or still tearing down — indistinguishable now
                // → remember it and re-check once the file stops changing
                exitPending = true
            } else {
                // Known alive until now → first wrap up a turn that just finished normally (turn end
                // and archive often land in the same poll; skipping this would mark a completed turn
                // as interrupted), then emit sessionEnded (an idle session is removed silently, a
                // running one counts as interrupted). Already exited on first sight → don't register.
                if let previous, !previous.ended {
                    if previous.running, !snapshot.running { emitFinished() }
                    emit(.sessionEnded(reason: Self.exitReason), at: mtime)
                }
                states[path] = FileState(
                    mtime: mtime, sessionId: snapshot.sessionId, cwd: snapshot.cwd,
                    running: false, ended: true, lastProbeAt: now,
                    promptAt: snapshot.promptAt,
                    knownTitle: snapshot.sessionTitle ?? previous?.knownTitle,
                    contextBucket: previous?.contextBucket)
                return
            }
        }
        // Resumed after exiting: the store no longer has this session, so treat it as first sight
        if previous?.ended == true { previous = nil }

        let wasRunning = previous?.running
        if snapshot.running {
            if wasRunning == true {
                // State unchanged: keep the task alive (prevents a false 4h reap)
                emit(.activity(tool: nil), at: mtime)
            } else {
                // Running on first sight / new turn started after idle
                emit(.taskStarted(title: snapshot.promptTitle),
                     at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime)
            }
        } else if wasRunning == nil {
            emit(.sessionStarted, at: mtime)
        } else if wasRunning == true {
            // Turn finished: for sessions without hooks this is the only finish signal; with hooks,
            // Stop arrives first and the session is already idle → the store suppresses the
            // duplicate card
            emitFinished()
        } else if let promptAt = snapshot.promptAt, promptAt != previous?.promptAt {
            // A turn shorter than one poll interval: start and finish fall between two scans.
            // Emitting only the finish would be dropped by the store as a duplicate for an idle
            // session → emit the start first
            emit(.taskStarted(title: snapshot.promptTitle),
                 at: promptAt)
            emitFinished()
        }

        // Emit only when the title/context changed
        if let title = snapshot.sessionTitle, title != previous?.knownTitle {
            emit(.titleUpdate(title: title), at: mtime)
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
            mtime: mtime, sessionId: snapshot.sessionId, cwd: snapshot.cwd,
            running: snapshot.running,
            exitPending: exitPending, lastProbeAt: now,
            promptAt: snapshot.promptAt,
            knownTitle: snapshot.sessionTitle ?? previous?.knownTitle,
            contextBucket: bucket ?? previous?.contextBucket,
            lastSubagents: subagents
        )
    }
}
