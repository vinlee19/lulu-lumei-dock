import Foundation
import EurekaKit

/// Rebuilds live Claude session state at launch (Codex is handled by the rollout tailer's
/// first-sight scan): for sessions already running before the app started, the UserPromptSubmit was
/// long since consumed/lost, and the heartbeat only arrives after the next tool call ends, so they
/// would stay invisible through long commands / pure generation.
///
/// Rule: after the last real user prompt in the transcript tail, no turn_duration (the turn-end
/// marker) / API error line → the turn is still in flight.
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
        public var aiTitle: String?
        public var contextPercent: Double?
        public var earliestAt: Date?
    }

    /// Live-state verdict for a single transcript (public for tests).
    public static func inspectSession(
        fileURL: URL, mtime: Date, tailBytes: Int = 262144
    ) -> [TaskEvent] {
        guard let snapshot = classify(fileURL: fileURL, tailBytes: tailBytes) else { return [] }

        func event(_ kind: TaskEvent.Kind, at date: Date) -> TaskEvent {
            TaskEvent(
                source: .claude, sessionId: snapshot.sessionId, kind: kind,
                timestamp: date, cwd: snapshot.cwd, transcriptPath: fileURL.path)
        }

        var events: [TaskEvent] = []
        if snapshot.running {
            let title = snapshot.promptText.flatMap { summarizeTitle($0) }
            // Start time: prompt time → earliest time in the tail window (at least never
            // underestimates the duration) → mtime
            events.append(event(
                .taskStarted(title: title),
                at: snapshot.promptAt ?? snapshot.earliestAt ?? mtime))
        } else {
            events.append(event(.sessionStarted, at: mtime))
        }
        if let aiTitle = snapshot.aiTitle {
            events.append(event(.titleUpdate(title: aiTitle), at: mtime))
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
        var aiTitle: String?
        var lastPromptAt: Date?
        var lastPromptText: String?
        var lastTurnEndAt: Date?
        var contextPercent: Double?
        /// Whether the tail shows main-chain execution traces (assistant/tool_result): the
        /// criterion for the middle of a very long turn
        var hasMainChainActivity = false
        var earliestAt: Date?

        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            if sessionId == nil { sessionId = root["sessionId"] as? String }
            if cwd == nil { cwd = root["cwd"] as? String }
            let timestamp = (root["timestamp"] as? String).flatMap {
                isoFormatter.date(from: $0) ?? ISO8601DateFormatter().date(from: $0)
            }
            if let timestamp, earliestAt == nil { earliestAt = timestamp }

            switch type {
            case "ai-title":
                aiTitle = root["aiTitle"] as? String

            case "user":
                guard root["isMeta"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // Real prompt: content is a string; an array (tool_result) is an execution trace
                if let content = message["content"] as? String {
                    lastPromptAt = timestamp
                    lastPromptText = content
                } else {
                    hasMainChainActivity = true
                }

            case "system":
                if root["subtype"] as? String == "turn_duration" {
                    lastTurnEndAt = timestamp
                }

            case "assistant":
                guard root["isSidechain"] as? Bool != true,
                      let message = root["message"] as? [String: Any]
                else { continue }
                // An API error line also means the turn ended (no turn_duration will follow)
                if root["isApiErrorMessage"] as? Bool == true
                    || message["model"] as? String == "<synthetic>" {
                    lastTurnEndAt = timestamp ?? lastTurnEndAt
                    continue
                }
                hasMainChainActivity = true
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
        let running: Bool
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

        return Snapshot(
            sessionId: sessionId,
            cwd: cwd,
            running: running,
            promptAt: lastPromptAt,
            promptText: lastPromptText,
            turnEndAt: lastTurnEndAt,
            aiTitle: aiTitle,
            contextPercent: contextPercent,
            earliestAt: earliestAt
        )
    }
}
