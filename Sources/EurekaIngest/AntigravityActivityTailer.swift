import Foundation
import EurekaKit

/// Antigravity activity monitor: polls writes (mtime) to conversations/<uuid>.db to decide whether
/// a session is running or idle. The content is a protobuf blob with no readable "what is it doing"
/// text, so it only emits a detail-free running/idle lifecycle:
/// new writes → running (taskStarted/activity); silent beyond idleThreshold → taskFinished → idle.
/// Like the opencode/grok tailers, a hook-less live channel; it never reads DB content, which
/// sidesteps the live-WAL read-only problem.
public final class AntigravityActivityTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let conversationsRoot: URL
    private let runningWindow: TimeInterval   // max age of a first sighting / write that still counts as running
    private let idleThreshold: TimeInterval   // how long a silence ends the turn
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.antigravity-tailer")
    private var timer: DispatchSourceTimer?

    private struct State {
        var lastMtime: Date
        var lastActivityAt: Date
        var running: Bool
        var cwd: String?
    }
    private var states: [String: State] = [:]  // uuid → state

    static let healthName = "Antigravity 活动监视"

    public init(
        conversationsRoot: URL = AntigravityPaths.conversationsRoot(),
        runningWindow: TimeInterval = 45,
        idleThreshold: TimeInterval = 45,
        handler: @escaping Handler
    ) {
        self.conversationsRoot = conversationsRoot
        self.runningWindow = runningWindow
        self.idleThreshold = idleThreshold
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power; must be below the poll interval
        // (100ms for the 1s tier)
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

    /// Public for tests and for a synchronous call at startup
    public func scanOnce(now: Date = Date()) {
        HealthRegistry.shared.beat(Self.healthName)
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: conversationsRoot, includingPropertiesForKeys: nil)) ?? []
        for db in files where db.pathExtension == "db" {
            let uuid = db.deletingPathExtension().lastPathComponent
            guard let mtime = AntigravityPaths.newestMtime(dbURL: db) else { continue }
            inspect(uuid: uuid, dbURL: db, mtime: mtime, now: now)
        }
        reapIdle(now: now)
    }

    private func inspect(uuid: String, dbURL: URL, mtime: Date, now: Date) {
        func cwd() -> String? {
            if states[uuid]?.cwd == nil {
                let c = AntigravityPaths.cwd(dbURL: dbURL)
                states[uuid]?.cwd = c
                return c
            }
            return states[uuid]?.cwd
        }
        func emit(_ kind: TaskEvent.Kind, at ts: Date) {
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .antigravity, sessionId: uuid, kind: kind,
                timestamp: ts, cwd: states[uuid]?.cwd), false)
        }

        guard var state = states[uuid] else {
            // First sighting: set a baseline, don't replay history
            let active = now.timeIntervalSince(mtime) < runningWindow
            states[uuid] = State(
                lastMtime: mtime, lastActivityAt: active ? now : mtime,
                running: active, cwd: nil)
            _ = cwd()  // Cache the workspace
            emit(active ? .taskStarted(title: nil) : .sessionStarted, at: active ? now : mtime)
            return
        }

        if mtime > state.lastMtime {
            // New writes → active
            let wasRunning = state.running
            state.lastMtime = mtime
            state.lastActivityAt = now
            state.running = true
            states[uuid] = state
            _ = cwd()
            emit(wasRunning ? .activity(tool: nil) : .taskStarted(title: nil), at: now)
        }
    }

    /// Running sessions that have gone silent past the timeout → wind down to idle (the next write
    /// taskStarts again)
    private func reapIdle(now: Date) {
        for (uuid, var state) in states where state.running {
            guard now.timeIntervalSince(state.lastActivityAt) > idleThreshold else { continue }
            state.running = false
            states[uuid] = state
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .antigravity, sessionId: uuid,
                kind: .taskFinished(outcome: .success, title: nil, detail: nil),
                timestamp: now, cwd: state.cwd), false)
        }
    }
}
