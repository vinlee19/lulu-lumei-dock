import EurekaKit
import EurekaStore
import Foundation

/// What the audit page's analytics view shows for one filter: operations grouped by a dimension
/// (model, source, project, session) with their mix of kinds, a day-by-day series, the rules that
/// fired, and a few rankings.
public struct AuditAnalytics: Equatable, Sendable {
    public struct Group: Equatable, Sendable, Identifiable {
        public var id: String { key }
        /// Dimension value; "" is the group nothing could be attributed to
        public var key: String
        public var total = 0
        public var byKind: [ToolKind: Int] = [:]
        public var risk = 0
        /// High risk or above
        public var high = 0
        public var errors = 0
        public var riskByCategory: [RiskRule.Category: Int] = [:]

        public var riskRate: Double { total > 0 ? Double(risk) / Double(total) : 0 }
        public var errorRate: Double { total > 0 ? Double(errors) / Double(total) : 0 }
    }

    public struct Day: Equatable, Sendable, Identifiable {
        public var id: String { day }
        public var day: String  // yyyy-MM-dd, local time
        public var date: Date
        public var byKind: [ToolKind: Int] = [:]
        public var risk = 0
        public var total: Int { byKind.values.reduce(0, +) }
    }

    public struct Ranked: Equatable, Sendable, Identifiable {
        public var id: String { label }
        public var label: String
        public var count: Int
    }

    public var dimension: AuditRepo.Dimension
    /// Largest first
    public var groups: [Group]
    public var totals: Group
    public var days: [Day]
    /// Rule ids by hits
    public var rules: [Ranked]
    public var commands: [Ranked]
    public var mcpTools: [Ranked]
    public var domains: [Ranked]
    public var directories: [Ranked]
    /// The command and domain rankings read the newest commands only; this is how many
    public var commandsParsed: Int
}

public enum AuditAnalyticsBuilder {
    /// Commands parsed for the command and domain rankings (newest first). Parsing is the only
    /// part that costs more than a GROUP BY.
    public static let parsedCommandLimit = 30_000
    public static let rankingSize = 8

    /// Words that say nothing about what an agent did
    private static let ignoredCommands: Set<String> = [
        "", "cd", "echo", "printf", "true", "false", "export", "set", "unset", "local", "return",
        "exit", "test", "[", "[[", "]]", "{", "}", "fi", "done", "esac", "for", "case", "function",
        "select", "in", ":", "sleep", "wait",
    ]
    private static let fetchers: Set<String> = ["curl", "wget", "http", "https", "xh"]

