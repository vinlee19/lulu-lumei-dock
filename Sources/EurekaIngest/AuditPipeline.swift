import Foundation
import EurekaKit
import EurekaStore

/// Single audit evaluation point: risk assessment → idempotent insert → high-risk alert decision.
/// Shared by the CLI and the app. Stateful (alert throttling); callers own thread confinement (the
/// app calls it serially on the AuditService queue).
public final class AuditPipeline {
    public struct IngestResult: Equatable, Sendable {
        public var inserted: Bool      // whether a row was really inserted (after idempotent dedup)
        public var alert: RiskAlert?   // high-risk alert to show (already throttled / stale-filtered)
    }

    private let store: EurekaStore
    private var throttle: RiskAlertThrottle

    public init(store: EurekaStore, throttle: RiskAlertThrottle = RiskAlertThrottle()) {
        self.store = store
        self.throttle = throttle
    }

    /// Assess risk, persist, decide on alerting. isStale=true (offline backlog / rescan) only
    /// persists and never alerts.
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

    /// Backfill the execution result (Codex function_call_output finds its row via call_id=op_id)
    public func markOutcome(
        source: AgentSource, sessionId: String, opId: String, exitCode: Int?, isError: Bool
    ) throws {
        try store.audit.markOutcome(
            source: source, sessionId: sessionId, opId: opId, exitCode: exitCode, isError: isError)
    }
}
