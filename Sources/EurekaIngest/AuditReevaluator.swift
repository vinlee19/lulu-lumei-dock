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

    /// A pass in flight: where it is, what it found so far, and the rules it started with
    public struct Progress {
        public internal(set) var report = Report()
        var cursor: Int64 = 0
        let fingerprint: String
        let rules: RiskRuleSet
    }

    /// Starts a pass with the rules in force right now. A rule change while it runs is picked up
    /// afterwards: the fingerprint recorded at the end is this one, so `isDue` stays true.
    public static func begin() -> Progress {
        Progress(fingerprint: RiskRuleEngine.fingerprint, rules: RiskRuleEngine.current)
    }

    /// Evaluates the next batch. Returns false once the table is exhausted (and, unless `dryRun`,
    /// the fingerprint is recorded). The app calls this one batch at a time so live audit events
    /// are not held up behind a whole pass.
    public static func step(
        _ progress: inout Progress, store: EurekaStore, dryRun: Bool = false,
        home: String = NSHomeDirectory(),
        onChange: ((AuditRepo.Classification, AuditRepo.Classification) -> Void)? = nil
    ) throws -> Bool {
        let rows = try store.audit.classifications(after: progress.cursor, limit: batchSize)
        guard let last = rows.last else {
            if !dryRun { try store.audit.setMeta(fingerprintKey, progress.fingerprint) }
            return false
        }
        progress.cursor = last.id
        var updates: [AuditRepo.Classification] = []
        for row in rows {
            progress.report.scanned += 1
            if let rule = row.riskRule, row.riskLevel != nil {
                progress.report.before[rule, default: 0] += 1
            }
            var updated = row
            // Only "other" is ever promoted: a kind a scanner chose stands
            if row.kind == .other, let kind = AuditExtractor.kind(forStoredTool: row.tool) {
                updated.kind = kind
                progress.report.reclassified["other→\(kind.rawValue)", default: 0] += 1
            }
            let hit = progress.rules.evaluate(
                kind: updated.kind, tool: updated.tool, detail: updated.detail,
                cwd: updated.cwd, source: updated.source, home: home)
            updated.riskLevel = hit?.level
            updated.riskRule = hit?.ruleId
            if let hit { progress.report.after[hit.ruleId, default: 0] += 1 }
            if updated != row {
                progress.report.changed += 1
                updates.append(updated)
                onChange?(row, updated)
            }
        }
        if !dryRun { try store.audit.reclassify(updates) }
        return true
    }

    /// One full pass in one go (CLI, tests). `dryRun` computes the report without writing
    /// anything. `onChange` sees each changed row before and after.
    @discardableResult
    public static func run(
        store: EurekaStore, dryRun: Bool = false, home: String = NSHomeDirectory(),
        onChange: ((AuditRepo.Classification, AuditRepo.Classification) -> Void)? = nil
    ) throws -> Report {
        var progress = begin()
        while try step(&progress, store: store, dryRun: dryRun, home: home, onChange: onChange) {}
        return progress.report
    }
}