    public static func build(
        store: EurekaStore, query: AuditRepo.Query, dimension: AuditRepo.Dimension,
        home: String = NSHomeDirectory(), calendar: Calendar = .current
    ) throws -> AuditAnalytics {
        // Groups
        var groups: [String: AuditAnalytics.Group] = [:]
        var totals = AuditAnalytics.Group(key: "")
        for row in try store.audit.breakdown(by: dimension, query) {
            var group = groups[row.key] ?? AuditAnalytics.Group(key: row.key)
            group.total += row.count
            group.byKind[row.kind, default: 0] += row.count
            group.risk += row.risk
            group.high += row.high
            group.errors += row.errors
            groups[row.key] = group
            totals.total += row.count
            totals.byKind[row.kind, default: 0] += row.count
            totals.risk += row.risk
            totals.high += row.high
            totals.errors += row.errors
        }
        // Rule hits: per group by category, and overall by rule
        let rules = RiskRuleEngine.current
        var ruleCounts: [String: Int] = [:]
        for hit in try store.audit.riskHits(by: dimension, query) where !hit.rule.isEmpty {
            ruleCounts[hit.rule, default: 0] += hit.count
            let category = rules.rule(id: hit.rule)?.category ?? .custom
            groups[hit.key]?.riskByCategory[category, default: 0] += hit.count
            totals.riskByCategory[category, default: 0] += hit.count
        }

        // Days
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var days: [String: AuditAnalytics.Day] = [:]
        for row in try store.audit.dailySeries(query) {
            guard let date = formatter.date(from: row.day) else { continue }
            var day = days[row.day] ?? AuditAnalytics.Day(day: row.day, date: date)
            day.byKind[row.kind, default: 0] += row.count
            day.risk += row.risk
            days[row.day] = day
        }

        // Rankings
        let commandDetails = try store.audit.details(
            kind: .command, query, limit: parsedCommandLimit)
        var (commands, hosts) = rankCommands(commandDetails)
        for detail in try store.audit.details(kind: .web, query, limit: parsedCommandLimit) {
            if let host = host(of: detail) { hosts[host, default: 0] += 1 }
        }
        commands = commands.filter { !ignoredCommands.contains($0.key) }
        var directories: [String: Int] = [:]
        for detail in try store.audit.details(kind: .edit, query, limit: parsedCommandLimit) {
            let first = detail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            for path in first.components(separatedBy: ", ") where !path.isEmpty {
                directories[directory(of: path, home: home), default: 0] += 1
            }
        }
        let mcpTools = try store.audit.topTools(kind: .mcp, query, limit: rankingSize)
            .map { AuditAnalytics.Ranked(label: $0.tool, count: $0.count) }

        return AuditAnalytics(
            dimension: dimension,
            // Largest first; on a tie a named group before the unattributed one
            groups: groups.values.sorted {
                $0.total != $1.total ? $0.total > $1.total
                    : $0.key.isEmpty != $1.key.isEmpty ? !$0.key.isEmpty : $0.key < $1.key
            },
            totals: totals,
            days: days.values.sorted { $0.day < $1.day },
            rules: ranked(ruleCounts, limit: 12),
            commands: ranked(commands, limit: rankingSize),
            mcpTools: mcpTools,
            domains: ranked(hosts, limit: rankingSize),
            directories: ranked(directories, limit: rankingSize),
            commandsParsed: commandDetails.count)
    }

    static func ranked(_ counts: [String: Int], limit: Int) -> [AuditAnalytics.Ranked] {
        counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(limit)
            .map { AuditAnalytics.Ranked(label: $0.key, count: $0.value) }
    }

    /// Command words of every command (substitutions and nested scripts included), and the hosts
    /// the fetchers among them were pointed at
    public static func rankCommands(_ details: [String]) -> (commands: [String: Int], hosts: [String: Int]) {
        var commands: [String: Int] = [:]
        var hosts: [String: Int] = [:]
        for detail in details {
            for pipeline in ShellCommandSplitter.split(detail) {
                for segment in pipeline {
                    commands[segment.command, default: 0] += 1
                    guard fetchers.contains(segment.command) else { continue }
                    for arg in segment.args {
                        if let host = host(of: arg) { hosts[host, default: 0] += 1 }
                    }
                }
            }
        }
        return (commands, hosts)
    }

    /// Host of the first http(s) URL in the text; nil when there is none (a search query)
    public static func host(of text: String) -> String? {
        guard let scheme = text.range(of: "https://") ?? text.range(of: "http://") else {
            return nil
        }
        let rest = text[scheme.upperBound...]
        // Drop credentials (`user:pass@host`) and stop at the port, path or a quote
        var host = rest.prefix { !"/?#\"' \n\\)".contains($0) }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        host = host.prefix { $0 != ":" }
        // A variable is not a host
        guard !host.isEmpty, !host.contains("$"), !host.contains("{"), host.contains(".")
                || host == "localhost"
        else { return nil }
        return host.lowercased()
    }

    /// Parent directory of an edited file, with the home directory shortened to `~`
    public static func directory(of path: String, home: String) -> String {
        var directory = (path as NSString).deletingLastPathComponent
        if directory.isEmpty { directory = "." }
        if directory == home { return "~" }
        if directory.hasPrefix(home + "/") { directory = "~" + directory.dropFirst(home.count) }
        return directory
    }
}
