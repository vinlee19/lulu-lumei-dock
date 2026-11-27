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

    /// A secret being read again a minute later is worth saying again; other rules wait 10 minutes
    static let criticalCooldown: TimeInterval = 60

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
        let hit = RiskRuleEngine.evaluate(
            kind: event.kind, tool: event.tool, detail: event.detail, cwd: event.cwd)
        event.riskLevel = hit?.level
        event.riskRule = hit?.ruleId

        let inserted = try store.audit.insert(event)
        guard inserted, !isStale, let hit, hit.level >= .high,
              throttle.shouldAlert(
                sessionId: event.sessionId, ruleId: hit.ruleId, now: now,
                cooldown: hit.level == .critical ? Self.criticalCooldown : nil)
        else { return IngestResult(inserted: inserted, alert: nil) }

        // The alert leaves the database: it is shown on the island, in a system notification
        // (lock screen included) and in the app log, so credentials are masked first. The stored
        // row keeps the raw text.
        let shown = AuditRedactor.redact(detail: event.detail, tool: event.tool).text
        return IngestResult(inserted: true, alert: RiskAlert(
            opId: event.opId, source: event.source, sessionId: event.sessionId,
            ruleId: hit.ruleId, ruleTitle: hit.title, tool: event.tool,
            detail: shown, timestamp: event.timestamp, level: hit.level))
    }

    /// Backfill the execution result (Codex function_call_output finds its row via call_id=op_id)
    public func markOutcome(
        source: AgentSource, sessionId: String, opId: String, exitCode: Int?, isError: Bool
    ) throws {
        try store.audit.markOutcome(
            source: source, sessionId: sessionId, opId: opId, exitCode: exitCode, isError: isError)
    }
}
