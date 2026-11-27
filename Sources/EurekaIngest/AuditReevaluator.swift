import EurekaKit
import EurekaStore
import Foundation

/// Evaluates the stored audit log again with the rules in force.
///
/// Risk is decided when a row is written, so a rule change (a fixed false positive, a new rule, a
/// user's own rule) would otherwise only apply from then on. This walks the table in id order and
/// rewrites the rows whose kind or risk comes out different. It never raises alerts and never
/// inserts or deletes; see `AuditRepo.reclassify` for why that matters to the archive.
public enum AuditReevaluator {
    /// Where the fingerprint of the last completed pass is kept
    public static let fingerprintKey = "risk_rules_fingerprint"
    public static let batchSize = 5_000

    public struct Report: Equatable, Sendable {
        public var scanned = 0
        public var changed = 0
        /// Hits per rule id before and after the pass
        public var before: [String: Int] = [:]
        public var after: [String: Int] = [:]
        public var reclassified: [String: Int] = [:]  // "other→command": n
    }

    /// True when the stored log was last evaluated with different rules
    public static func isDue(store: EurekaStore) -> Bool {
        (try? store.audit.meta(fingerprintKey)) != RiskRuleEngine.fingerprint
    }

    /// One full pass. `dryRun` computes the report without writing anything. `shouldContinue` is
    /// asked between batches; returning false stops early (the fingerprint is then not recorded,
    /// so the next launch starts over). `onChange` sees each row before and after.
    @discardableResult
    public static func run(
        store: EurekaStore, dryRun: Bool = false, home: String = NSHomeDirectory(),
        shouldContinue: () -> Bool = { true },
        onChange: ((AuditRepo.Classification, AuditRepo.Classification) -> Void)? = nil
    ) throws -> Report {
        // Captured first: a rule change during the pass must trigger another one
        let fingerprint = RiskRuleEngine.fingerprint
        let rules = RiskRuleEngine.current
        var report = Report()
        var cursor: Int64 = 0
        while shouldContinue() {
            let rows = try store.audit.classifications(after: cursor, limit: batchSize)
            guard let last = rows.last else {
                if !dryRun { try store.audit.setMeta(fingerprintKey, fingerprint) }
                return report
            }
            cursor = last.id
            var updates: [AuditRepo.Classification] = []
            for row in rows {
                report.scanned += 1
                if let rule = row.riskRule, row.riskLevel != nil {
                    report.before[rule, default: 0] += 1
                }
                var updated = row
                // Only "other" is ever promoted: a kind a scanner chose stands
                if row.kind == .other, let kind = AuditExtractor.kind(forStoredTool: row.tool) {
                    updated.kind = kind
                    report.reclassified["other→\(kind.rawValue)", default: 0] += 1
                }
                let hit = rules.evaluate(
                    kind: updated.kind, tool: updated.tool, detail: updated.detail,
                    cwd: updated.cwd, home: home)
                updated.riskLevel = hit?.level
                updated.riskRule = hit?.ruleId
                if let hit { report.after[hit.ruleId, default: 0] += 1 }
                if updated != row {
                    report.changed += 1
                    updates.append(updated)
                    onChange?(row, updated)
                }
            }
            if !dryRun { try store.audit.reclassify(updates) }
        }
        return report
    }
}
