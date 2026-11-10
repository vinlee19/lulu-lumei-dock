import EurekaKit
import Foundation

/// **Deep inspection** of stdio MCP servers: briefly launches the configured command and, over
/// the spec's stdin/stdout JSON-RPC (newline-delimited in every revision), lets `MCPInspector`
/// read what the server offers, then ends the process right away.
///
/// This is the **only** way to list a stdio server's tools (same for Claude Desktop / Claude Code): no
/// process, no list. What gets launched is a command the user configured and each CLI already runs every
/// session; it is launched when the user asks for a probe or opens that server's detail page, never in the
/// background and never resident. env values are passed only to the child process (their intended use),
/// never stored or logged; stdout only feeds the parser; the tail of stderr is handed back for an
/// on-screen diagnosis and is never persisted; after reading, stdin is closed first, then SIGTERM →
/// SIGKILL if it does not exit, never leaving an orphan process.
public enum MCPStdioProbe {
    public typealias Inspection = MCPInspector.Inspection

    public enum Failure: Error, Equatable, Sendable {
        case commandMissing
        case launchFailed(String)
        /// The process started but produced no valid handshake (timeout / non-MCP output / early
        /// exit)
        case handshakeFailed(String)
    }

    public struct Report: Sendable {
        public var result: Result<Inspection, Failure>
        /// Last few hundred characters the process wrote to stderr; nil when it wrote nothing.
        /// For showing the user why a server did not start — keep it in memory only.
        public var stderrTail: String?
    }

    /// Runs synchronously (the caller is on a background queue). `timeout` is the overall budget
    /// of one launch: a uvx/npx cold start may need to download packages, so allow a full 20s;
    /// every wait shares the same deadline.
    ///
    /// - `environment`: what the child inherits before the config's own `env` is layered on top.
    ///   Pass `LoginShellEnvironment.shared.environment()` from a GUI process, whose own PATH
    ///   does not contain the user's tools.
    /// - `workingDirectory`: the project root for project-scoped servers, whose commands and
    ///   arguments are often relative to it.
    /// - `discoverTimeout`: how long a server may stay silent on `server/discover` before
    ///   `initialize` is sent as well.
    public static func inspectDetailed(
        command: String, args: [String], env: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 20, discoverTimeout: TimeInterval = 3
    ) -> Report {
        guard let executable = MCPProbe.resolveCommand(
            command, pathVariable: environment["PATH"] ?? "",
            workingDirectory: workingDirectory)
        else {
            return Report(result: .failure(.commandMissing), stderrTail: nil)
        }
        var report = launch(
            executable: executable, args: args, env: env, environment: environment,
            workingDirectory: workingDirectory, timeout: timeout,
            discoverTimeout: discoverTimeout, opening: .discover)
        // Some handshake-era servers exit when the first thing they hear is a request they do
        // not know. Give those one more launch that goes straight to `initialize`.
        if report.diedUnanswered {
            report = launch(
                executable: executable, args: args, env: env, environment: environment,
                workingDirectory: workingDirectory, timeout: timeout,
                discoverTimeout: discoverTimeout, opening: .initialize)
        }
        return Report(result: report.result, stderrTail: report.stderrTail)
    }

    /// `inspectDetailed` without the diagnostics
    public static func inspect(
        command: String, args: [String], env: [String: String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 20, discoverTimeout: TimeInterval = 3
    ) -> Result<Inspection, Failure> {
        inspectDetailed(
            command: command, args: args, env: env, environment: environment,
            workingDirectory: workingDirectory, timeout: timeout,
            discoverTimeout: discoverTimeout).result
    }

    private struct LaunchReport {
        var result: Result<Inspection, Failure>
        var stderrTail: String?
        /// The process exited before answering anything
        var diedUnanswered: Bool
    }

    private static func launch(
        executable: String, args: [String], env: [String: String],
        environment: [String: String], workingDirectory: URL?,
        timeout: TimeInterval, discoverTimeout: TimeInterval, opening: MCPInspector.Opening
    ) -> LaunchReport {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Servers need PATH/HOME…; the config's env is layered on top
        process.environment = environment.merging(env) { _, configured in configured }
        if let workingDirectory,
           FileManager.default.fileExists(atPath: workingDirectory.path) {
            process.currentDirectoryURL = workingDirectory
        }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stderr = TailCollector(handle: stderrPipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            stderr.stop()
            return LaunchReport(
                result: .failure(.launchFailed(error.localizedDescription)),
                stderrTail: nil, diedUnanswered: false)
        }
        let channel = StdioChannel(
            process: process, stdin: stdinPipe,
            lines: LineChannel(handle: stdoutPipe.fileHandleForReading),
            deadline: Date().addingTimeInterval(timeout), discoverTimeout: discoverTimeout)
        let outcome = MCPInspector.inspect(channel, opening: opening)
        shutdown(process, stdin: stdinPipe, channel: channel.lines)
        stderr.stop()

        switch outcome {
        case .inspected(let inspection):
            return LaunchReport(
                result: .success(inspection), stderrTail: stderr.tail, diedUnanswered: false)
        case .failed(let status):
            let reason: String
            if case .unreachable(let text) = status { reason = text } else { reason = status.label }
            return LaunchReport(
                result: .failure(.handshakeFailed(reason)), stderrTail: stderr.tail,
                diedUnanswered: opening == .discover && channel.closedUnanswered)
        }
    }

    /// Ends the process: close stdin (the spec's exit signal) → 0.5s → SIGTERM → 0.5s → SIGKILL
    private static func shutdown(_ process: Process, stdin: Pipe, channel: LineChannel) {
        channel.stop()
        try? stdin.fileHandleForWriting.close()
        let graceDeadline = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < graceDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let termDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < termDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }
}

/// `MCPInspectorChannel` over a child process's stdin/stdout
private final class StdioChannel: MCPInspectorChannel {
    let process: Process
    let stdin: Pipe
    let lines: LineChannel
    /// Shared by every wait of this launch
    let deadline: Date
    let discoverTimeout: TimeInterval?
    private var answered = false
    private var closed = false

