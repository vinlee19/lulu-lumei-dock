import Foundation

/// Side effects emitted by the state machine; the caller (app layer) drives UI / persistence from
/// them
public enum TaskStoreEffect: Equatable, Sendable {
    /// A task finished: show a completion card and write it to history
    case taskFinished(FinishedTask)
    /// A task is waiting for confirmation: show a reminder card
    case taskWaiting(AgentTask)
    /// The active task set changed (count or state); the compact capsule needs a refresh
    case activeTasksChanged
}

/// Session state machine: events in, state table out. Pure logic, no IO; the caller owns thread
/// confinement (main thread in the app). key = source:sessionId.
///
/// Lifecycle: sessionStarted / discovered via heartbeat → idle/running ↔ waiting → (turn done) idle
/// (an open Claude session can run turns repeatedly; Codex is removed on completion) → sessionEnded / timeout → removed.
public final class TaskStore {
    public private(set) var activeTasks: [String: AgentTask] = [:]

    public init() {}

    /// Apply one domain event and return the side effects to execute
    @discardableResult
    public func apply(_ event: TaskEvent) -> [TaskStoreEffect] {
        let key = AgentTask.key(source: event.source, sessionId: event.sessionId)
        let effects = applyKind(event, key: key)
        // Backfill the "session first-start time" from any event onto the task (set only once)
        if let sessionStart = event.sessionStartedAt,
           var task = activeTasks[key], task.sessionStartedAt == nil {
            task.sessionStartedAt = sessionStart
            activeTasks[key] = task
        }
        // Terminal ownership, by contrast, is **updated every time** (not set once): after a
        // session is resumed in another terminal, jumping must land on the current one, not the
        // original one.
        if let terminal = event.terminal, var task = activeTasks[key], task.terminal != terminal {
            task.terminal = terminal
            activeTasks[key] = task
        }
        return effects
    }

    /// Backfill terminal ownership. It is unrelated to events (it comes from probing), so it gets
    /// its own entry point instead of a faked event.
    ///
    /// A binding with `.hook` precision is never overwritten by `.probe` — the former is read directly by the relay inside the session's terminal,
    /// the latter is inferred by matching processes on cwd, so they differ in trust. Returns whether state actually changed.
    @discardableResult
    public func attachTerminal(
        _ binding: TerminalBinding, source: AgentSource, sessionId: String
    ) -> Bool {
        let key = AgentTask.key(source: source, sessionId: sessionId)
        guard var task = activeTasks[key] else { return false }
        if let existing = task.terminal {
            guard existing.origin != .hook || binding.origin == .hook else { return false }
            guard existing != binding else { return false }
        }
        task.terminal = binding
        activeTasks[key] = task
        return true
    }

