import Foundation
import EurekaKit

/// 增量 tail Kimi 会话事件（~/.kimi-code/sessions/<ws>/<session>/agents/main/wire.jsonl）。
/// Kimi 无 hook/notify 回调，这是实时通道（与 grok/opencode tailer 同理）：
/// 轮询近期有写入的主 agent wire.jsonl，按 offset 续读、半行不消费；新发现文件只做
/// 尾部状态恢复，不重放历史。会话 id/cwd/标题从上级 state.json 带入（mtime 变了就重读——
/// Kimi 首轮后才生成标题）；上下文占用从 usage.record 累计 ÷ config.toml 的 max_context_size 估算。
/// 只 tail main agent 的事件流（子代理 wire 逐行入岛会造成幻影任务；用量扫描器单独收其 token）。
/// 子 agent 现场由 KimiSubagentScanner 做轻量快照（各 agents/<id>/wire.jsonl 头+尾窗），
/// 在运行中会话上随轮询以 .subagentsUpdated 发出。
public final class KimiWireTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let sessionsRoot: URL
    private let configTomlURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.kimi-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        var modelAlias: String?
        var stateMtime: Date?
        /// 当前是否有未收尾的 turn（子 agent 快照只在运行中扫描）
        var running = false
        /// 当前 turn 起点（taskStarted 时间）：子 agent 快照按它裁到本 turn
        var turnStartedAt: Date?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    private var contextWindows: [String: Int]?  // config.toml max_context_size，懒加载
    /// 各会话上次发出的子 agent 快照（变化才重发；TaskStore 还会再去重）
    private var lastSubagents: [String: [SubagentInfo]] = [:]

    static let healthName = "kimi 事件监视"

    public init(
        sessionsRoot: URL = KimiPaths.sessionsRoot(),
        configTomlURL: URL = KimiPaths.configToml(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.configTomlURL = configTomlURL
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway 让系统合并唤醒省电；必须小于轮询间隔（1s 档用 100ms）
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

    /// 公开供测试与启动时同步调用
    public func scanOnce() {
        HealthRegistry.shared.beat(Self.healthName)
        for url in recentWireFiles() {
            tail(url)
        }
        emitSubagentUpdates()
    }

    // MARK: - 文件发现

    /// sessions/<ws>/<session>/agents/main/wire.jsonl 中近期（recentWindow 内）有写入的
    private func recentWireFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let workspaceDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for workspaceDir in workspaceDirs where isDirectory(workspaceDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: workspaceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let wire = sessionDir.appendingPathComponent("agents/main/wire.jsonl")
                guard let values = try? wire.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                    let mtime = values.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(wire)
            }
        }
        return results
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - 增量读取

    private func tail(_ url: URL) {
        let path = url.path
        guard let size = fileSize(path) else { return }

        guard var offset = offsets[path] else {
            initialScan(url, size: size)
            return
        }
        if size < offset { offset = 0 }  // 文件被截断/重写
        // 即使没有新字节也要刷 state.json（标题在首轮后才生成，且写在 wire 追加之后）
        refreshContextIfStateChanged(url)
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let consumed = processLines(data, url: url)
        offsets[path] = offset + UInt64(consumed)
    }

    /// 处理完整行（最后的半行不消费），返回消费字节数。
    /// 单次 JSON 解析同时喂生命周期解码与旁路（modelAlias / usage → ctx%）。
    private func processLines(_ data: Data, url: URL) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var ctx = context(for: url)
        var lastUsage: (model: String?, usage: KimiWireDecoder.Usage)?
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            cursor = complete.index(after: lineEnd)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            // 旁路：模型别名跟踪（config.update / llm.request）+ 最近一次用量
            if let alias = KimiWireDecoder.modelAlias(root) { ctx.modelAlias = alias }
            if let record = KimiWireDecoder.usageRecord(root) { lastUsage = record }
            let events = KimiWireDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd)
            for event in events {
                switch event.kind {
                case .taskStarted:
                    ctx.running = true
                    ctx.turnStartedAt = event.timestamp
                case .taskFinished:
                    ctx.running = false
                default:
                    break
                }
            }
            deliver(events, context: ctx)
        }
        contexts[url.path] = ctx
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
        return complete.count
    }

    private func deliver(_ events: [TaskEvent], context: FileContext) {
        for var event in events {
            event.sessionStartedAt = context.sessionStartedAt
            HealthRegistry.shared.event(Self.healthName)
            let isStale = Date().timeIntervalSince(event.timestamp) > staleThreshold
            handler(event, isStale)
        }
    }

    /// 新发现文件：从尾部恢复"最后状态"——
    /// - 仍在进行中（最后 turn.prompt 晚于最后 step.end 终轮）：补发 running
    /// - 已结束（或无轮次记录）：以 sessionStarted 注册为空闲
    /// 两种情况都补发 state.json 的标题，让会话卡带名字。
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        var ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 65536)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        var lastUsage: (model: String?, usage: KimiWireDecoder.Usage)?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = KimiWireDecoder.usageRecord(root) { lastUsage = record }
            for event in KimiWireDecoder.decode(
                root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

        // 运行状态与 turn 起点：子 agent 快照按 turn 裁剪、只在运行中扫描
        ctx.running = lastStarted != nil
            && (lastFinished.map { $0.timestamp < lastStarted!.timestamp } ?? true)
        ctx.turnStartedAt = lastStarted?.timestamp
        contexts[path] = ctx

        func titleEvent(from base: TaskEvent) {
            guard let title = ctx.title, !title.isEmpty else { return }
            var event = base
            event.kind = .titleUpdate(title: title)
            handler(event, false)
        }

        if let started = lastStarted,
           lastFinished.map({ $0.timestamp < started.timestamp }) ?? true {
            // 仍在进行中：补发 running（真实开始时间，不按 stale 抑制）
            var event = started
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        } else {
            // 已结束 / 无轮次记录：注册为空闲会话（避免直接发 finished 造成竞态）
            let base = lastFinished ?? lastStarted ?? TaskEvent(
                source: .kimi, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd)
            var event = base
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - 子 agent 快照（agents/<id>/wire.jsonl 头+尾窗，轻量）

    /// 只对已跟踪且运行中的会话扫描（幻影任务不变式：不为未跟踪会话发事件）；
    /// 快照变化才发（TaskStore 还会再去重）；转空闲后清缓存，下一 turn 重新发。
    private func emitSubagentUpdates() {
        for (path, ctx) in contexts {
            guard ctx.running else {
                lastSubagents[path] = []
                continue
            }
            let sessionDir = Self.sessionDir(of: URL(fileURLWithPath: path))
            let subagents = KimiSubagentScanner.scan(
                sessionDir: sessionDir,
                turnStartedAt: ctx.turnStartedAt)
            guard subagents != (lastSubagents[path] ?? []) else { continue }
            lastSubagents[path] = subagents
            HealthRegistry.shared.event(Self.healthName)
            handler(TaskEvent(
                source: .kimi, sessionId: ctx.sessionId,
                kind: .subagentsUpdated(subagents),
                timestamp: Date(), cwd: ctx.cwd,
                sessionStartedAt: ctx.sessionStartedAt), false)
        }
    }

    // MARK: - 上下文占用（usage.record 累计 ÷ config.toml max_context_size）

    private func emitContext(
        for wireURL: URL, context ctx: FileContext,
        usage: (model: String?, usage: KimiWireDecoder.Usage)
    ) {
        let alias = usage.model ?? ctx.modelAlias
        guard let window = contextWindow(for: alias), window > 0 else { return }
        let percent = min(100, Double(usage.usage.total) / Double(window) * 100)
        // 只在变化时补发，避免刷屏
        if let last = lastContextPercent[wireURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[wireURL.path] = percent
        handler(TaskEvent(
            source: .kimi, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    private func contextWindow(for modelAlias: String?) -> Int? {
        guard let modelAlias else { return nil }
        if contextWindows == nil { contextWindows = loadContextWindows() }
        return contextWindows?[modelAlias] ?? contextWindows?["*default*"]
    }

    /// config.toml → { "kimi-code/k3": max_context_size }（懒加载一次；朴素行扫描，不解全量 TOML）。
    /// 段头形如 `[models."kimi-code/k3"]`，段内 `max_context_size = 1048576`。
    private func loadContextWindows() -> [String: Int] {
        var map: [String: Int] = ["*default*": 262144]
        guard let text = try? String(contentsOf: configTomlURL, encoding: .utf8) else {
            return map
        }
        var currentModel: String?
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                if line.hasPrefix("[models.\""), let end = line.range(of: "\"]") {
                    currentModel = String(
                        line[line.index(line.startIndex, offsetBy: "[models.\"".count)..<end.lowerBound])
                } else {
                    currentModel = nil
                }
                continue
            }
            guard let model = currentModel, line.hasPrefix("max_context_size") else { continue }
            let parts = line.components(separatedBy: "=")
            if parts.count == 2,
               let value = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                map[model] = value
            }
        }
        return map
    }

    // MARK: - 会话上下文（上级 state.json，mtime 变了重读 → 标题事件）

    /// wire.jsonl → session 目录（wire.jsonl ← main ← agents ← session_<uuid>）
    private static func sessionDir(of wireURL: URL) -> URL {
        wireURL
            .deletingLastPathComponent()  // main/
            .deletingLastPathComponent()  // agents/
            .deletingLastPathComponent()  // session_<uuid>/
    }

    private func context(for wireURL: URL) -> FileContext {
        let path = wireURL.path
        if let cached = contexts[path] { return cached }
        let ctx = readState(wireURL: wireURL, previous: nil)
        contexts[path] = ctx
        return ctx
    }

    /// state.json mtime 变化 → 重读；标题变了（且非默认）补发 titleUpdate
    private func refreshContextIfStateChanged(_ wireURL: URL) {
        let path = wireURL.path
        guard let cached = contexts[path] else { return }
        let stateURL = Self.sessionDir(of: wireURL).appendingPathComponent("state.json")
        let mtime = (try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let mtime, mtime != cached.stateMtime else { return }
        let fresh = readState(wireURL: wireURL, previous: cached)
        contexts[path] = fresh
        if let title = fresh.title, !title.isEmpty, title != cached.title {
            handler(TaskEvent(
                source: .kimi, sessionId: fresh.sessionId,
                kind: .titleUpdate(title: title),
                timestamp: Date(), cwd: fresh.cwd,
                sessionStartedAt: fresh.sessionStartedAt), false)
        }
    }

    private func readState(wireURL: URL, previous: FileContext?) -> FileContext {
        let sessionDir = Self.sessionDir(of: wireURL)
        var ctx = FileContext(
            sessionId: sessionDir.lastPathComponent,
            cwd: previous?.cwd,
            sessionStartedAt: previous?.sessionStartedAt,
            title: previous?.title,
            modelAlias: previous?.modelAlias,
            stateMtime: previous?.stateMtime)

        let stateURL = sessionDir.appendingPathComponent("state.json")
        ctx.stateMtime = (try? stateURL.resourceValues(
            forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let data = try? Data(contentsOf: stateURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else { return ctx }

        ctx.cwd = (root["workDir"] as? String) ?? ctx.cwd
        ctx.sessionStartedAt = (root["createdAt"] as? String)
            .flatMap(KimiWireDecoder.parseISO) ?? ctx.sessionStartedAt
        let rawTitle = (root["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 默认标题 "New Session" 不当名字（首轮后 Kimi 会替换为真标题）
        if let rawTitle, !rawTitle.isEmpty, rawTitle != "New Session" {
            ctx.title = rawTitle
        }
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
