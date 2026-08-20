import Foundation

/// stdio MCP server 的**深度检测**（v2.8）：短暂启动配置的命令，走规范的
/// stdin/stdout JSON-RPC（newline 分隔）完成 initialize → tools/list（跟分页）
/// → prompts/list / resources/list（能力声明了才问），读完立即结束进程。
///
/// 这是列出 stdio server 工具的**唯一**方式（Claude Desktop / Claude Code 同理）——
/// 没有进程就没有清单。红线口径（v2.8 起）：**只在用户点击「重新检测」时启动**，
/// 绝不自动、绝不常驻；启动的是用户自己配置、各 CLI 每个会话都在跑的命令；
/// env 值只传给子进程（这是它们的既定用途），不落库不记日志；子进程 stderr 丢弃、
/// stdout 只喂解析器；读完先关 stdin，不退再 SIGTERM → SIGKILL，绝不留孤儿进程。
public enum MCPStdioProbe {
    public struct Inspection: Equatable, Sendable {
        public var handshake: MCPProbe.HandshakeInfo
        public var tools: [MCPProbe.ToolInfo]
        public var prompts: [MCPProbe.NamedItem]
        public var resources: [MCPProbe.NamedItem]
        /// tools/list 各页载荷的 token 估算合计（≈ 每轮 schema 税，与 remote 同口径）
        public var schemaTokens: Int
    }

    public enum Failure: Error, Equatable, Sendable {
        case commandMissing
        case launchFailed(String)
        /// 进程起来了但没有合法的 initialize 响应（超时/非 MCP 输出）
        case handshakeFailed(String)
    }

    /// 同步执行（调用方在后台队列上）。timeout 是整体预算：uvx/npx 冷启动可能要
    /// 下载包，给足 20s；每步等待共享同一个 deadline。
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
        // 继承本进程环境（server 需要 PATH/HOME…），配置里的 env 覆盖其上
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

        // ① initialize 真握手（报最新定稿版本，协商回落照记）
        guard send(MCPProbe.initializeRequestBody()) else {
            return .failure(.launchFailed("进程未能接收输入"))
        }
        guard let initLine = channel.nextResponse(id: 1, deadline: deadline, process: process)
        else {
            return .failure(.handshakeFailed(
                process.isRunning ? "等待 initialize 响应超时" : "进程提前退出"))
        }
        guard let info = MCPProbe.parseInitializeResponse(
            initLine, contentType: "application/json")
        else {
            return .failure(.handshakeFailed("initialize 响应不是合法 MCP 握手"))
        }
        _ = send(MCPProbe.initializedNotificationBody())

        // ② tools/list 跟随分页（护栏 ≤20 页且 ≤1000 工具）；schema 税按各页累加
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

        // ③ prompts / resources：能力声明了才问，第一页即可（清单缓存上限由调用方裁）
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

    /// 结束进程：关 stdin（规范的退出信号）→ 0.5s → SIGTERM → 0.5s → SIGKILL
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

/// stdout 行读取器：后台线程累积字节、按 \n 切行；调用方按 JSON-RPC id 取响应。
/// 容错：跳过空行/非 JSON 行/无匹配 id 的行（server 发来的通知与请求一概忽略）。
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

    /// 轮询等待 id 匹配的 JSON-RPC 响应；进程退出且无存量行、或到 deadline 即放弃
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
                // 存量清空且流已关/进程已退 → 不会再有响应
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
