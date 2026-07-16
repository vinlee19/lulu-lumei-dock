import Foundation
import EurekaKit

/// 增量 tail grok 会话事件（~/.grok/sessions/<enc-cwd>/<uuid>/events.jsonl）。
/// grok 无 hook/notify 回调，这是实时通道（与 opencode/Codex tailer 同理）：
/// 轮询近期有写入的 events.jsonl，按 offset 续读、半行不消费；新发现文件只做尾部
/// 状态恢复，不重放历史。会话 id/cwd/标题从同目录 summary.json 带入，上下文占用从
/// 同目录 updates.jsonl 的 totalTokens ÷ 模型 context_window 估算。
public final class GrokRolloutTailer {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let sessionsRoot: URL
    private let modelsCacheURL: URL
    private let staleThreshold: TimeInterval
    private let recentWindow: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.vinlee.eureka.grok-tailer")
    private var timer: DispatchSourceTimer?

    private var offsets: [String: UInt64] = [:]
    private struct FileContext {
        var sessionId: String
        var cwd: String?
        var sessionStartedAt: Date?
        var title: String?
        var modelId: String?
    }
    private var contexts: [String: FileContext] = [:]
    private var lastContextPercent: [String: Double] = [:]
    private var contextWindows: [String: Int]?  // models_cache.json，懒加载

    static let healthName = "grok 事件监视"

    public init(
        sessionsRoot: URL = GrokPaths.sessionsRoot(),
        modelsCacheURL: URL = GrokPaths.modelsCache(),
        staleThreshold: TimeInterval = 300,
        recentWindow: TimeInterval = 2 * 86400,
        handler: @escaping Handler
    ) {
        self.sessionsRoot = sessionsRoot
        self.modelsCacheURL = modelsCacheURL
        self.staleThreshold = staleThreshold
        self.recentWindow = recentWindow
        self.handler = handler
    }

