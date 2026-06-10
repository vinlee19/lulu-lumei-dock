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

    /// 最近一次 Codex 限额快照（M6 面板消费）
    public private(set) var latestCodexRateLimits: RateLimitSnapshot?

    public init(
        spoolRoot: URL,
        codexSessionsRoot: URL = CodexRolloutTailer.defaultSessionsRoot(),
        handler: @escaping Handler
    ) {
        self.handler = handler
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
    }

    public func stop() {
        spool?.stop()
        tailer?.stop()
    }

    /// Claude 上下文估算的节流（每会话最多 20s 一次，读文件尾有成本）
    private var lastContextEstimate: [String: Date] = [:]

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

        // Claude 心跳 → 节流估算上下文占用（Codex 的由 rollout token_count 直接提供）
        if event.source == .claude,
           case .activity = event.kind,
           let transcriptPath = event.transcriptPath {
            let now = Date()
            let last = lastContextEstimate[event.sessionId] ?? .distantPast
            if now.timeIntervalSince(last) > 20 {
                lastContextEstimate[event.sessionId] = now
                if lastContextEstimate.count > 64 {
                    lastContextEstimate = lastContextEstimate.filter {
                        now.timeIntervalSince($0.value) < 3600
                    }
                }
                if let percent = ClaudeContextEstimator.estimate(transcriptPath: transcriptPath) {
                    events.append(TaskEvent(
                        source: .claude,
                        sessionId: event.sessionId,
                        kind: .contextUpdate(percent: percent),
                        timestamp: now,
                        cwd: event.cwd
                    ))
                }
            }
        }
        return events
    }
}
