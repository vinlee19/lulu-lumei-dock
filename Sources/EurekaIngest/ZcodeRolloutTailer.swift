import Foundation
import EurekaKit
import EurekaStore

/// 增量 tail ZCode 模型 IO 流水（~/.zcode/cli/rollout/model-io-sess_<id>.jsonl）。
/// ZCode 无 hook/notify 回调，这是实时通道（与 grok/kimi tailer 同理）：
/// 轮询近期有写入的 rollout 文件，按 offset 续读、半行不消费；新发现文件只做
/// 尾部状态恢复，不重放历史。会话 cwd 从 db 的 session 表懒查（directory 列）。
/// 子代理文件（`model-io-sess_subagent_*`）跳过：逐行入岛会造成幻影任务，
/// 其 token 由用量扫描器单独收取，现场由 ZcodeSubagentScanner 做快照。
public final class ZcodeRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let rolloutRoot: URL
    private let dbPath: URL
    private let modelConfigURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.zcode-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    /// 会话上下文（cwd 从 db 懒查；缓存避免每轮询都开库）
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var dbMtime: Date?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    /// v2/config.json 的 per-model limit.context（懒加载；ctx% 分母的权威来源）
    private var contextWindows: [String: Int]?

    static let healthName = "zcode 事件监视"

    public init(
        rolloutRoot: URL = ZcodePaths.rolloutRoot(),
        dbPath: URL = ZcodePaths.db(),
        modelConfigURL: URL = ZcodePaths.modelConfig(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.rolloutRoot = rolloutRoot
        self.dbPath = dbPath
        self.modelConfigURL = modelConfigURL
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
        for url in recentRolloutFiles() {
            tail(url)
        }
    }

    // MARK: - 文件发现

    /// rollout/ 下近期（recentWindow 内）有写入、且会话 id 非 subagent 的流水文件
    private func recentRolloutFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(
            at: rolloutRoot, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var results: [URL] = []
        for url in files where url.pathExtension == "jsonl" {
            guard let id = ZcodeRolloutDecoder.sessionId(fileName: url.lastPathComponent),
                  !id.contains("subagent")
            else { continue }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let mtime = values.contentModificationDate,
                  now.timeIntervalSince(mtime) < recentWindow
            else { continue }
            results.append(url)
        }
        return results
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
    /// 单次 JSON 解析同时喂生命周期解码与用量旁路（-> ctx%）。
    private func processLines(_ data: Data, url: URL) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        let ctx = context(for: url)
        var lastUsage: (model: String?, usage: ZcodeRolloutDecoder.Usage)?
        var lastPrompt: String?
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            cursor = complete.index(after: lineEnd)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = ZcodeRolloutDecoder.usageRecord(root) {
                lastUsage = (record.model, record.usage)
            }
            if let prompt = ZcodeRolloutDecoder.userPromptText(root) { lastPrompt = prompt }
            for event in ZcodeRolloutDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                deliver(event)
            }
        }
        // 本批没有生命周期事件但有新用量 -> 至少发一次心跳（模型在跑）
        if lastUsage != nil {
            deliver(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId, kind: .activity(tool: nil),
                timestamp: Date(), cwd: ctx.cwd))
        }
        if let prompt = lastPrompt.flatMap({ summarizeTitle($0) }) {
            deliver(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId,
                kind: .titleUpdate(title: prompt),
                timestamp: Date(), cwd: ctx.cwd))
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
        return complete.count
    }

    private func deliver(_ event: TaskEvent) {
        var enriched = event
        if enriched.cwd == nil, let key = eventKey(for: event.sessionId),
           let ctx = contexts[key] {
            enriched.cwd = ctx.cwd
        }
        HealthRegistry.shared.event(Self.healthName)
        let isStale = Date().timeIntervalSince(enriched.timestamp) > staleThreshold
        handler(enriched, isStale)
    }

    /// 新发现文件：从尾部恢复"最后状态"--
    /// - 最后一条已完成记录是 tool-calls 中间步（无终轮 stop）：补发 running
    /// - 已有终轮（stop/error）：注册为空闲会话
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        let ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 262_144)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastEvent: TaskEvent?
        var finished: TaskEvent?
        var lastUsage: (model: String?, usage: ZcodeRolloutDecoder.Usage)?
        var lastPrompt: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any]
            else { continue }
            if let record = ZcodeRolloutDecoder.usageRecord(root) {
                lastUsage = (record.model, record.usage)
            }
            if let prompt = ZcodeRolloutDecoder.userPromptText(root) { lastPrompt = prompt }
            for event in ZcodeRolloutDecoder.decode(root: root, sessionId: ctx.sessionId, cwd: ctx.cwd) {
                lastEvent = event
                if case .taskFinished = event.kind { finished = event }
            }
        }

        func titleEvent(from base: TaskEvent) {
            guard let title = lastPrompt.flatMap({ summarizeTitle($0) }) else { return }
            var event = base
            event.kind = .titleUpdate(title: title)
            handler(event, false)
        }

        if let finished {
            var event = finished
            event.kind = .sessionStarted  // 已结束：注册为空闲（直接 finished 会造成竞态）
            event.cwd = event.cwd ?? ctx.cwd
            handler(event, false)
            titleEvent(from: event)
        } else if let last = lastEvent {
            var event = last
            event.cwd = event.cwd ?? ctx.cwd
            handler(event, false)  // 中间步 -> running
            titleEvent(from: event)
        } else {
            handler(TaskEvent(
                source: .zcode, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd), false)
        }
        if let lastUsage {
            emitContext(for: url, context: ctx, usage: lastUsage)
        }
    }

    // MARK: - 上下文占用（usage.total ÷ config.json 的 per-model limit.context）

    private func emitContext(
        for url: URL, context ctx: FileContext,
        usage: (model: String?, usage: ZcodeRolloutDecoder.Usage)
    ) {
        if contextWindows == nil {
            contextWindows = ZcodeConfigWindows.parse(configURL: modelConfigURL)
        }
        // 窗口取该次请求模型在 config 里的值；查不到（自定义 provider 未配 limit）不发
        guard let window = usage.model.flatMap({ contextWindows?[$0] }), window > 0
        else { return }
        let percent = min(100, Double(usage.usage.total) / Double(window) * 100)
        // 只在变化时补发，避免刷屏
        if let last = lastContextPercent[url.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[url.path] = percent
        handler(TaskEvent(
            source: .zcode, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd), false)
    }

    // MARK: - 会话上下文（cwd 从 db.session 懒查一次）

    private func eventKey(for sessionId: String) -> String? {
        // 反查：contexts 以文件路径为键，这里按 sessionId 匹配（每会话一个文件）
        contexts.first { $0.value.sessionId == sessionId }?.key
    }

    private func context(for url: URL) -> FileContext {
        let path = url.path
        if let cached = contexts[path] { return cached }
        let sessionId = ZcodeRolloutDecoder.sessionId(fileName: url.lastPathComponent) ?? path
        var ctx = FileContext(sessionId: sessionId, cwd: nil, dbMtime: nil)
        // 懒查 db：directory 列（db 不存在/无该行 -> cwd 留空，岛上显示短 id）
        if let db = try? SQLiteDB(path: dbPath.path, readOnly: true) {
            let rows = (try? db.query(
                "SELECT directory FROM session WHERE id = ?", [.text(sessionId)]) { $0.text(0) }) ?? []
            ctx.cwd = rows.first ?? nil
        }
        contexts[path] = ctx
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
