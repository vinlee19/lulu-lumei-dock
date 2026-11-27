import Foundation

/// Splits shell command text into pipelines of simple commands, so risk rules can look at the
/// command word, its arguments and its redirects instead of running a regex over the whole text.
///
/// It is a tokenizer, not a shell: it tracks quotes, escapes, `$( )` / backticks / `<( )`, the
/// control operators and redirects, and keeps heredoc bodies out of the command (they are the
/// stdin of the command that opened them). Variables are never expanded and
/// control flow is not understood (`for` / `case` stay ordinary words). That is enough to tell
/// `curl … | sh` from `curl … | python3 -c '…'`, or `cat /etc/hosts` from `tee /etc/hosts`.
public enum ShellCommandSplitter {
    public struct Redirect: Equatable, Sendable {
        /// `>` `>>` `>|` `&>` `&>>` `<` `<<<`, and `<<` with the heredoc delimiter as target
        /// (fd-duplication forms like `2>&1` are dropped)
        public var op: String
        public var target: String

        public var isWrite: Bool { op.contains(">") }
    }

    public struct Segment: Sendable {
        /// Lowercased basename of the command word, after leading `VAR=value` assignments, shell
        /// keywords and wrappers are stripped; empty when the segment is only redirects
        public var command: String
        /// Wrappers stripped in front of the command (`sudo`, `env`, `xargs`, …), lowercased
        public var wrappers: [String]
        /// Words after the command word, quotes removed
        public var args: [String]
        public var redirects: [Redirect]
        /// Source text of the segment
        public var text: String
        /// Pipelines inside this segment's `$( )`, backticks and `<( )`
        public var feeds: [[Segment]]
        /// What the command reads on stdin when it is given in the text: a heredoc body or a
        /// here-string. A rule that names this command also matches against it (the SQL of
        /// `psql <<SQL`), and when the command is a shell it is parsed as a script.
        public var stdin: String?
        /// `NAME=value` words in front of the command (or standing alone), in order
        public var assignments: [(name: String, value: String)] = []
        /// Inside `$( )`, backticks or `<( )`: the output goes to another command, not the screen
        public var inSubstitution = false
        /// Parser bookkeeping: which pending heredoc belongs to this segment (0 = none)
        fileprivate var heredocOwner = 0

        /// Arguments that are not flags
        public var operands: [String] { args.filter { !$0.hasPrefix("-") } }
    }

    public typealias Pipeline = [Segment]

    /// Nesting followed into `$( )`, `bash -c '…'` and scripts fed to a shell on stdin
    static let maxDepth = 3

    /// Every pipeline of the command, in source order. A pipeline found inside a substitution,
    /// inside `bash -c '…'` / `eval '…'` or in a script fed to a shell follows the pipeline that
    /// contains it.
    ///
    /// The whole text is parsed, whatever its length: the work is linear, and cutting it would
    /// let a command hide behind padding.
    public static func split(_ source: String) -> [Pipeline] {
        var parser = Parser(bytes: Array(source.utf8), depth: 0)
        return parser.run()
    }

    // MARK: - Command word

    private static let keywords: Set<String> = [
        "if", "then", "else", "elif", "do", "while", "until", "!", "{", "time",
    ]
    /// Wrapper → flags that take a value (skipped together with the value)
    private static let wrappers: [String: Set<String>] = [
        "sudo": ["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-T", "-U"],
        "doas": ["-u", "-C"],
        "env": ["-u", "-S", "-C"],
        "nohup": [], "command": [], "exec": ["-a"], "builtin": [], "stdbuf": [],
        "nice": ["-n"],
        "timeout": ["-s", "-k"],
        "caffeinate": ["-t", "-w"],
        "arch": [],
        "xargs": ["-n", "-I", "-P", "-L", "-d", "-J", "-E", "-s", "-R", "-S"],
    ]
    private static let shells: Set<String> = ["bash", "sh", "zsh", "dash", "ksh", "fish"]