    private func applyKind(_ event: TaskEvent, key: String) -> [TaskStoreEffect] {
        switch event.kind {
        case .taskStarted(let title):
            if var task = activeTasks[key] {
                // Another submit in the same session (follow-up steering / reply after waiting for
                // input / new turn after idle)
                task.lastActivityAt = event.timestamp
                if task.title == nil { task.title = title }
                if case .idle = task.phase {
                    // New turn after idle: timing restarts now, and the new prompt becomes the new
                    // task name
                    task.startedAt = event.timestamp
                    task.currentActivity = nil
                    task.subagents = []  // Subagents belong to the previous turn; clear them
                    if let title { task.title = title }
                }
                if case .running = task.phase {} else { task.phase = .running }
                activeTasks[key] = task
                return [.activeTasksChanged]
            }
            activeTasks[key] = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: title,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .running
            )
            return [.activeTasksChanged]

        case .taskFinished(let outcome, let title, let detail):
            let existing = activeTasks[key]
            if var task = existing, case .idle = task.phase {
                // Duplicate completion signal for an already-finished session (hooks and transcript
                // watching are dual sources): just refresh liveness; never emit a card or write
                // history twice
                task.lastActivityAt = event.timestamp
                activeTasks[key] = task
                return []
            }
            let finished = FinishedTask(
                source: event.source,
                sessionId: event.sessionId,
                title: title ?? existing?.title,
                cwd: event.cwd ?? existing?.cwd,
                startedAt: existing?.startedAt,
                sessionStartedAt: existing?.sessionStartedAt ?? event.sessionStartedAt,
                finishedAt: event.timestamp,
                outcome: outcome,
                detail: detail,
                terminal: existing?.terminal
            )
            if var task = existing {
                // Known session (Claude/Codex): turn ended → go idle and wait for the next prompt
                // Idle Codex sessions are silently reaped by reapStaleTasks after idleTimeout
                task.phase = .idle
                task.lastActivityAt = event.timestamp
                task.currentActivity = nil
                task.subagents = []  // Subagents belong to this turn; clear them on finish
                if task.title == nil { task.title = title }
                activeTasks[key] = task
            } else {
                // Unknown session that missed its start event: leave no idle ghost behind
                activeTasks.removeValue(forKey: key)
            }
            return [.taskFinished(finished), .activeTasksChanged]

        case .waiting(let reason, let message):
            if var task = activeTasks[key] {
                task.phase = .waiting(reason, since: event.timestamp)
                task.lastActivityAt = event.timestamp
                activeTasks[key] = task
                return [.taskWaiting(task), .activeTasksChanged]
            }
            // Missed the start event (hooks installed mid-turn): register in the waiting state
            let task = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: nil,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .waiting(reason, since: event.timestamp)
            )
            _ = message  // The message text is not used as a title (titleUpdate brings the ai-title)
            activeTasks[key] = task
            return [.taskWaiting(task), .activeTasksChanged]

        case .activity(let tool):
            guard var task = activeTasks[key] else {
                // Heartbeat discovered an unknown session (app launched mid-turn): register it as
                // running
                activeTasks[key] = AgentTask(
                    source: event.source,
                    sessionId: event.sessionId,
                    title: nil,
                    cwd: event.cwd,
                    startedAt: event.timestamp,
                    phase: .running,
                    currentActivity: tool
                )
                return [.activeTasksChanged]
            }
            task.lastActivityAt = event.timestamp
            var effects: [TaskStoreEffect] = []
            switch task.phase {
            case .waiting, .idle:
                // Wait resolved / an idle session has a tool running → running
                task.phase = .running
                effects.append(.activeTasksChanged)
            case .running:
                break
            }
            if let tool, tool != task.currentActivity {
                task.currentActivity = tool
                // The tool changed, so the previous tool's target string is stale (PostToolUse
                // carries only the name, not the target)
                task.currentToolDetail = nil
                if effects.isEmpty { effects.append(.activeTasksChanged) }
            }
            if task.isCompacting {
                task.isCompacting = false  // Tool activity means compaction has finished
                if effects.isEmpty { effects.append(.activeTasksChanged) }
            }
            activeTasks[key] = task
            return effects

        case .toolPending(let tool, let detail):
            guard var task = activeTasks[key] else {
                // Same fallback as activity: when the app launches mid-turn, register as running
                // first
                var task = AgentTask(
                    source: event.source,
                    sessionId: event.sessionId,
                    cwd: event.cwd,
                    startedAt: event.timestamp,
                    phase: .running,
                    currentActivity: tool
                )
                task.currentToolDetail = detail
                activeTasks[key] = task
                return [.activeTasksChanged]
            }
            task.lastActivityAt = event.timestamp
            // PreToolUse arrives **before** the permission prompt, so setting running here is
            // correct; the Notification right after it flips it back to waiting and borrows the
            // target string stored here.
            if case .running = task.phase {} else { task.phase = .running }
            task.currentActivity = tool
            task.currentToolDetail = detail
            task.isCompacting = false
            activeTasks[key] = task
            return [.activeTasksChanged]

        case .compacting:
            guard var task = activeTasks[key], !task.isCompacting else { return [] }
            task.isCompacting = true
            task.lastActivityAt = event.timestamp
            activeTasks[key] = task
            return [.activeTasksChanged]

