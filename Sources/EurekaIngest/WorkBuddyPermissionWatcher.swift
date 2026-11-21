import EurekaKit
import Foundation

/// Turns WorkBuddy's pending permission prompts into waiting events.
///
/// WorkBuddy keeps the "waiting for permission" state in memory only; the one durable trace is its
/// audit log (`~/.workbuddy/audit-log/YYYY-MM-DD.jsonl`, one JSON object per line):
/// `eventType:"file-safety.needs-approval"` when it asks, then `file-safety.approved` (or another
/// event for the same `toolCallId`) once answered. Every entry carries `sessionId`, `requestId`,
/// `toolCallId` and a millisecond `timestamp`, and joins the transcripts on `sessionId` and
/// `toolCallId` (verified 100% on 2026-11 data).
///
/// Only a `needs-approval` is turned into `.waiting(.permission)`, and only an entry for a tool
/// call it reported resolves it (`.activity`), because TaskStore registers a task for any event of
/// a session it doesn't know and the log is full of routine `allow-listed` / `sandbox-executed`
/// entries. Previews in the log (`commandPreview`, `contentPreview`, paths) can hold secrets and
/// never leave this type. Scheduled automation runs and internal sessions are skipped, like
/// everywhere else.
///
/// No timer of its own: `WorkBuddyLiveChannel` runs it right after the transcript tailer in the
/// same tick, so a tool call's activity event (written to the transcript first) can't arrive after
/// the waiting event and clear it.
final class WorkBuddyPermissionWatcher {
    typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let root: URL
    private let lookup: CodeBuddySessionLookup?
    private let staleThreshold: TimeInterval
    private let handler: Handler
    /// Byte offset per daily file already read
    private var offsets: [String: UInt64] = [:]
    /// toolCallId → sessionId of prompts reported as waiting and not answered yet
    private var pending: [String: String] = [:]

    static let healthName = "WorkBuddy 授权监视"
    /// How far back the first read of a file looks for a prompt still open at launch
    private static let initialTailBytes: UInt64 = 64 * 1024

    init(
        root: URL, lookup: CodeBuddySessionLookup?, staleThreshold: TimeInterval = 300,
        handler: @escaping Handler
    ) {
        self.root = root
        self.lookup = lookup
        self.staleThreshold = staleThreshold
        self.handler = handler
    }

    func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for file in recentLogFiles() { read(file) }
    }

    /// The two newest daily files (a prompt can open before midnight and close after it)
    private func recentLogFiles() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names
            .filter { Self.isDailyLog($0) }
            .sorted()
            .suffix(2)
            .map { root.appendingPathComponent($0) }
    }

    static func isDailyLog(_ name: String) -> Bool {
        guard name.hasSuffix(".jsonl") else { return false }
        let stem = name.dropLast(".jsonl".count)
        return stem.count == 10 && stem.allSatisfy { $0.isNumber || $0 == "-" }
    }

    private func read(_ file: URL) {
        let path = file.path
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size]
            .flatMap({ ($0 as? NSNumber)?.uint64Value })
        else { return }
        let isFirstRead = offsets[path] == nil
        var offset = offsets[path] ?? (size > Self.initialTailBytes ? size - Self.initialTailBytes : 0)
        if size < offset { offset = 0 }
        guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              let lastNewline = data.lastIndex(of: UInt8(ascii: "\n"))
        else { return }
        var lines = data[data.startIndex...lastNewline].split(separator: UInt8(ascii: "\n"))
        // A first read from mid-file starts mid-line
        if isFirstRead, offset > 0, !lines.isEmpty { lines.removeFirst() }
        offsets[path] = offset + UInt64(lastNewline - data.startIndex + 1)
        guard isFirstRead else {
            for line in lines { absorb(Data(line), report: true) }
            return
        }
        // Catching up at launch: settle the whole window first, then report only the prompts
        // still open, so a prompt answered a minute ago doesn't flash a wait and a resume
        let before = Set(pending.keys)
        var opened: [String: Date] = [:]
        for line in lines {
            if let (toolCallId, timestamp) = absorb(Data(line), report: false) {
                opened[toolCallId] = timestamp
            }
        }
        for (toolCallId, timestamp) in opened.sorted(by: { $0.value < $1.value })
        where !before.contains(toolCallId) {
            guard let sessionId = pending[toolCallId] else { continue }
            emit(.waiting(reason: .permission, message: nil), sessionId, timestamp)
        }
    }

    /// Returns the tool call and time of a prompt it opened (used by the launch catch-up)
    @discardableResult
    private func absorb(_ line: Data, report: Bool) -> (String, Date)? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let eventType = root["eventType"] as? String,
              let sessionId = root["sessionId"] as? String, !sessionId.isEmpty,
              let toolCallId = root["toolCallId"] as? String, !toolCallId.isEmpty
        else { return nil }
        let timestamp = (root["timestamp"] as? NSNumber)
            .map { Date(timeIntervalSince1970: $0.doubleValue / 1000) } ?? Date()

        if eventType == "file-safety.needs-approval" {
            guard pending[toolCallId] == nil, !isExcluded(sessionId) else { return nil }
            pending[toolCallId] = sessionId
            if report { emit(.waiting(reason: .permission, message: nil), sessionId, timestamp) }
            return (toolCallId, timestamp)
        } else if let waitingSession = pending.removeValue(forKey: toolCallId), report {
            emit(.activity(tool: nil), waitingSession, timestamp)
        }
        return nil
    }

    private func isExcluded(_ sessionId: String) -> Bool {
        CodeBuddyDialect.isWorkBuddyInternalSession(sessionId)
            || lookup?(sessionId)?.isAutomation == true
    }

    private func emit(_ kind: TaskEvent.Kind, _ sessionId: String, _ timestamp: Date) {
        HealthRegistry.shared.event(Self.healthName)
        let event = TaskEvent(
            source: .workbuddy, sessionId: sessionId, kind: kind, timestamp: timestamp, cwd: nil)
        handler(event, Date().timeIntervalSince(timestamp) > staleThreshold)
    }
}