    /// Commands that run their stdin as a shell script
    fileprivate static func runsStdin(_ segment: Segment) -> Bool {
        guard shells.contains(segment.command) else { return false }
        // `bash script.sh <<EOF` feeds the script its input; `bash -s` / bare `bash` runs stdin.
        // The argument of -c is a script, not a script file.
        var operands = segment.operands
        if let flag = segment.args.firstIndex(where: {
            $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")
        }), flag + 1 < segment.args.count,
           let script = operands.firstIndex(of: segment.args[flag + 1]) {
            operands.remove(at: script)
        }
        return operands.isEmpty || segment.args.contains { $0 == "-s" || $0.hasPrefix("-s") }
    }

    private static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
            && !(word.first?.isNumber ?? true)
    }

    private static func basename(_ word: String) -> String {
        (word.split(separator: "/").last.map(String.init) ?? word).lowercased()
    }

    /// Builds one segment from its words; returns the script text to parse further when the
    /// command is `bash -c '…'` or `eval '…'`.
    fileprivate static func makeSegment(
        words: [String], redirects: [Redirect], feeds: [Pipeline], text: String
    ) -> (segment: Segment, scripts: [String]) {
        var index = 0
        var found: [String] = []
        var command = ""
        var assignments: [(name: String, value: String)] = []
        while index < words.count {
            let word = words[index]
            if isAssignment(word), let equals = word.firstIndex(of: "=") {
                assignments.append(
                    (String(word[..<equals]), String(word[word.index(after: equals)...])))
                index += 1
                continue
            }
            if keywords.contains(word) {
                index += 1
                continue
            }
            let name = basename(word)
            guard let valueFlags = wrappers[name] else {
                command = name
                index += 1
                break
            }
            found.append(name)
            index += 1
            // The wrapper's own flags, then (for env) its assignments
            while index < words.count {
                let next = words[index]
                if next.hasPrefix("-"), next != "-", next != "--" {
                    index += valueFlags.contains(next) ? 2 : 1
                } else if name == "env", isAssignment(next) {
                    index += 1
                } else if name == "timeout", next.first?.isNumber == true {
                    index += 1  // the duration
                    break
                } else {
                    break
                }
            }
        }
        // A wrapper with nothing after it (`… | xargs`) is the command itself
        if command.isEmpty, let last = found.popLast() { command = last }
        let args = index < words.count ? Array(words[index...]) : []
        var segment = Segment(
            command: command, wrappers: found, args: args, redirects: redirects,
            text: text, feeds: feeds)
        segment.assignments = assignments
        // A here-string is the command's stdin, known right here (a heredoc body comes later)
        segment.stdin = redirects.last { $0.op == "<<<" }?.target

        // Every script the text hands this command is parsed: a `-c` argument and stdin can both
        // be present (`bash -s -c '…' <<< '…'`), and picking one would hide the other
        var scripts: [String] = []
        if shells.contains(command) {
            // -c, or a flag cluster ending in c (-lc, -ic)
            if let flag = args.firstIndex(where: {
                $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")
            }), flag + 1 < args.count {
                scripts.append(args[flag + 1])
            }
            if let stdin = segment.stdin, runsStdin(segment) { scripts.append(stdin) }
        } else if command == "eval" {
            scripts.append(args.joined(separator: " "))
        }
        return (segment, scripts)
    }

    // MARK: - Parser

    private struct Parser {
        let bytes: [UInt8]
        let depth: Int

        private var index = 0
        private var result: [Pipeline] = []
        private var pipeline: Pipeline = []
        /// Pipelines nested in the open pipeline; emitted right after it
        private var nested: [Pipeline] = []
        /// A `|` was seen and its right-hand command has not started yet
        private var pendingPipe = false

        private var segmentStart = 0
        private var words: [String] = []
        private var redirects: [Redirect] = []
        private var feeds: [Pipeline] = []
        private var word: [UInt8] = []
        private var hasWord = false
        /// Redirect operator waiting for its target word
        private var pendingRedirect: String?
        /// Heredocs opened on the current line: delimiter + the marker of the segment that owns it
        private var heredocs: [(delimiter: String, owner: Int)] = []
        /// Markers of the heredocs opened by the segment being read
        private var openedHere: [Int] = []
        private var nextOwner = 1
        /// Bodies read so far, by owner marker
        private var bodies: [(owner: Int, text: String)] = []

        init(bytes: [UInt8], depth: Int) {
            self.bytes = bytes
            self.depth = depth
        }

        private func byte(_ offset: Int) -> UInt8? {
            let position = index + offset
            return position < bytes.count ? bytes[position] : nil
        }

        mutating func run() -> [Pipeline] {
            while index < bytes.count {
                step()
            }
            boundary(isPipe: false, length: 0)
            closePipeline()
            attachHeredocBodies()
            return result
        }

        /// Heredoc bodies are read after the line that opened them, when their segment is already
        /// built: hand each body to its segment, and parse it when that segment is a shell.
        private mutating func attachHeredocBodies() {
            for body in bodies {
                guard let at = result.firstIndex(where: { pipeline in
                    pipeline.contains { $0.heredocOwner == body.owner }
                }), let position = result[at].firstIndex(where: { $0.heredocOwner == body.owner })
                else { continue }
                result[at][position].stdin = body.text
                let owner = result[at][position]
                // Run by the command itself (`bash <<EOF`), or passed on to a shell further down
                // the pipe (`cat <<EOF | sh`)
                let passedOn = ["cat", "tee"].contains(owner.command)
                    && result[at][(position + 1)...].contains(where: ShellCommandSplitter.runsStdin)
                guard ShellCommandSplitter.runsStdin(owner) || passedOn,
                      depth < ShellCommandSplitter.maxDepth
                else { continue }
                var parser = Parser(bytes: Array(body.text.utf8), depth: depth + 1)
                result.insert(contentsOf: parser.run(), at: at + 1)
            }
            bodies = []
            // Markers mean nothing outside this parser (a parent numbers its own heredocs from 1)
            for at in result.indices {
                for position in result[at].indices { result[at][position].heredocOwner = 0 }
            }
        }

        private mutating func step() {
            let current = bytes[index]
            let next = byte(1)
            switch current {
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                endWord()
                index += 1
            case UInt8(ascii: "\\"):
                if let next, next != UInt8(ascii: "\n") {
                    word.append(next)
                    hasWord = true
                }
                index += 2
            case UInt8(ascii: "'"):
                hasWord = true
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "'") {
                    word.append(bytes[index])
                    index += 1
                }
                index += 1
            case UInt8(ascii: "\""):
                doubleQuoted()
            case UInt8(ascii: "$") where next == UInt8(ascii: "("):
                hasWord = true
                substitution(openParen: index + 1, from: index)
            case UInt8(ascii: "`"):
                hasWord = true
                backticks()
            case UInt8(ascii: "<") where next == UInt8(ascii: "("),
                 UInt8(ascii: ">") where next == UInt8(ascii: "("):
                hasWord = true
                substitution(openParen: index + 1, from: index)
            case UInt8(ascii: "#") where !hasWord && startsWord():
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            case UInt8(ascii: "\n"):
                boundary(isPipe: false, length: 1)
                skipHeredocBodies()
            case UInt8(ascii: ";"), UInt8(ascii: "("), UInt8(ascii: ")"):
                boundary(isPipe: false, length: 1)
            case UInt8(ascii: "&"):
                if next == UInt8(ascii: "&") {
                    boundary(isPipe: false, length: 2)
                } else if next == UInt8(ascii: ">") {
                    endWord()
                    index += 2
                    var op = "&>"
                    if byte(0) == UInt8(ascii: ">") {
                        op = "&>>"
                        index += 1
                    }
                    pendingRedirect = op
                } else {
                    boundary(isPipe: false, length: 1)
                }
            case UInt8(ascii: "|"):
                if next == UInt8(ascii: "|") {
                    boundary(isPipe: false, length: 2)
                } else {
                    boundary(isPipe: true, length: next == UInt8(ascii: "&") ? 2 : 1)
                }
            case UInt8(ascii: ">"):
                dropFileDescriptor()
                endWord()
                index += 1
                var op = ">"
                if let follow = byte(0),
                   [UInt8(ascii: ">"), UInt8(ascii: "|"), UInt8(ascii: "&")].contains(follow) {
                    op.append(Character(UnicodeScalar(follow)))
                    index += 1
                }
                pendingRedirect = op
            case UInt8(ascii: "<"):
                dropFileDescriptor()
                endWord()
                index += 1
                var op = "<"
                if byte(0) == UInt8(ascii: "<") {
                    if byte(1) == UInt8(ascii: "<") {
                        op = "<<<"
                        index += 2
                    } else {
                        op = "<<"
                        index += 1
                        if byte(0) == UInt8(ascii: "-") { index += 1 }
                    }
                } else if byte(0) == UInt8(ascii: "&") {
                    op = "<&"
                    index += 1
                }
                pendingRedirect = op
            default:
                word.append(current)
                hasWord = true
                index += 1
            }
        }

        /// `#` starts a comment only at the start of a word
        private func startsWord() -> Bool {
            guard index > 0 else { return true }
            let previous = bytes[index - 1]
            return previous == UInt8(ascii: " ") || previous == UInt8(ascii: "\t")
                || previous == UInt8(ascii: "\n") || previous == UInt8(ascii: ";")
        }

        private mutating func doubleQuoted() {
            hasWord = true
            index += 1
            while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                let current = bytes[index]
                if current == UInt8(ascii: "\\"), let next = byte(1),
                   [UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "$"), UInt8(ascii: "`"),
                    UInt8(ascii: "\n")].contains(next) {
                    if next != UInt8(ascii: "\n") { word.append(next) }
                    index += 2
                } else if current == UInt8(ascii: "$"), byte(1) == UInt8(ascii: "(") {
                    substitution(openParen: index + 1, from: index)
                } else if current == UInt8(ascii: "`") {
                    backticks()
                } else {
                    word.append(current)
                    index += 1
                }
            }
            index += 1
        }

        /// `$( … )` / `<( … )`: keeps the raw text in the word and parses the inside as its own
        /// command. `from` is where the raw text starts, `openParen` the `(`.
        private mutating func substitution(openParen: Int, from: Int) {
            var cursor = openParen + 1
            var level = 1
            while cursor < bytes.count, level > 0 {
                switch bytes[cursor] {
                case UInt8(ascii: "\\"):
                    cursor += 1
                case UInt8(ascii: "'"):
                    cursor += 1
                    while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "'") { cursor += 1 }
                case UInt8(ascii: "\""):
                    cursor += 1
                    while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "\"") {
                        if bytes[cursor] == UInt8(ascii: "\\") { cursor += 1 }
                        cursor += 1
                    }
                case UInt8(ascii: "("):
                    level += 1
                case UInt8(ascii: ")"):
                    level -= 1
                default:
                    break
                }
                cursor += 1
            }
            let end = min(cursor, bytes.count)  // one past the closing paren
            let innerEnd = level == 0 ? end - 1 : end
            word.append(contentsOf: bytes[from..<end])
            feed(Array(bytes[min(openParen + 1, innerEnd)..<innerEnd]))
            index = end
        }

        private mutating func backticks() {
            let start = index
            var cursor = index + 1
            while cursor < bytes.count, bytes[cursor] != UInt8(ascii: "`") {
                if bytes[cursor] == UInt8(ascii: "\\") { cursor += 1 }
                cursor += 1
            }
            let innerEnd = min(cursor, bytes.count)
            let end = min(cursor + 1, bytes.count)
            word.append(contentsOf: bytes[start..<end])
            feed(Array(bytes[min(start + 1, innerEnd)..<innerEnd]))
            index = end
        }

        private mutating func feed(_ inner: [UInt8]) {
            guard depth < ShellCommandSplitter.maxDepth, !inner.isEmpty else { return }
            var parser = Parser(bytes: inner, depth: depth + 1)
            feeds.append(contentsOf: parser.run().map { pipeline in
                pipeline.map { segment in
                    var segment = segment
                    segment.inSubstitution = true
                    return segment
                }
            })
        }

        /// `2>file`: the digits in front of a redirect are a file descriptor, not an argument
        private mutating func dropFileDescriptor() {
            guard hasWord, pendingRedirect == nil, !word.isEmpty,
                  word.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") })
            else { return }
            word.removeAll(keepingCapacity: true)
            hasWord = false
        }

        private mutating func endWord() {
            guard hasWord else { return }
            let text = String(decoding: word, as: UTF8.self)
            word.removeAll(keepingCapacity: true)
            hasWord = false
            guard let op = pendingRedirect else {
                words.append(text)
                return
            }
            pendingRedirect = nil
            switch op {
            case "<<":
                heredocs.append((text, nextOwner))
                openedHere.append(nextOwner)
                nextOwner += 1
                // Kept as a redirect (target = delimiter): the command's stdin is the heredoc
                redirects.append(Redirect(op: op, target: text))
            case ">&", "<&":
                // 2>&1 / >&- duplicate or close a descriptor; anything else names a file
                let isDescriptor = text == "-" || text.allSatisfy(\.isNumber)
                if !isDescriptor { redirects.append(Redirect(op: op, target: text)) }
            default:
                redirects.append(Redirect(op: op, target: text))
            }
        }

        /// Ends the current segment at a control operator `length` bytes long
        private mutating func boundary(isPipe: Bool, length: Int) {
            endWord()
            pendingRedirect = nil
            if !words.isEmpty || !redirects.isEmpty || !feeds.isEmpty {
                let end = min(index, bytes.count)
                let text = String(decoding: bytes[min(segmentStart, end)..<end], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                var built = ShellCommandSplitter.makeSegment(
                    words: words, redirects: redirects, feeds: feeds, text: text)
                // The last heredoc a command opens is the one it reads
                built.segment.heredocOwner = openedHere.last ?? 0
                openedHere = []
                pipeline.append(built.segment)
                nested.append(contentsOf: feeds)
                if depth < ShellCommandSplitter.maxDepth {
                    for script in built.scripts {
                        var parser = Parser(bytes: Array(script.utf8), depth: depth + 1)
                        nested.append(contentsOf: parser.run())
                    }
                }
                words = []
                redirects = []
                feeds = []
                pendingPipe = false
            }
            if isPipe {
                pendingPipe = true
            } else if !pendingPipe {
                // A newline right after `|` continues the pipeline
                closePipeline()
            }
            index += length
            segmentStart = index
        }

        private mutating func closePipeline() {
            if !pipeline.isEmpty { result.append(pipeline) }
            result.append(contentsOf: nested)
            pipeline = []
            nested = []
            pendingPipe = false
        }

        /// After the line that opened them, heredoc bodies run to a line holding only the delimiter
        private mutating func skipHeredocBodies() {
            guard !heredocs.isEmpty else { return }
            for heredoc in heredocs {
                let bodyStart = index
                var bodyEnd = index
                var closed = false
                while index < bytes.count, !closed {
                    var lineEnd = index
                    while lineEnd < bytes.count, bytes[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
                    let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    closed = line == heredoc.delimiter
                    if !closed { bodyEnd = min(lineEnd + 1, bytes.count) }
                    index = min(lineEnd + 1, bytes.count)
                }
                bodies.append(
                    (heredoc.owner, String(decoding: bytes[bodyStart..<bodyEnd], as: UTF8.self)))
            }
            heredocs = []
            segmentStart = index
        }
    }
}