        case .contextUpdate(let percent):
            guard var task = activeTasks[key] else { return [] }
            // Refresh the UI only when the integer bucket changes, avoiding high-frequency
            // fractional jitter
            let oldBucket = task.contextUsedPercent.map { Int($0.rounded()) }
            task.contextUsedPercent = percent
            task.lastActivityAt = event.timestamp
            activeTasks[key] = task
            return Int(percent.rounded()) == oldBucket ? [] : [.activeTasksChanged]

        case .titleUpdate(let title):
            guard var task = activeTasks[key], task.title != title else { return [] }
            task.title = title
            activeTasks[key] = task
            return [.activeTasksChanged]

        case .subagentsUpdated(let subagents):
            // Don't create a session out of thin air for subagent events; skip the UI refresh when
            // the list is unchanged (prevents 5s jitter)
            guard var task = activeTasks[key] else { return [] }
            guard task.subagents != subagents else { return [] }
            task.subagents = subagents
            task.lastActivityAt = event.timestamp
            activeTasks[key] = task
            return [.activeTasksChanged]

        case .sessionStarted:
            guard activeTasks[key] == nil else { return [] }
            // Session open but no task run yet: register as idle (visible in the task list)
            activeTasks[key] = AgentTask(
                source: event.source,
                sessionId: event.sessionId,
                title: nil,
                cwd: event.cwd,
                startedAt: event.timestamp,
                phase: .idle
            )
            return [.activeTasksChanged]

        case .sessionEnded(let reason):
            guard let task = activeTasks.removeValue(forKey: key) else { return [] }
            if case .idle = task.phase {
                // Idle session closed normally: not a task interruption, no card
                return [.activeTasksChanged]
            }
            // Session ended while the task was still running → treat as interrupted
            let finished = FinishedTask(
                source: event.source,
                sessionId: event.sessionId,
                title: task.title,
                cwd: task.cwd,
                startedAt: task.startedAt,
                sessionStartedAt: task.sessionStartedAt,
                finishedAt: event.timestamp,
                outcome: .interrupted,
                detail: reason.map {
                    L10n.format("Session ended (%@)", zhHans: "会话结束（%@）", String($0))
                },
                terminal: task.terminal
            )
            return [.taskFinished(finished), .activeTasksChanged]
        }
    }

    /// Reap timed-out tasks (fallback for lost hooks): running/waiting timeout → mark interrupted
    /// and emit a card; idle timeout (shorter, SessionEnd may have been missed) → remove silently
    @discardableResult
    public func reapStaleTasks(
        now: Date, runningTimeout: TimeInterval, idleTimeout: TimeInterval = 3600
    ) -> [TaskStoreEffect] {
        var effects: [TaskStoreEffect] = []
        var changed = false
        for (key, task) in activeTasks {
            let timeout: TimeInterval
            if case .idle = task.phase { timeout = idleTimeout } else { timeout = runningTimeout }
            guard now.timeIntervalSince(task.lastActivityAt) > timeout else { continue }
            activeTasks.removeValue(forKey: key)
            changed = true
            if case .idle = task.phase { continue }
            effects.append(.taskFinished(FinishedTask(
                source: task.source,
                sessionId: task.sessionId,
                title: task.title,
                cwd: task.cwd,
                startedAt: task.startedAt,
                sessionStartedAt: task.sessionStartedAt,
                finishedAt: now,
                outcome: .interrupted,
                detail: L10n.text(
                    "Cleared automatically after a long period with no activity",
                    zhHans: "长时间无活动，已自动清理"),
                terminal: task.terminal
            )))
        }
        if changed { effects.append(.activeTasksChanged) }
        return effects
    }

    /// Running/waiting tasks, sorted by start time (capsule count, cards)
    public var sortedActiveTasks: [AgentTask] {
        activeTasks.values
            .filter { if case .idle = $0.phase { return false } else { return true } }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Idle sessions, sorted by most recent activity (the task list's "idle" group)
    public var sortedIdleTasks: [AgentTask] {
        activeTasks.values
            .filter { if case .idle = $0.phase { return true } else { return false } }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
    }
}
