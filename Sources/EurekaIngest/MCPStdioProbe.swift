import EurekaKit
import Foundation

/// **Deep inspection** of stdio MCP servers (v2.8): briefly launches the configured command and,
/// over the spec's stdin/stdout JSON-RPC (newline-delimited), runs initialize → tools/list
/// (following pagination)
/// → prompts/list / resources/list (only if the capability is declared), then ends the process
/// right away.
///
/// This is the **only** way to list a stdio server's tools (same for Claude Desktop / Claude Code): no
/// process, no list. Red line (since v2.8): **launch only when the user clicks "Re-check"**, never
/// automatically, never resident; what gets launched is a command the user configured and each CLI already
/// runs every session; env values are passed only to the child process (their intended use), never stored
/// or logged; the child's stderr is discarded and stdout only feeds the parser; after reading, stdin is
/// closed first, then SIGTERM → SIGKILL if it does not exit, never leaving an orphan process.
public enum MCPStdioProbe {
    public struct Inspection: Equatable, Sendable {
        public var handshake: MCPProbe.HandshakeInfo
        public var tools: [MCPProbe.ToolInfo]
        public var prompts: [MCPProbe.NamedItem]
        public var resources: [MCPProbe.NamedItem]
        /// Sum of token estimates over all tools/list page payloads (≈ per-turn schema tax, same
        /// basis as remote)
        public var schemaTokens: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case commandMissing
        case launchFailed(String)
        /// The process started but produced no valid initialize response (timeout / non-MCP output)
        case handshakeFailed(String)
    }

    /// Runs synchronously (the caller is on a background queue). timeout is the overall budget: a
    /// uvx/npx cold start may need to download packages, so allow a full 20s; every wait shares the
    /// same deadline.
    public static func inspect(
        command: String, args: [String], env: [String: String],
        timeout: TimeInterval = 20
    ) -> Result<Inspection, Failure> {
        guard let executable = MCPProbe.resolveCommand(command) else {
            return .failure(.commandMissing)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        // Inherit this process's environment (servers need PATH/HOME…), with the config's env
        // layered on top
        process.environment = ProcessInfo.processInfo.environment
            .merging(env) { _, configured in configured }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(error.localizedDescription))
        }
        let channel = LineChannel(handle: stdoutPipe.fileHandleForReading)
        defer { shutdown(process, stdin: stdinPipe, channel: channel) }
        let deadline = Date().addingTimeInterval(timeout)

        func send(_ body: Data) -> Bool {
            guard process.isRunning else { return false }
            do {
                try stdinPipe.fileHandleForWriting.write(contentsOf: body + Data("\n".utf8))
                return true
            } catch {
                return false
            }
        }

        // (1) A real initialize handshake (reports the latest finalized version; records whatever
        //     is negotiated down to)
        guard send(MCPProbe.initializeRequestBody()) else {
            return .failure(.launchFailed(L10n.text("The process could not receive input", zhHans: "进程未能接收输入")))
        }
        guard let initLine = channel.nextResponse(id: 1, deadline: deadline, process: process)
        else {
            return .failure(.handshakeFailed(
                process.isRunning ? L10n.text("Timed out waiting for the initialize response", zhHans: "等待 initialize 响应超时") : L10n.text("The process exited early", zhHans: "进程提前退出")))
        }
        guard let info = MCPProbe.parseInitializeResponse(
            initLine, contentType: "application/json")
        else {
            return .failure(.handshakeFailed(L10n.text("The initialize response is not a valid MCP handshake", zhHans: "initialize 响应不是合法 MCP 握手")))
        }
        _ = send(MCPProbe.initializedNotificationBody())

        // (2) tools/list following pagination (guardrails: ≤20 pages and ≤1000 tools); schema tax
        //     accumulates per page
        var tools: [MCPProbe.ToolInfo] = []
        var schemaTokens = 0
        var cursor: String?
        for _ in 0..<20 {
            guard send(MCPProbe.toolsListRequestBody(cursor: cursor)),
                  let line = channel.nextResponse(id: 2, deadline: deadline, process: process),
                  let page = MCPProbe.parseToolsList(line, contentType: "application/json")
            else { break }
            tools += page.tools
            schemaTokens += TokenEstimator.estimate(String(decoding: line, as: UTF8.self))
            cursor = page.nextCursor
            guard cursor != nil, tools.count < 1000 else { break }
        }

        // (3) prompts / resources: only asked if the capability is declared, first page only (the
        //     caller caps the cached list)
        var prompts: [MCPProbe.NamedItem] = []
        if info.capabilities.contains("prompts"),
           send(MCPProbe.promptsListRequestBody()),
           let line = channel.nextResponse(id: 4, deadline: deadline, process: process),
           let page = MCPProbe.parseNamedList(
               line, contentType: "application/json", key: "prompts") {
            prompts = page.items
        }
        var resources: [MCPProbe.NamedItem] = []
        if info.capabilities.contains("resources"),
           send(MCPProbe.resourcesListRequestBody()),
           let line = channel.nextResponse(id: 3, deadline: deadline, process: process),
           let page = MCPProbe.parseNamedList(
               line, contentType: "application/json", key: "resources") {
            resources = page.items
        }

        return .success(Inspection(
            handshake: info, tools: tools, prompts: prompts,
            resources: resources, schemaTokens: schemaTokens))
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

    /// Polls for the JSON-RPC response with a matching id; gives up when the process has exited
    /// with no buffered lines, or at the deadline
    func nextResponse(id: Int, deadline: Date, process: Process) -> Data? {
        while Date() < deadline {
            lock.lock()
            let pending = lines
            lines.removeAll()
            let isClosed = closed
            lock.unlock()
            for line in pending {
                guard let root = (try? JSONSerialization.jsonObject(with: line))
                    as? [String: Any] else { continue }
                if let lineID = root["id"] as? Int, lineID == id { return line }
                if let lineID = root["id"] as? String, lineID == "\(id)" { return line }
            }
            if pending.isEmpty, isClosed || !process.isRunning {
                // Buffer drained and stream closed / process exited → no more responses will come
                lock.lock()
                let drained = lines.isEmpty
                lock.unlock()
                if drained { return nil }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return nil
    }
}
