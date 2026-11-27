import Foundation

/// Where a path named by an operation lies, as far as the text alone can tell.
public enum RiskPathZone: String, Codable, Sendable, CaseIterable {
    /// Under a temporary directory (`/tmp`, `/var/folders`, `$TMPDIR`)
    case tmp
    /// Absolute or home-relative, inside the session's working directory
    case cwd
    /// Written as a relative path
    case relative
    /// Under the home directory, outside the working directory
    case home
    /// Anywhere else on the system
    case system
    /// Starts with a variable or substitution that is not expanded here
    case unknown
}

/// Path handling shared by the rules. Purely lexical: nothing is read from disk.
public enum RiskPath {
    private static let tmpRoots = [
        "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp", "/var/folders",
        "/private/var/folders",
    ]

    /// Expands `~`, `$HOME`, `$PWD` and `$TMPDIR`, resolves a relative path against `cwd` when it
    /// is known, and folds `.` / `..`. A path that starts with any other variable comes back as is.
    public static func resolve(_ raw: String, cwd: String?, home: String) -> String {
        var path = raw
        func replacePrefix(_ prefixes: [String], with replacement: String) -> Bool {
            for prefix in prefixes where path == prefix || path.hasPrefix(prefix + "/") {
                path = replacement + path.dropFirst(prefix.count)
                return true
            }
            return false
        }
        if !replacePrefix(["~", "$HOME", "${HOME}"], with: home),
           !replacePrefix(["$TMPDIR", "${TMPDIR}"], with: "/tmp"),
           let cwd, !cwd.isEmpty {
            if !replacePrefix(["$PWD", "${PWD}"], with: cwd),
               !path.hasPrefix("/"), !path.hasPrefix("$"), !path.hasPrefix("`") {
                path = cwd + "/" + path
            }
        }
        guard path.hasPrefix("/") else { return path }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func isInside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    public static func zone(of raw: String, cwd: String?, home: String) -> RiskPathZone {
        if raw.hasPrefix("$TMPDIR") || raw.hasPrefix("${TMPDIR}") { return .tmp }
        let isHomeForm = raw == "~" || raw.hasPrefix("~/")
            || raw.hasPrefix("$HOME") || raw.hasPrefix("${HOME}")
        let isWorkingDirForm = raw.hasPrefix("$PWD") || raw.hasPrefix("${PWD}")
        if !isHomeForm, !isWorkingDirForm, raw.hasPrefix("$") || raw.hasPrefix("`") {
            return .unknown
        }
        let resolved = resolve(raw, cwd: cwd, home: home)
        if tmpRoots.contains(where: { isInside(resolved, $0) }) { return .tmp }
        // A session started in `/` or in the home directory has no project to stay inside of
        let project = cwd.flatMap { $0.isEmpty || $0 == "/" || $0 == home ? nil : $0 }
        if !raw.hasPrefix("/"), !isHomeForm, !isWorkingDirForm {
            // Typed relative: stays relative unless `..` walks out of the project
            guard let project, resolved.hasPrefix("/") else { return .relative }
            if isInside(resolved, project) { return .relative }
        } else if let project, isInside(resolved, project) {
            return .cwd
        }
        return isInside(resolved, home) ? .home : .system
    }
}

/// Which paths a command segment reads and which it writes, from its command word and redirects.
/// Explicit lists on purpose: an unknown command is neither, so `ls ~/.ssh` or
/// `docker run --env-file .env` never count as reading a secret.
enum ShellAccess {
    /// Commands whose output shows the content of their file operands
    private static let readers: Set<String> = [
        "cat", "less", "more", "head", "tail", "bat", "nl", "tac", "strings", "xxd", "hexdump",
        "od", "base64", "openssl", "gpg", "cut", "sort", "uniq", "diff", "cmp", "source", ".",
        "tar", "zip", "gzip",
    ]
    /// Readers whose first operand is a pattern or a program, not a file
    private static let patternFirst: Set<String> = [
        "grep", "egrep", "fgrep", "rg", "ag", "awk", "gawk", "sed", "jq", "yq", "perl",
    ]
    /// Flags of the pattern-first commands that take a value
    private static let valueFlags: Set<String> = [
        "-e", "-f", "-A", "-B", "-C", "-m", "-g", "-t", "-F", "-v", "--include", "--exclude",
        "--exclude-dir", "--glob", "--type", "--regexp", "--file", "--arg", "--argjson",
    ]
    /// Last operand is written, the ones before it are read
    private static let copiers: Set<String> = ["cp", "mv", "scp", "rsync", "ln", "install"]
    /// Every operand is created, changed or removed
    private static let writers: Set<String> = [
        "tee", "touch", "mkdir", "rm", "rmdir", "unlink", "chmod", "chown", "chgrp", "chflags",
        "truncate", "shred",
    ]