    /// The process went away without ever answering
    var closedUnanswered: Bool { closed && !answered }

    init(
        process: Process, stdin: Pipe, lines: LineChannel, deadline: Date,
        discoverTimeout: TimeInterval
    ) {
        self.process = process
        self.stdin = stdin
        self.lines = lines
        self.deadline = deadline
        self.discoverTimeout = discoverTimeout
    }

    func send(
        _ request: MCPInspector.Request
    ) -> Result<MCPInspector.Reply, MCPInspector.ChannelFailure> {
        let exited = L10n.text("The process exited early", zhHans: "进程提前退出")
        guard process.isRunning else {
            closed = true
            return .failure(.closed(exited))
        }
        do {
            try stdin.fileHandleForWriting.write(contentsOf: request.body + Data("\n".utf8))
        } catch {
            closed = true
            return .failure(.closed(
                L10n.text("The process could not receive input", zhHans: "进程未能接收输入")))
        }
        guard let id = request.id else {
            return .success(MCPInspector.Reply(data: Data()))
        }
        let until = request.timeout.map { min(deadline, Date().addingTimeInterval($0)) }
            ?? deadline
        switch lines.nextResponse(id: id, deadline: until, process: process) {
        case .line(let data):
            answered = true
            return .success(MCPInspector.Reply(data: data, contentType: "application/json"))
        case .closed:
            closed = true
            return .failure(.closed(exited))
        case .timedOut:
            return .failure(.timedOut)
        }
    }
}

/// Keeps the last bytes a pipe produced (stderr), draining it so the child never blocks on a full
/// pipe
private final class TailCollector {
    private static let limit = 2048
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            if data.isEmpty {
                fh.readabilityHandler = nil
                return
            }
            self.lock.lock()
            self.buffer.append(data)
            if self.buffer.count > Self.limit {
                self.buffer.removeFirst(self.buffer.count - Self.limit)
            }
            self.lock.unlock()
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    /// The last ~300 characters, whitespace-trimmed; nil when nothing was written
    var tail: String? {
        lock.lock()
        let text = String(decoding: buffer, as: UTF8.self)
        lock.unlock()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.suffix(300))
    }
}

/// stdout line reader: a background thread accumulates bytes and splits on \n; the caller fetches
/// responses by JSON-RPC id. Tolerant: skips empty lines / non-JSON lines / lines with no matching
/// id (notifications and requests from the server are ignored).
private final class LineChannel {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private var lines: [Data] = []
    private var closed = false

    init(handle: FileHandle) {
        self.handle = handle
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if data.isEmpty {
                self.closed = true
                fh.readabilityHandler = nil
                return
            }
            self.buffer.append(data)
            while let newline = self.buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = self.buffer.subdata(in: self.buffer.startIndex..<newline)
                self.buffer.removeSubrange(self.buffer.startIndex...newline)
                if !line.isEmpty { self.lines.append(line) }
            }
        }
    }

    func stop() {
        handle.readabilityHandler = nil
    }

    enum Wait {
        case line(Data)
        case timedOut
        /// Stream closed / process exited with nothing left to read
        case closed
    }

    /// Responses read while waiting for another id. A server may answer out of order — e.g. the
    /// reply to a `server/discover` it was slow on arrives after `initialize` went out — so
    /// nothing with an id is thrown away (bounded; ids the probe never asks about just age out).
    private var backlog: [(id: String, line: Data)] = []

    /// Polls for the JSON-RPC response with a matching id; gives up when the process has exited
    /// with no buffered lines, or at the deadline. Notifications and requests from the server
    /// (no `result` / `error`) are ignored.
    func nextResponse(id: Int, deadline: Date, process: Process) -> Wait {
        let wanted = "\(id)"
        while true {
            lock.lock()
            let pending = lines
            lines.removeAll()
            let isClosed = closed
            lock.unlock()
            for line in pending {
                guard let root = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any],
                    root["result"] != nil || root["error"] != nil else { continue }
                let lineID = (root["id"] as? Int).map(String.init) ?? (root["id"] as? String)
                guard let lineID else { continue }
                backlog.append((lineID, line))
            }
            if backlog.count > 64 { backlog.removeFirst(backlog.count - 64) }
            if let index = backlog.firstIndex(where: { $0.id == wanted }) {
                return .line(backlog.remove(at: index).line)
            }
            if pending.isEmpty, isClosed || !process.isRunning {
                // Buffer drained and stream closed / process exited → no more responses will come
                lock.lock()
                let drained = lines.isEmpty
                lock.unlock()
                if drained { return .closed }
            }
            guard Date() < deadline else { return .timedOut }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }
}
