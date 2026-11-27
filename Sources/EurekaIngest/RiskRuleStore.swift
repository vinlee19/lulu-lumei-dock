import EurekaKit
import EurekaStore
import Foundation

/// Keeps `audit-rules.json` and the rule set in force in step: reads the file, installs the
/// resulting rules into `RiskRuleEngine`, writes the file when the app changes a rule, and notices
/// a hand edit by the file's modification time.
///
/// A file that cannot be used never turns the rules off: a broken entry is skipped and reported,
/// and a file that is not a config at all leaves the previous rules in force.
public final class RiskRuleStore: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        public var config: RiskRulesConfig
        /// Entries left out, with the reason
        public var problems: [RiskRuleSet.Problem]
        /// Set when the whole file was unusable; `config` is then the last one that worked
        public var fileError: String?

        public init(
            config: RiskRulesConfig = RiskRulesConfig(), problems: [RiskRuleSet.Problem] = [],
            fileError: String? = nil
        ) {
            self.config = config
            self.problems = problems
            self.fileError = fileError
        }
    }

    public static let shared = RiskRuleStore(url: defaultURL())

    /// Next to the database (`~/Library/Application Support/Eureka/audit-rules.json`), so a
    /// database copy opened with `EUREKA_DB_PATH` never picks up or changes the real rules
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_AUDIT_RULES_PATH"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return EurekaStore.defaultURL(environment: environment)
            .deletingLastPathComponent().appendingPathComponent("audit-rules.json")
    }

    public let url: URL
    private let lock = NSLock()
    private var current = State()
    private var stamp: String?

    public init(url: URL) {
        self.url = url
    }

    public var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private static func stamp(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(modified):\(attributes[.size] as? Int ?? 0)"
    }

    /// Reads the file and installs the rules it describes
    @discardableResult
    public func load() -> State {
        let stamp = Self.stamp(of: url)
        var next = state
        if let data = try? Data(contentsOf: url) {
            do {
                let parsed = try RiskRulesConfig.parse(data)
                next = State(config: parsed.config, problems: parsed.problems)
            } catch {
                // Keep what was in force; only say why the file is ignored
                next.fileError = "audit-rules.json is not a JSON object"
            }
        } else {
            // No file: built-in rules as they come
            next = State()
        }
        return install(next, stamp: stamp)
    }

    /// Reloads when the file changed since it was last read; nil when it did not
    public func reloadIfChanged() -> State? {
        lock.lock()
        let known = stamp
        lock.unlock()
        return Self.stamp(of: url) == known ? nil : load()
    }

    /// Writes the config (atomically) and installs it
    @discardableResult
    public func save(_ config: RiskRulesConfig) throws -> State {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try config.encoded().write(to: url, options: .atomic)
        return install(State(config: config), stamp: Self.stamp(of: url))
    }

    private func install(_ next: State, stamp: String?) -> State {
        let rules = RiskRuleSet.make(
            builtin: RiskRuleEngine.builtinRules, config: next.config, problems: next.problems)
        var installed = next
        installed.problems = rules.problems
        RiskRuleEngine.install(rules)
        lock.lock()
        current = installed
        self.stamp = stamp
        lock.unlock()
        return installed
    }

    /// How many stored operations a rule would match on its own (what saving it would flag),
    /// before any allow entry
    public static func historicalHits(
        of rule: RiskRule, store: EurekaStore, home: String = NSHomeDirectory()
    ) throws -> Int {
        var candidate = rule
        candidate.enabled = true
        let rules = RiskRuleSet(rules: [candidate])
        guard rules.problems.isEmpty else { return 0 }
        var cursor: Int64 = 0
        var hits = 0
        while true {
            let rows = try store.audit.classifications(after: cursor, limit: 5_000)
            guard let last = rows.last else { return hits }
            cursor = last.id
            for row in rows where rule.kinds.contains(row.kind) {
                if rules.evaluate(
                    kind: row.kind, tool: row.tool, detail: row.detail, cwd: row.cwd,
                    source: row.source, home: home) != nil {
                    hits += 1
                }
            }
        }
    }
}
