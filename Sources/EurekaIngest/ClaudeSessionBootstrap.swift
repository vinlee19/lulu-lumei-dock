import Foundation
import EurekaKit

/// Rebuilds live Claude session state at launch (Codex is handled by the rollout tailer's
/// first-sight scan): for sessions already running before the app started, the UserPromptSubmit was
/// long since consumed/lost, and the heartbeat only arrives after the next tool call ends, so they
/// would stay invisible through long commands / pure generation.
///
/// Rule: no turn-end marker after the last real user prompt at the transcript tail → the turn is
/// still in flight.
/// End markers: a main-chain assistant line with `stop_reason == "end_turn"` / a user-interrupt
/// line / an API-error line / `turn_duration` (written only by the CLI entrypoint; desktop
/// `entrypoint: claude-desktop` never writes it).
public enum ClaudeSessionBootstrap {
    /// Defaults to ~/.claude/projects (overridden by EUREKA_CLAUDE_PROJECTS, same convention as the
    /// usage scanner)
    public static func defaultProjectsRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CLAUDE_PROJECTS"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    /// Scans recently active session transcripts and synthesizes state-rebuild events.
    /// Looks only two levels deep, at projects/<project>/<session>.jsonl (subagents/ holds subagent
    /// side chains, not sessions).
    public static func discover(
        projectsRoot: URL,
        idleWindow: TimeInterval = 1800,
        now: Date = Date()
    ) -> [TaskEvent] {
        let fm = FileManager.default
        var events: [TaskEvent] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let files = (try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                guard now.timeIntervalSince(mtime) < idleWindow else { continue }
                events.append(contentsOf: inspectSession(fileURL: file, mtime: mtime))
            }
        }
        return events
    }

    /// Live session snapshot (the tail-window classification result)
    public struct Snapshot: Equatable {
        public var sessionId: String
        public var cwd: String?
        public var running: Bool
        public var promptAt: Date?
        public var promptText: String?
        public var turnEndAt: Date?
        /// Outcome of the latest end marker (user interrupt → interrupted, anything else → success;
        /// API errors are escalated to error by EventPipeline's ClaudeErrorSniffer)
        public var turnEndOutcome: TaskOutcome?
        /// Inline custom-title (Desktop auto-naming / `/rename`); when the tail has none this already
        /// fell back to the sidecar `custom-title.json`
        public var customTitle: String?
        /// Legacy ai-title (not written since 2.1.27x; only old sessions have it)
        public var aiTitle: String?
        public var contextPercent: Double?
        public var earliestAt: Date?
        /// The last line is `cost-state`: the final line a Claude process writes when it **exits**
        /// (archive / Desktop's idle sweep / a scheduled task finishing). A fresh live session never
        /// has it, but a **resumed** process writes one at startup too, so on its own it cannot
        /// prove death: `ClaudeResumeProbe` must also find no live process carrying this id.
        public var exitMarkerLast: Bool = false
        /// Background agents / workflows that have not reported back (see `ClaudeBackgroundTasks`;
        /// counted over its larger window once the turn has ended). Each report starts another
        /// turn by itself, so a turn that ends while this is non-zero has not finished the work.
        public var pendingBackgroundTasks: Int = 0
        /// With `exitMarkerLast`: background tasks still running when the process exited (they die
        /// with it, so the session ends interrupted rather than finished)
        public var abandonedBackgroundTasks: Int = 0
        /// Time of the last prompt the user typed, skipping `<task-notification>` prompts: where a
        /// chain of turns driven by background reports began
        public var userPromptAt: Date?

        /// The turn has ended, but background tasks it launched will start another one: the
        /// session is still working. An interrupted turn finishes as usual.
        public var awaitingBackgroundTasks: Int {
            running || turnEndOutcome == .interrupted ? 0 : pendingBackgroundTasks
        }

        /// Session name: the custom one (user / Desktop) wins over the auto-generated one (see
        /// `ClaudeSessionTitle`)
        public var sessionTitle: String? { customTitle ?? aiTitle }

        /// Task name: summarized after stripping injected blocks (e.g. background-task
        /// `<task-notification>` reports); stripped to empty → nil, and TaskStore keeps the
        /// session's previous title
        public var promptTitle: String? {
            promptText.flatMap { TurnSlicer.realPrompt($0) }.flatMap { summarizeTitle($0) }
        }
    }

    /// Live-state verdict for a single transcript (public for tests).
    /// `isResumedAlive`: whether a live process carries this session id (defaults to the process
    /// table; tests inject it).
    public static func inspectSession(
        fileURL: URL, mtime: Date, tailBytes: Int = 262144,
        isResumedAlive: (String) -> Bool = ClaudeResumeProbe.isAlive
    ) -> [TaskEvent] {
        guard let snapshot = classify(fileURL: fileURL, tailBytes: tailBytes) else { return [] }
        // The writer has exited → don't register: otherwise archived / swept sessions would hang in
        // the island's idle list for an hour
        if snapshot.exitMarkerLast, !isResumedAlive(snapshot.sessionId) { return [] }

        func event(_ kind: TaskEvent.Kind, at date: Date) -> TaskEvent {
            TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: fileURL.path)
        }

        var events: [TaskEvent] = []
        let awaiting = snapshot.awaitingBackgroundTasks
        if snapshot.running || awaiting > 0 {
            let title = snapshot.promptTitle
            // Start time: prompt time → earliest time in the tail window (at least never
            // underestimates the duration) → mtime
            events.append(event(
                .taskStarted(title: title),
                at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime))
            if awaiting > 0 {
                events.append(event(
                    .awaitingBackgroundTasks(count: awaiting), at: snapshot.turnEndAt ?? mtime))
            }
        } else {
            events.append(event(.sessionStarted, at: mtime))
        }
        if let title = snapshot.sessionTitle {
            events.append(event(.titleUpdate(title: title), at: mtime))
        }
        if let percent = snapshot.contextPercent {
            events.append(event(.contextUpdate(percent: percent), at: mtime))
        }
        return events
    }

    /// Tail-window classification: whether the turn is in flight.
    /// The tail window must be large: in a long turn the real prompt can be hundreds of KB back.
    public static func classify(fileURL: URL, tailBytes: Int = 262144) -> Snapshot? {
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return nil }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var sessionId: String?
        var cwd: String?
        var customTitle: String?
        var aiTitle: String?
        var lastPromptAt: Date?
        var lastPromptText: String?
        var lastTurnEndAt: Date?
        var lastTurnEndOutcome: TaskOutcome?
        var contextPercent: Double?
        /// Whether the tail shows main-chain execution traces (assistant/tool_result): the
        /// criterion for the middle of a very long turn
        var hasMainChainActivity = false
        var earliestAt: Date?
        /// Type of the last parsable line in the tail window (exit-marker check)
        var lastType: String?
        var backgroundTasks = ClaudeBackgroundTasks()
        var lastUserPromptAt: Date?
        /// Last background report queued for delivery (`queue-operation` enqueue)
        var lastQueuedReportAt: Date?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            lastType = type
            if sessionId == nil { sessionId = root["sessionId"] as? String }
            if cwd == nil { cwd = root["cwd"] as? String }
            let timestamp = (root["timestamp"] as? String).flatMap {
                isoFormatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            if let timestamp, earliestAt == nil { earliestAt = timestamp }
            backgroundTasks.observe(root, type: type)

            switch type {
            case "queue-operation":
                if !ClaudeBackgroundTasks.reports(root, type: type).isEmpty {
                    lastQueuedReportAt = timestamp ?? lastQueuedReportAt
                }

            case "custom-title", "ai-title":
                // Latest line of each kind wins (after /rename the new name comes later)
                if let (isCustom, title) = ClaudeSessionTitle.line(root) {
                    if isCustom { customTitle = title } else { aiTitle = title }
                }

            case "user":
                guard root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // Real prompt: content is a string; an array (tool_result) is an execution trace
                if let content = message["content"] as? String {
                    lastPromptAt = timestamp
                    lastPromptText = content
                    if !content.hasPrefix("<task-notification>") { lastUserPromptAt = timestamp }
                } else if isInterruptMarker(message["content"]) {
                    // User pressed Esc to interrupt: no end_turn / Stop will follow
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .interrupted
                } else {
                    hasMainChainActivity = true
                }

            case "system":
                if root["subtype"] as? String == "turn_duration" {
                    lastTurnEndAt = timestamp
                    lastTurnEndOutcome = .success
                }

            case "assistant":
                guard root["isSidechain"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // An API error line also means the turn ended (no turn_duration will follow)
                if root["isApiErrorMessage"] as? Bool == true
                    || message["model"] as? String == "<synthetic>" {
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .success
                    continue
                }
                hasMainChainActivity = true
                // Model wraps up on its own (no more tool calls) = turn end; desktop has no
                // turn_duration, so this is its only end marker
                if message["stop_reason"] as? String == "end_turn" {
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    lastTurnEndOutcome = .success
                }
                if let usage = message["usage"] as? [String: Any] {
                    let used = (usage["input_tokens"] as? Int ?? 0)
                        + (usage["cache_read_input_tokens"] as? Int ?? 0)
                        + (usage["cache_creation_input_tokens"] as? Int ?? 0)
                    if used > 0 {
                        contextPercent = ContextWindows.percent(
                            used: used, model: message["model"] as? String)
                    }
                }

            default:
                break
            }
        }

        guard let sessionId else { return nil }
        // No inline custom-title in the tail (CLI session / pushed out by huge lines) → fall back to
        // the sidecar, one small file read
        if customTitle == nil {
            customTitle = ClaudeSessionTitle.sidecar(transcriptURL: fileURL)
        }
        var running: Bool
        if let promptAt = lastPromptAt {
            // Prompt visible with no end marker after it → in flight
            running = lastTurnEndAt.map { $0 < promptAt } ?? true
        } else if lastTurnEndAt != nil {
            // Only an end marker seen → the previous turn already wrapped up
            running = false
        } else {
            // Middle of a very long turn: prompt and end marker both scrolled out of the tail
            // window and it is full of execution traces → in flight
            running = hasMainChainActivity
        }
        // A background report queued after the turn ended starts the next turn: Claude Code writes
        // the enqueue ~30ms before that turn's prompt line, and a poll landing in between must not
        // take the gap for a finished turn
        if !running, let queuedAt = lastQueuedReportAt,
           queuedAt > (lastTurnEndAt ?? .distantPast), queuedAt > (lastPromptAt ?? .distantPast) {
            running = true
        }
        // Once the turn has ended the count decides between waiting and finishing, so it is read
        // over the larger background window; mid-turn the tail window is enough
        let background = running ? backgroundTasks : ClaudeBackgroundTasks.scan(fileURL: fileURL)

        return Snapshot(
            sessionId: sessionId,
            cwd: cwd,
            running: running,
            promptAt: lastPromptAt,
            promptText: lastPromptText,
            turnEndAt: lastTurnEndAt,
            turnEndOutcome: lastTurnEndOutcome,
            customTitle: customTitle,
            aiTitle: aiTitle,
            contextPercent: contextPercent,
            earliestAt: earliestAt,
            exitMarkerLast: lastType == "cost-state",
            pendingBackgroundTasks: background.pendingCount,
            abandonedBackgroundTasks: lastType == "cost-state" ? background.abandonedAtExit : 0,
            userPromptAt: lastUserPromptAt
        )
    }

    /// Interrupt line: a text item in the content array starts with "[Request interrupted by user"
    /// (including the "... for tool use]" variant)
    private static func isInterruptMarker(_ content: Any?) -> Bool {
        guard let items = content as? [[String: Any]] else { return false }
        return items.contains {
            $0["type"] as? String == "text"
                && ($0["text"] as? String)?.hasPrefix("[Request interrupted by user") == true
        }
    }
}
