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

    private func ingest(_ event: TaskEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.dedup.isDuplicate(event) else { return }
            self.handler(self.enrich(event), isStale)
        }
    }

    /// Claude 任务"成功"完成时嗅探 transcript 尾部：
    /// API 错误 → 升级为出错；ai-title → 升级标题
    private func enrich(_ event: TaskEvent) -> TaskEvent {
        guard
            event.source == .claude,
            case .taskFinished(outcome: .success, let title, let detail) = event.kind,
            let transcriptPath = event.transcriptPath
        else { return event }

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
        return enriched
    }
}
