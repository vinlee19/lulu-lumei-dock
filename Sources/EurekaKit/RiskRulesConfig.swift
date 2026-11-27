import Foundation

/// The user's changes to the audit rules, as stored in `audit-rules.json`:
///
/// ```json
/// {
///   "version": 1,
///   "overrides": { "sudo": { "enabled": false }, "git-push-main": { "level": "high" } },
///   "rules": [
///     { "id": "prod-db", "title": "Connect to the production database", "level": "critical",
///       "kinds": ["command"], "scope": "segment", "commands": ["psql", "mysql"],
///       "pattern": "prod", "exclude": ["--dry-run"] }
///   ],
///   "allow": [
///     { "rule": "rm-rf", "cwd": "/Users/me/scratch" },
///     { "rule": "*", "pattern": "^make clean\\b" }
///   ]
/// }
/// ```
///
/// `overrides` switch a built-in rule off or change its level. `rules` are the user's own, with
/// exactly the fields of a built-in rule. `allow` entries silence a rule (`*` = any) where every
/// condition they state holds: a working directory (and everything under it), a source, a regex
/// over the operation.
public struct RiskRulesConfig: Equatable, Sendable {
    public struct Override: Equatable, Sendable {
        public var enabled: Bool?
        public var level: RiskLevel?

        public init(enabled: Bool? = nil, level: RiskLevel? = nil) {
            self.enabled = enabled
            self.level = level
        }

        var isEmpty: Bool { enabled == nil && level == nil }
    }

    public struct Allow: Equatable, Sendable, Identifiable {
        public var id = UUID()
        /// Rule id, or `*` for every rule
        public var rule: String
        public var cwd: String?
        public var source: String?
        public var pattern: String?

        public init(rule: String, cwd: String? = nil, source: String? = nil, pattern: String? = nil) {
            self.rule = rule
            self.cwd = cwd
            self.source = source
            self.pattern = pattern
        }

        public static func == (lhs: Allow, rhs: Allow) -> Bool {
            lhs.rule == rhs.rule && lhs.cwd == rhs.cwd && lhs.source == rhs.source
                && lhs.pattern == rhs.pattern
        }
    }

    public var overrides: [String: Override]
    public var rules: [RiskRule]
    public var allow: [Allow]

    /// Whether a directory is narrow enough to allow a rule in from the app: a directory below
    /// the home directory, or one outside it that is not an ancestor of it. `/`, the home
    /// directory and its parents would cover every session, which is what switching the rule off
    /// is for. (A hand-written entry is taken as written.)
    public static func isProjectDirectory(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let directory = RiskPath.resolve(path, cwd: nil, home: home)
        guard directory.hasPrefix("/"), directory != "/" else { return false }
        return directory != home && !home.hasPrefix(directory.hasSuffix("/") ? directory : directory + "/")
    }

    public init(overrides: [String: Override] = [:], rules: [RiskRule] = [], allow: [Allow] = []) {
        self.overrides = overrides
        self.rules = rules
        self.allow = allow
    }

    public var isEmpty: Bool { overrides.isEmpty && rules.isEmpty && allow.isEmpty }

    public enum ParseError: Error, Equatable {
        /// The file is not a JSON object; nothing in it can be used
        case notAnObject
    }

    // MARK: - Reading