    /// Operands of a pattern-first command that name files
    private static func fileOperands(_ segment: ShellCommandSplitter.Segment) -> [String] {
        var files: [String] = []
        var explicitPattern = false
        var skip = false
        for arg in segment.args {
            if skip {
                skip = false
                continue
            }
            if arg.hasPrefix("-"), arg != "-" {
                if ["-e", "-f", "--regexp", "--file"].contains(arg) { explicitPattern = true }
                skip = valueFlags.contains(arg)
                continue
            }
            files.append(arg)
        }
        return explicitPattern ? files : Array(files.dropFirst())
    }

    private static func editsInPlace(_ segment: ShellCommandSplitter.Segment) -> Bool {
        segment.args.contains { $0.hasPrefix("-i") || $0 == "--in-place" || $0.hasPrefix("-pi") }
    }

    /// Files curl uploads: `-T file`, `-d @file`, `-F name=@file`
    private static func uploads(_ segment: ShellCommandSplitter.Segment) -> [String] {
        var files: [String] = []
        var index = 0
        let args = segment.args
        while index < args.count {
            let arg = args[index]
            let value = index + 1 < args.count ? args[index + 1] : nil
            if ["-T", "--upload-file"].contains(arg), let value {
                files.append(value)
                index += 1
            } else if arg.hasPrefix("-d") || arg.hasPrefix("--data") || arg == "-F"
                        || arg == "--form" {
                // The value is attached (-d@file) or the next word
                let payload = arg.contains("@") ? arg : (value ?? "")
                if let at = payload.lastIndex(of: "@") {
                    let file = payload[payload.index(after: at)...].prefix { $0 != ";" }
                    if !file.isEmpty { files.append(String(file)) }
                }
            }
            index += 1
        }
        return files
    }

    static func reads(_ segment: ShellCommandSplitter.Segment) -> [String] {
        var paths = segment.redirects.filter { $0.op == "<" }.map(\.target)
        let command = segment.command
        if readers.contains(command) {
            paths += segment.operands
        } else if patternFirst.contains(command) {
            paths += fileOperands(segment)
        } else if copiers.contains(command) {
            paths += segment.operands.dropLast()
        } else if command == "curl" {
            paths += uploads(segment)
        }
        return paths
    }

    static func writes(_ segment: ShellCommandSplitter.Segment) -> [String] {
        var paths = segment.redirects.filter(\.isWrite).map(\.target)
        let command = segment.command
        if writers.contains(command) {
            paths += segment.operands
        } else if copiers.contains(command) {
            if let last = segment.operands.last { paths.append(last) }
        } else if ["sed", "perl"].contains(command), editsInPlace(segment) {
            paths += fileOperands(segment)
        } else if command == "dd" {
            paths += segment.args.compactMap { $0.hasPrefix("of=") ? String($0.dropFirst(3)) : nil }
        }
        return paths
    }

    static func all(_ segment: ShellCommandSplitter.Segment) -> [String] {
        segment.redirects.filter { $0.op != "<<" }.map(\.target) + segment.operands
    }
}

/// A set of rules compiled for matching. Immutable; swap the whole set to change rules.
public final class RiskRuleSet: @unchecked Sendable {
    /// A rule left out because one of its patterns does not compile
    public struct Problem: Equatable, Sendable {
        public var ruleId: String
        public var message: String
    }

    private struct Compiled {
        let rule: RiskRule
        let pattern: NSRegularExpression?
        let exclude: [NSRegularExpression]
        let commands: [String]
        let pipeInto: Set<String>
        let pipeIntoBare: Set<String>
    }

    public let rules: [RiskRule]
    public let problems: [Problem]
    private let compiled: [Compiled]

