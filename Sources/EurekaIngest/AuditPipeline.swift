import Foundation
import EurekaKit
import EurekaStore

/// 审计单一评估点：风险判定 → 幂等落库 → 高危告警决策。CLI 与 app 共用。
/// 有状态（告警节流），调用方负责线程约束（app 在 AuditService 队列上串行调用）。
public final class AuditPipeline {
    public struct IngestResult: Equatable, Sendable {
        public var inserted: Bool      // 是否真的新插入（幂等去重后）
        public var alert: RiskAlert?   // 需呈现的高危告警（已过节流/陈旧过滤）
    }

    private let store: EurekaStore
    private var throttle: RiskAlertThrottle

    public init(store: EurekaStore, throttle: RiskAlertThrottle = RiskAlertThrottle()) {
        self.store = store
        self.throttle = throttle
    }

    /// 评估风险、落库、决定告警。isStale=true（离线积压/重扫）只入库、永不告警。
    @discardableResult
    public func ingest(_ event: AuditEvent, isStale: Bool, now: Date = Date()) throws -> IngestResult {
        var event = event
        let hit = RiskRuleEngine.evaluate(kind: event.kind, tool: event.tool, detail: event.detail)
        event.riskLevel = hit?.level
        event.riskRule = hit?.ruleId

        let inserted = try store.audit.insert(event)
        guard inserted, !isStale, let hit, hit.level == .high,
              throttle.shouldAlert(sessionId: event.sessionId, ruleId: hit.ruleId, now: now)
        else { return IngestResult(inserted: inserted, alert: nil) }

        return IngestResult(inserted: true, alert: RiskAlert(
            opId: event.opId, source: event.source, sessionId: event.sessionId,
            ruleId: hit.ruleId, ruleTitle: hit.title, tool: event.tool,
            detail: event.detail, timestamp: event.timestamp))
    }

    /// 回填执行结果（Codex function_call_output 用 call_id=op_id 找到对应行）
    public func markOutcome(
        source: AgentSource, sessionId: String, opId: String, exitCode: Int?, isError: Bool
    ) throws {
        try store.audit.markOutcome(
            source: source, sessionId: sessionId, opId: opId, exitCode: exitCode, isError: isError)
    }
}