    /// Reads a config. An entry that cannot be understood is left out and reported; only a file
    /// that is not a JSON object at all throws (the caller then keeps the rules it had).
    public static func parse(_ data: Data) throws -> (config: RiskRulesConfig, problems: [RiskRuleSet.Problem]) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ParseError.notAnObject
        }
        var config = RiskRulesConfig()
        var problems: [RiskRuleSet.Problem] = []
        func problem(_ id: String, _ message: String) {
            problems.append(RiskRuleSet.Problem(ruleId: id, message: message))
        }

        for (id, value) in root["overrides"] as? [String: Any] ?? [:] {
            guard let fields = value as? [String: Any] else {
                problem(id, "override is not an object")
                continue
            }
            var entry = Override(enabled: fields["enabled"] as? Bool)
            if let name = fields["level"] as? String {
                if let level = RiskLevel(name: name) {
                    entry.level = level
                } else {
                    problem(id, "unknown level \"\(name)\"")
                }
            }
            if !entry.isEmpty { config.overrides[id] = entry }
        }

        for (index, value) in (root["rules"] as? [Any] ?? []).enumerated() {
            guard let fields = value as? [String: Any] else {
                problem("rules[\(index)]", "rule is not an object")
                continue
            }
            do {
                config.rules.append(try rule(from: fields))
            } catch let error as RuleError {
                problem(fields["id"] as? String ?? "rules[\(index)]", error.message)
            } catch {
                problem(fields["id"] as? String ?? "rules[\(index)]", "\(error)")
            }
        }

        for (index, value) in (root["allow"] as? [Any] ?? []).enumerated() {
            guard let fields = value as? [String: Any],
                  let rule = fields["rule"] as? String, !rule.isEmpty
            else {
                problem("allow[\(index)]", "entry needs a \"rule\" (a rule id or \"*\")")
                continue
            }
            let entry = Allow(
                rule: rule, cwd: nonEmpty(fields["cwd"]), source: nonEmpty(fields["source"]),
                pattern: nonEmpty(fields["pattern"]))
            // An entry with no condition would silence the rule everywhere; that is what
            // `overrides.enabled = false` is for, and `*` with no condition would silence all rules
            if rule == "*", entry.cwd == nil, entry.source == nil, entry.pattern == nil {
                problem("allow[\(index)]", "\"*\" needs at least one of cwd, source, pattern")
                continue
            }
            config.allow.append(entry)
        }
        return (config, problems)
    }

    private struct RuleError: Error {
        let message: String
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        (value as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func strings(_ value: Any?) -> [String] {
        (value as? [Any])?.compactMap { $0 as? String }.filter { !$0.isEmpty } ?? []
    }

    private static func rule(from fields: [String: Any]) throws -> RiskRule {
        guard let id = nonEmpty(fields["id"]) else { throw RuleError(message: "rule needs an \"id\"") }
        guard let levelName = fields["level"] as? String, let level = RiskLevel(name: levelName) else {
            throw RuleError(message: "\"level\" must be notice, high or critical")
        }
        var kinds: Set<ToolKind> = []
        for name in strings(fields["kinds"]) {
            guard let kind = ToolKind(rawValue: name) else {
                throw RuleError(message: "unknown kind \"\(name)\"")
            }
            kinds.insert(kind)
        }
        let commands = strings(fields["commands"])
        let scope: RiskRule.Scope
        if let name = fields["scope"] as? String {
            guard let parsed = RiskRule.Scope(rawValue: name) else {
                throw RuleError(message: "unknown scope \"\(name)\"")
            }
            scope = parsed
        } else {
            scope = commands.isEmpty ? .text : .segment
        }
        if kinds.isEmpty {
            // What the scope can look at when nothing is said
            switch scope {
            case .tool: kinds = [.mcp]
            case .path: kinds = [.read, .search, .edit, .command]
            case .text, .segment, .pipeline: kinds = [.command]
            }
        }
        let pattern = nonEmpty(fields["pattern"])
        // A rule that names nothing would match every operation of its kinds
        if pattern == nil, commands.isEmpty {
            throw RuleError(message: "rule needs a \"pattern\" or \"commands\"")
        }
        var access = RiskRule.Access.any
        if let name = fields["access"] as? String {
            guard let parsed = RiskRule.Access(rawValue: name) else {
                throw RuleError(message: "unknown access \"\(name)\"")
            }
            access = parsed
        }
        func zones(_ key: String) throws -> Set<RiskPathZone> {
            try Set(strings(fields[key]).map { name in
                guard let zone = RiskPathZone(rawValue: name) else {
                    throw RuleError(message: "unknown zone \"\(name)\" in \(key)")
                }
                return zone
            })
        }
        return RiskRule(
            id: id,
            title: RiskRuleTitle(nonEmpty(fields["title"]) ?? id),
            level: level, category: .custom, kinds: kinds, scope: scope, commands: commands,
            pattern: pattern, pipeInto: strings(fields["pipeInto"]),
            pipeIntoBare: strings(fields["pipeIntoBare"]), access: access,
            targets: try zones("targets"), exceptTargets: try zones("exceptTargets"),
            exclude: strings(fields["exclude"]), topLevel: fields["topLevel"] as? Bool ?? false,
            notPipedInto: strings(fields["notPipedInto"]),
            enabled: fields["enabled"] as? Bool ?? true)
    }

    // MARK: - Writing

    /// The config as JSON, keys sorted so a re-save does not reshuffle a hand-edited file
    public func encoded() throws -> Data {
        var root: [String: Any] = ["version": 1]
        var overrideFields: [String: Any] = [:]
        for (id, entry) in overrides where !entry.isEmpty {
            var fields: [String: Any] = [:]
            if let enabled = entry.enabled { fields["enabled"] = enabled }
            if let level = entry.level { fields["level"] = level.name }
            overrideFields[id] = fields
        }
        root["overrides"] = overrideFields
        root["rules"] = rules.map { rule -> [String: Any] in
            var fields: [String: Any] = [
                "id": rule.id, "title": rule.title.english, "level": rule.level.name,
                "kinds": rule.kinds.map(\.rawValue).sorted(), "scope": rule.scope.rawValue,
            ]
            if !rule.commands.isEmpty { fields["commands"] = rule.commands }
            if let pattern = rule.pattern { fields["pattern"] = pattern }
            if !rule.pipeInto.isEmpty { fields["pipeInto"] = rule.pipeInto }
            if !rule.pipeIntoBare.isEmpty { fields["pipeIntoBare"] = rule.pipeIntoBare }
            if rule.access != .any { fields["access"] = rule.access.rawValue }
            if !rule.targets.isEmpty { fields["targets"] = rule.targets.map(\.rawValue).sorted() }
            if !rule.exceptTargets.isEmpty {
                fields["exceptTargets"] = rule.exceptTargets.map(\.rawValue).sorted()
            }
            if !rule.exclude.isEmpty { fields["exclude"] = rule.exclude }
            if rule.topLevel { fields["topLevel"] = true }
            if !rule.notPipedInto.isEmpty { fields["notPipedInto"] = rule.notPipedInto }
            if !rule.enabled { fields["enabled"] = false }
            return fields
        }
        root["allow"] = allow.map { entry -> [String: Any] in
            var fields: [String: Any] = ["rule": entry.rule]
            if let cwd = entry.cwd { fields["cwd"] = cwd }
            if let source = entry.source { fields["source"] = source }
            if let pattern = entry.pattern { fields["pattern"] = pattern }
            return fields
        }
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }
}

extension RiskLevel {
    /// Name used in the rules file
    public var name: String {
        switch self {
        case .notice: return "notice"
        case .high: return "high"
        case .critical: return "critical"
        }
    }

    public init?(name: String) {
        guard let level = RiskLevel.allCases.first(where: { $0.name == name.lowercased() }) else {
            return nil
        }
        self = level
    }
}
