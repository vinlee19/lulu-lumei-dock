import Foundation

/// Background work a Claude main session launched and has not heard back from yet.
///
/// When the main agent starts background work and ends its turn, Claude Code fires `Stop` and
/// writes `end_turn` just as for a finished turn, yet the session is not done: every background
/// task that finishes enqueues a `<task-notification>` that starts another turn on its own. Fed the
/// transcript lines in file order, this tracker tells the two apart.
///
/// Counted: tools whose result is `toolUseResult.status == "async_launched"` (background `Agent`
/// runs carry `agentId`, `Workflow` runs carry `taskId`). Both always end and always report back.
/// Not counted: background `Bash` (`backgroundTaskId`) and `Monitor`. They include long-lived
/// processes such as dev servers and watchers that never report back (13 of 606 local background
/// commands never did), and one of those would hold every later turn of the session open.
///
/// Finished: a `<task-notification>` naming the id, in any of the three shapes Claude Code writes it
/// (the user prompt that starts the follow-up turn, a `queued_command` attachment injected into a
/// turn already running, a `queue-operation` enqueue), or a `TaskStop` result. Only those shapes
/// are read: a tool result may quote another notification verbatim. The last event per id wins, so
/// an agent resumed with SendMessage and reporting twice stays consistent.
///
/// Background tasks run inside the Claude process, so a `cost-state` line (written when the
/// process exits) drops everything still outstanding: a resumed session never inherits them.
///
/// Window: `scan` reads far more than the 256KB classification window, because reports carry whole
/// agent results and Claude Code logs request copies beside them (a real 17-minute wait put 248KB
/// between the first launch and the turn end). A launch that scrolled out even of that window is
/// missed, which falls back to finishing the turn as before; the reverse cannot happen because a
/// report always follows its launch.
public struct ClaudeBackgroundTasks: Equatable {
    /// id → still running
    private var running: [String: Bool] = [:]
    /// How many were still running when the latest `cost-state` dropped them (killed with the
    /// process: an archive while waiting on them is an interruption, not a finish)
    public private(set) var abandonedAtExit = 0

    public init() {}

    /// Ids launched and not yet reported back, in no particular order
    public var pendingIds: Set<String> { Set(running.filter(\.value).keys) }
    public var pendingCount: Int { running.values.filter { $0 }.count }

    /// Feeds one parsed transcript line (`type` already read from it)
    public mutating func observe(_ root: [String: Any], type: String) {
        if type == "cost-state" {
            abandonedAtExit = pendingCount
            running.removeAll()
        }
        if let id = Self.launchedId(root, type: type) { running[id] = true }
        for report in Self.reports(root, type: type) { running[report.id] = false }
        if let id = Self.stoppedId(root, type: type) { running[id] = false }
    }

    /// Default window for `scan`
    public static let scanBytes = 4 * 1024 * 1024

    /// Background tasks over the transcript's last `tailBytes`. Only lines mentioning one of the
    /// markers are decoded, and the request copies Claude Code logs (`api-request-*` lines, which
    /// repeat every report verbatim and run to hundreds of KB) are skipped before any search.
    public static func scan(fileURL: URL, tailBytes: Int = scanBytes) -> ClaudeBackgroundTasks {
        var tasks = ClaudeBackgroundTasks()
        guard
            let handle = FileHandle(forReadingAtPath: fileURL.path),
            let size = try? handle.seekToEnd(), size > 0
        else { return tasks }
        defer { try? handle.close() }
        let length = min(size, UInt64(tailBytes))
        guard (try? handle.seek(toOffset: size - length)) != nil,
              let data = try? handle.readToEnd()
        else { return tasks }
        // Walk the raw bytes: a generic split over megabytes costs more than everything else here
        var matched: [Data] = []
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                let newline: UnsafeMutableRawPointer? = memchr(
                    base + start, Int32(UInt8(ascii: "\n")), buffer.count - start)
                let end = newline.map { UnsafeRawPointer($0) - base } ?? buffer.count
                let line = UnsafeRawBufferPointer(rebasing: buffer[start..<end])
                if !line.starts(with: requestCopyPrefix),
                   markers.contains(where: { contains(line, $0) }) {
                    matched.append(Data(line))
                }
                start = end + 1
            }
        }
        for line in matched {
            guard
                let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let type = root["type"] as? String
            else { continue }
            tasks.observe(root, type: type)
        }
        return tasks
    }

    /// Byte markers of the lines `observe` acts on
    private static let markers: [[UInt8]] = [
        "async_launched", "<task-notification>", "\"task_type\"", "\"cost-state\"",
    ].map { Array($0.utf8) }

    private static let requestCopyPrefix = Array(#"{"type":"api-request"#.utf8)

    private static func contains(_ line: UnsafeRawBufferPointer, _ needle: [UInt8]) -> Bool {
        needle.withUnsafeBytes { pattern in
            memmem(line.baseAddress, line.count, pattern.baseAddress, pattern.count) != nil
        }
    }

    /// A background-task report: `status` is completed / failed / killed / stopped
    public struct Report: Equatable {
        public var id: String
        public var toolUseId: String?
        public var status: String?
    }

    /// The id of a background task launched on the main chain by this line
    public static func launchedId(_ root: [String: Any], type: String) -> String? {
        guard type == "user", root["isSidechain"] as? Bool != true,
              let result = root["toolUseResult"] as? [String: Any],
              result["status"] as? String == "async_launched"
        else { return nil }
        return (result["agentId"] as? String) ?? (result["taskId"] as? String)
    }

    /// Background-task reports carried by this line
    public static func reports(_ root: [String: Any], type: String) -> [Report] {
        let text: String?
        switch type {
        case "user":
            text = (root["message"] as? [String: Any])?["content"] as? String
        case "attachment":
            let attachment = root["attachment"] as? [String: Any]
            text = attachment?["type"] as? String == "queued_command"
                ? attachment?["prompt"] as? String : nil
        case "queue-operation":
            text = root["operation"] as? String == "enqueue" ? root["content"] as? String : nil
        default:
            text = nil
        }
        guard let text, text.contains("<task-notification>") else { return [] }
        return parseReports(text)
    }

    /// The id a `TaskStop` result says it stopped
    static func stoppedId(_ root: [String: Any], type: String) -> String? {
        guard type == "user",
              let result = root["toolUseResult"] as? [String: Any],
              result["task_type"] != nil
        else { return nil }
        return result["task_id"] as? String
    }

    /// Splits a prompt into its `<task-notification>` blocks
    public static func parseReports(_ text: String) -> [Report] {
        text.components(separatedBy: "<task-notification>").dropFirst().compactMap { block in
            guard let id = tag("task-id", in: block) else { return nil }
            return Report(
                id: id, toolUseId: tag("tool-use-id", in: block), status: tag("status", in: block))
        }
    }

    private static func tag(_ name: String, in block: String) -> String? {
        guard let open = block.range(of: "<\(name)>"),
              let close = block.range(of: "</\(name)>", range: open.upperBound..<block.endIndex)
        else { return nil }
        let value = block[open.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