    public init(rules: [RiskRule]) {
        self.rules = rules
        var compiled: [(index: Int, entry: Compiled)] = []
        var problems: [Problem] = []
        for (index, rule) in rules.enumerated() where rule.enabled {
            do {
                let pattern = try rule.pattern.map {
                    try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
                }
                let exclude = try rule.exclude.map {
                    try NSRegularExpression(pattern: $0, options: [.caseInsensitive])
                }
                compiled.append((index, Compiled(
                    rule: rule, pattern: pattern, exclude: exclude,
                    commands: rule.commands.map { $0.lowercased() },
                    pipeInto: Set(rule.pipeInto.map { $0.lowercased() }),
                    pipeIntoBare: Set(rule.pipeIntoBare.map { $0.lowercased() }))))
            } catch {
                problems.append(Problem(ruleId: rule.id, message: error.localizedDescription))
            }
        }
        // Highest level first; within a level, the order the rules were given in
        self.compiled = compiled.sorted {
            $0.entry.rule.level != $1.entry.rule.level
                ? $0.entry.rule.level > $1.entry.rule.level : $0.index < $1.index
        }.map(\.entry)
        self.problems = problems
    }

    /// Changes whenever a rule's matching or level changes; titles are left out. Stored next to the
    /// audit log to tell when history has to be evaluated again.
    public var fingerprint: String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ text: String) {
            for byte in text.utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
            hash = (hash ^ 0x1f) &* 0x0000_0100_0000_01b3
        }
        for rule in rules {
            mix(rule.id)
            mix(String(rule.level.rawValue))
            mix(rule.enabled ? "1" : "0")
            mix(rule.kinds.map(\.rawValue).sorted().joined(separator: ","))
            mix(rule.scope.rawValue)
            mix(rule.access.rawValue)
            mix(rule.commands.joined(separator: ","))
            mix(rule.pattern ?? "")
            mix(rule.pipeInto.joined(separator: ","))
            mix(rule.pipeIntoBare.joined(separator: ","))
            mix(rule.targets.map(\.rawValue).sorted().joined(separator: ","))
            mix(rule.exceptTargets.map(\.rawValue).sorted().joined(separator: ","))
            mix(rule.exclude.joined(separator: "\u{1}"))
        }
        return String(hash, radix: 16)
    }

    public func rule(id: String) -> RiskRule? {
        rules.first { $0.id == id }
    }

    // MARK: - Evaluation

    /// The first matching rule by descending level, then rule order; nil when nothing matches.
    public func evaluate(
        kind: ToolKind, tool: String, detail: String, cwd: String? = nil,
        home: String = NSHomeDirectory()
    ) -> RiskHit? {
        guard !detail.isEmpty || !tool.isEmpty else { return nil }
        var context = Context(kind: kind, tool: tool, detail: detail, cwd: cwd, home: home)
        for entry in compiled where entry.rule.kinds.contains(kind) {
            guard matches(entry, &context) else { continue }
            if entry.exclude.contains(where: { Self.found($0, in: detail) }) { continue }
            return RiskHit(ruleId: entry.rule.id, title: entry.rule.title.text, level: entry.rule.level)
        }
        return nil
    }

    /// Per-operation work shared by every rule: the command is split once, on first use
    private struct Context {
        let kind: ToolKind
        let tool: String
        let detail: String
        let cwd: String?
        let home: String
        private var cachedPipelines: [ShellCommandSplitter.Pipeline]?

        init(kind: ToolKind, tool: String, detail: String, cwd: String?, home: String) {
            self.kind = kind
            self.tool = tool
            self.detail = detail
            self.cwd = cwd
            self.home = home
        }

        var pipelines: [ShellCommandSplitter.Pipeline] {
            mutating get {
                if let cachedPipelines { return cachedPipelines }
                let split = kind == .command ? ShellCommandSplitter.split(detail) : []
                cachedPipelines = split
                return split
            }
        }

        /// Paths a file tool names: the whole detail, or the part after ` in ` for a search
        var toolPaths: [String] {
            var text = detail.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            if kind == .search {
                guard let range = text.range(of: " in ", options: .backwards) else { return [] }
                text = String(text[range.upperBound...])
            }
            return text.components(separatedBy: ", ").filter { !$0.isEmpty }
        }
    }

    private static func found(_ regex: NSRegularExpression, in text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }

    private static func commandMatches(
        _ segment: ShellCommandSplitter.Segment, _ commands: [String]
    ) -> Bool {
        guard !commands.isEmpty else { return true }
        return commands.contains { wanted in
            if wanted.hasSuffix("*") {
                return segment.command.hasPrefix(wanted.dropLast())
            }
            return segment.command == wanted || segment.wrappers.contains(wanted)
        }
    }

    private func zonesAllow(_ entry: Compiled, _ paths: [String], _ context: Context) -> Bool {
        let rule = entry.rule
        guard !rule.targets.isEmpty || !rule.exceptTargets.isEmpty else { return true }
        return paths.contains { path in
            let zone = RiskPath.zone(of: path, cwd: context.cwd, home: context.home)
            return (rule.targets.isEmpty || rule.targets.contains(zone))
                && !rule.exceptTargets.contains(zone)
        }
    }

    /// A path matches when it is in an allowed zone and the pattern finds it, as written or
    /// resolved
    private func pathMatches(_ entry: Compiled, _ path: String, _ context: Context) -> Bool {
        guard zonesAllow(entry, [path], context) else { return false }
        guard let pattern = entry.pattern else { return true }
        if Self.found(pattern, in: path) { return true }
        let resolved = RiskPath.resolve(path, cwd: context.cwd, home: context.home)
        return resolved != path && Self.found(pattern, in: resolved)
    }

    private func matches(_ entry: Compiled, _ context: inout Context) -> Bool {
        let rule = entry.rule
        switch rule.scope {
        case .text:
            return entry.pattern.map { Self.found($0, in: context.detail) } ?? false
        case .tool:
            return entry.pattern.map { Self.found($0, in: context.tool) } ?? false
        case .segment:
            let pipelines = context.pipelines
            let snapshot = context
            return pipelines.contains { pipeline in
                pipeline.contains { segment in
                    Self.commandMatches(segment, entry.commands)
                        && (entry.pattern.map { Self.found($0, in: segment.text) } ?? true)
                        && zonesAllow(entry, segment.operands, snapshot)
                }
            }
        case .pipeline:
            let pipelines = context.pipelines
            return pipelines.contains { pipelineMatches(entry, $0) }
        case .path:
            let pipelines = context.pipelines
            let snapshot = context
            if context.kind == .command {
                return pipelines.contains { pipeline in
                    pipeline.contains { segment in
                        guard Self.commandMatches(segment, entry.commands) else { return false }
                        let paths: [String]
                        switch rule.access {
                        case .read: paths = ShellAccess.reads(segment)
                        case .write: paths = ShellAccess.writes(segment)
                        case .any: paths = ShellAccess.all(segment)
                        }
                        return paths.contains { pathMatches(entry, $0, snapshot) }
                    }
                }
            }
            // A file tool reads (read / search) or writes (edit) the path it names
            let toolAccess: RiskRule.Access = context.kind == .edit ? .write : .read
            guard rule.access == .any || rule.access == toolAccess else { return false }
            return context.toolPaths.contains { pathMatches(entry, $0, snapshot) }
        }
    }

    /// The output of one of `commands` reaches a command that runs it: through a pipe, or as a
    /// substitution handed to a shell / interpreter / `eval`
    private func pipelineMatches(
        _ entry: Compiled, _ pipeline: ShellCommandSplitter.Pipeline
    ) -> Bool {
        func isSource(_ segment: ShellCommandSplitter.Segment) -> Bool {
            !entry.commands.isEmpty && Self.commandMatches(segment, entry.commands)
                && (entry.pattern.map { Self.found($0, in: segment.text) } ?? true)
        }
        for (index, segment) in pipeline.enumerated() {
            if isSource(segment) {
                let runsIt = pipeline[(index + 1)...].contains { sink in
                    entry.pipeInto.contains(sink.command)
                        // An interpreter runs its stdin only when given no script, and only
                        // when stdin is still the pipe (`python3 - <<PY` runs the heredoc)
                        || (entry.pipeIntoBare.contains(sink.command)
                            && sink.args.allSatisfy { $0 == "-" }
                            && sink.redirects.allSatisfy(\.isWrite))
                }
                if runsIt { return true }
            }
            let executes = entry.pipeInto.contains(segment.command)
                || entry.pipeIntoBare.contains(segment.command)
                || ["eval", "source", "."].contains(segment.command)
            if executes, segment.feeds.contains(where: { $0.contains(where: isSource) }) {
                return true
            }
        }
        return false
    }
}
