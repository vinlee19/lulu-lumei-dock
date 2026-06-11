import Foundation
import EurekaKit

/// 事件管道：spool（Claude hooks + Codex notify）与 Codex rollout tailer 两路汇流，
/// 统一做去重与富化（错误嗅探/ai-title），串行后交给单一 handler。
public final class EventPipeline {
    public typealias Handler = (TaskEvent, _ isStale: Bool) -> Void

    private let queue = DispatchQueue(label: "com.vinlee.eureka.pipeline")
    private let dedup = EventDeduplicator()
    private let handler: Handler
    private var spool: SpoolConsumer?
    private var tailer: CodexRolloutTailer?
    private var claudeWatcher: ClaudeTranscriptWatcher?

    /// 最近一次 Codex 限额快照（M6 面板消费）
    public private(set) var latestCodexRateLimits: RateLimitSnapshot?

    private let claudeProjectsRoot: URL

    public init(
        spoolRoot: URL,
        codexSessionsRoot: URL = CodexRolloutTailer.defaultSessionsRoot(),
        claudeProjectsRoot: URL = ClaudeSessionBootstrap.defaultProjectsRoot(),
        handler: @escaping Handler
    ) {
        self.handler = handler
        self.claudeProjectsRoot = claudeProjectsRoot
        spool = SpoolConsumer(root: spoolRoot) { [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        tailer = CodexRolloutTailer(
            sessionsRoot: codexSessionsRoot,
            rateLimitHandler: { [weak self] snapshot in
                self?.queue.async { self?.latestCodexRateLimits = snapshot }
            },
            handler: { [weak self] event, isStale in
                self?.ingest(event, isStale: isStale)
            }
        )
    }

    public func start() {
        spool?.start()
        tailer?.start()
        // Claude transcript 常驻监视（含启动首扫现场重建）：
        // 装 hooks 前启动的老会话不发任何 hook 事件，这是它们唯一的可见通道
        let watcher = ClaudeTranscriptWatcher(projectsRoot: claudeProjectsRoot) {
            [weak self] event, isStale in
            self?.ingest(event, isStale: isStale)
        }
        watcher.start()
        claudeWatcher = watcher
    }

    public func stop() {
        spool?.stop()
        tailer?.stop()
        claudeWatcher?.stop()
    }

    /// Claude 上下文估算的节流（每会话最多 20s 一次，读文件尾有成本）
    private var lastContextEstimate: [String: Date] = [:]
    /// 会话首启时间缓存（每会话只读一次文件头）
    private var sessionFirstAt: [String: Date] = [:]

    private func ingest(_ event: TaskEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.dedup.isDuplicate(event) else { return }
            for enriched in self.enrich(event) {
                self.handler(enriched, isStale)
            }
        }
    }

    private func enrich(_ event: TaskEvent) -> [TaskEvent] {
        var events = [event]

        // 会话首启时间：所有带 transcript 的 Claude 事件统一补上（头读一次，缓存）
        if event.source == .claude, event.sessionStartedAt == nil,
           let transcriptPath = event.transcriptPath {
            let firstAt: Date?
            if let cached = sessionFirstAt[event.sessionId] {
                firstAt = cached
            } else {
                firstAt = ClaudeSessionFirstTimestamp.read(transcriptPath: transcriptPath)
                if let firstAt { sessionFirstAt[event.sessionId] = firstAt }
                if sessionFirstAt.count > 128 {
                    sessionFirstAt.removeAll()  // 简单防膨胀，重读成本极低
                }
            }
            if let firstAt {
                events[0].sessionStartedAt = firstAt
            }
        }

        // Claude"成功"完成 → 嗅探尾部：API 错误升级为出错；ai-title 升级标题
        if event.source == .claude,
           case .taskFinished(outcome: .success, let title, let detail) = event.kind,
           let transcriptPath = event.transcriptPath {
            let findings = ClaudeErrorSniffer.sniff(transcriptPath: transcriptPath)
            var enriched = event
            let newTitle = findings.aiTitle ?? title
            if findings.isError {
                enriched.kind = .taskFinished(
                    outcome: .error,
                    title: newTitle,
                    detail: findings.errorDetail ?? detail
                )
            } else if newTitle != title {
                enriched.kind = .taskFinished(outcome: .success, title: newTitle, detail: detail)
            }
            events[0] = enriched
        }

        // Claude 心跳（节流 20s）/ 等待确认（立即，用户此刻最需要识别会话）
        // → 读 transcript 尾部：上下文占用 + ai-title 会话名
        if event.source == .claude, let transcriptPath = event.transcriptPath {
            let now = Date()
            var shouldInspect = false
            switch event.kind {
            case .activity:
                if now.timeIntervalSince(lastContextEstimate[event.sessionId] ?? .distantPast) > 20 {
                    lastContextEstimate[event.sessionId] = now
                    shouldInspect = true
                }
            case .waiting:
                shouldInspect = true
            default:
                break
            }
            if shouldInspect {
                if lastContextEstimate.count > 64 {
                    lastContextEstimate = lastContextEstimate.filter {
                        now.timeIntervalSince($0.value) < 3600
                    }
                }
                let info = ClaudeContextEstimator.inspect(transcriptPath: transcriptPath)
                func extra(_ kind: TaskEvent.Kind) -> TaskEvent {
                    TaskEvent(
                        source: .claude, sessionId: event.sessionId,
                        kind: kind, timestamp: now, cwd: event.cwd,
                        transcriptPath: transcriptPath)
                }
                // 标题先于 waiting 事件送达，等待卡一出来就带会话名
                if let aiTitle = info.aiTitle {
                    events.insert(extra(.titleUpdate(title: aiTitle)), at: 0)
                }
                if let percent = info.contextPercent {
                    events.append(extra(.contextUpdate(percent: percent)))
                }
            }
        }
        return events
    }
}