    public func start(pollInterval: TimeInterval = 2) {
        HealthRegistry.shared.register(Self.healthName, expectedInterval: pollInterval)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: pollInterval)
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
        for url in recentEventFiles() {
            tail(url)
        }
    }

    // MARK: - 文件发现

    /// sessions/<enc-cwd>/<uuid>/events.jsonl 中近期（recentWindow 内）有写入的。
    /// 顶层的 session_search.sqlite、cwd 层的 prompt_history.jsonl 都不是目录，天然跳过。
    private func recentEventFiles(now: Date = Date()) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []
        let cwdDirs = (try? fm.contentsOfDirectory(
            at: sessionsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for cwdDir in cwdDirs where isDirectory(cwdDir) {
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: cwdDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for sessionDir in sessionDirs where isDirectory(sessionDir) {
                let events = sessionDir.appendingPathComponent("events.jsonl")
                guard let values = try? events.resourceValues(
                    forKeys: [.contentModificationDateKey]),
                    let mtime = values.contentModificationDate,
                    now.timeIntervalSince(mtime) < recentWindow
                else { continue }
                results.append(events)
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
        guard size > offset else { return }

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return }

        let ctx = context(for: url)
        let consumed = processLines(data, context: ctx)
        offsets[path] = offset + UInt64(consumed)
        if consumed > 0 { emitContext(for: url, context: ctx) }
    }

    /// 处理完整行（最后的半行不消费），返回消费字节数
    private func processLines(_ data: Data, context: FileContext) -> Int {
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return 0 }
        let complete = data[data.startIndex...lastNewline]
        var cursor = complete.startIndex
        while cursor < complete.endIndex {
            let lineEnd = complete[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? complete.endIndex
            let line = complete[cursor..<lineEnd]
            if !line.isEmpty {
                deliver(
                    GrokEventDecoder.decode(
                        line: Data(line), sessionId: context.sessionId, cwd: context.cwd),
                    context: context)
            }
            cursor = complete.index(after: lineEnd)
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
    /// - 仍在进行中（最后 turn_started 晚于最后 turn_ended）：补发 running
    /// - 已结束（或无 turn 记录）：以 sessionStarted 注册为空闲
    /// 两种情况都补发 summary.json 的标题，让会话卡带名字。
    private func initialScan(_ url: URL, size: UInt64) {
        let path = url.path
        let ctx = context(for: url)
        offsets[path] = size

        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        let tailLength: UInt64 = min(size, 65536)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return }

        var lastStarted: TaskEvent?
        var lastFinished: TaskEvent?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            for event in GrokEventDecoder.decode(
                line: Data(line), sessionId: ctx.sessionId, cwd: ctx.cwd) {
                switch event.kind {
                case .taskStarted: lastStarted = event
                case .taskFinished: lastFinished = event
                default: break
                }
            }
        }

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
            // 已结束 / 无 turn 记录：注册为空闲会话（避免直接发 finished 造成竞态）
            let base = lastFinished ?? lastStarted ?? TaskEvent(
                source: .grok, sessionId: ctx.sessionId, kind: .sessionStarted,
                timestamp: Date(), cwd: ctx.cwd)
            var event = base
            event.kind = .sessionStarted
            event.sessionStartedAt = ctx.sessionStartedAt
            handler(event, false)
            titleEvent(from: event)
        }
        emitContext(for: url, context: ctx)
    }

    // MARK: - 上下文占用（updates.jsonl 的 totalTokens ÷ 模型窗口）

    private func emitContext(for eventsURL: URL, context ctx: FileContext) {
        guard let window = contextWindow(for: ctx.modelId), window > 0,
              let tokens = latestTotalTokens(sessionDir: eventsURL.deletingLastPathComponent())
        else { return }
        let percent = min(100, Double(tokens) / Double(window) * 100)
        // 只在变化时补发，避免刷屏
        if let last = lastContextPercent[eventsURL.path], abs(last - percent) < 0.5 { return }
        lastContextPercent[eventsURL.path] = percent
        handler(TaskEvent(
            source: .grok, sessionId: ctx.sessionId,
            kind: .contextUpdate(percent: percent),
            timestamp: Date(), cwd: ctx.cwd,
            sessionStartedAt: ctx.sessionStartedAt), false)
    }

    /// 读 updates.jsonl 尾部，取最近一次 `_meta.totalTokens`
    private func latestTotalTokens(sessionDir: URL) -> Int? {
        let updates = sessionDir.appendingPathComponent("updates.jsonl")
        guard let size = fileSize(updates.path), size > 0,
              let handle = FileHandle(forReadingAtPath: updates.path)
        else { return nil }
        defer { try? handle.close() }
        let tailLength = min(size, 16384)
        guard (try? handle.seek(toOffset: size - tailLength)) != nil,
              let data = try? handle.readToEnd()
        else { return nil }
        var latest: Int?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any],
                  let params = root["params"] as? [String: Any],
                  let meta = params["_meta"] as? [String: Any],
                  let total = meta["totalTokens"] as? Int
            else { continue }
            latest = total
        }
        return latest
    }

    private func contextWindow(for modelId: String?) -> Int? {
        guard let modelId else { return nil }
        if contextWindows == nil { contextWindows = loadContextWindows() }
        return contextWindows?[modelId] ?? contextWindows?["*default*"]
    }

    /// models_cache.json → { modelId: context_window }（懒加载一次）
    private func loadContextWindows() -> [String: Int] {
        var map: [String: Int] = ["*default*": 256000]
        guard let data = try? Data(contentsOf: modelsCacheURL),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let models = root["models"] as? [String: Any]
        else { return map }
        for (id, value) in models {
            guard let entry = value as? [String: Any],
                  let info = entry["info"] as? [String: Any],
                  let window = info["context_window"] as? Int
            else { continue }
            map[id] = window
        }
        return map
    }

    // MARK: - 上下文（同目录 summary.json）

    private func context(for eventsURL: URL) -> FileContext {
        let path = eventsURL.path
        if let cached = contexts[path] { return cached }

        let sessionDir = eventsURL.deletingLastPathComponent()
        // 目录名（uuid）作 session id 兜底，与 active_sessions.json 的 session_id 一致
        var ctx = FileContext(
            sessionId: sessionDir.lastPathComponent, cwd: nil,
            sessionStartedAt: nil, title: nil, modelId: nil)

        let summary = sessionDir.appendingPathComponent("summary.json")
        if let data = try? Data(contentsOf: summary),
           let object = try? JSONSerialization.jsonObject(with: data),
           let root = object as? [String: Any] {
            if let info = root["info"] as? [String: Any] {
                if let id = info["id"] as? String, !id.isEmpty { ctx.sessionId = id }
                ctx.cwd = info["cwd"] as? String
            }
            ctx.cwd = ctx.cwd ?? (root["cwd"] as? String)
            ctx.sessionStartedAt = GrokEventDecoder.parseDate(root["created_at"] as? String)
            ctx.title = (root["generated_title"] as? String)
                ?? (root["session_summary"] as? String)
            ctx.modelId = root["current_model_id"] as? String
        }
        contexts[path] = ctx
        return ctx
    }

    private func fileSize(_ path: String) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? nil
    }
}
