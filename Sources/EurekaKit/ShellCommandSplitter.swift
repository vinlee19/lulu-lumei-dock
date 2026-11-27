import Foundation

/// Splits shell command text into pipelines of simple commands, so risk rules can look at the
/// command word, its arguments and its redirects instead of running a regex over the whole text.
///
/// It is a tokenizer, not a shell: it tracks quotes, escapes, `$( )` / backticks / `<( )`, the
/// control operators and redirects, and drops heredoc bodies. Variables are never expanded and
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

    public struct Segment: Equatable, Sendable {
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

        /// Arguments that are not flags
        public var operands: [String] { args.filter { !$0.hasPrefix("-") } }
    }

    public typealias Pipeline = [Segment]

    /// Nesting followed into `$( )` and `bash -c '…'`
    static let maxDepth = 3
    /// Longer input is cut: the largest real commands are heredocs, whose bodies are skipped anyway
    static let maxLength = 64 << 10

    /// Every pipeline of the command, in source order. A pipeline found inside a substitution or
    /// inside `bash -c '…'` / `eval '…'` follows the pipeline that contains it.
    public static func split(_ source: String) -> [Pipeline] {
        var parser = Parser(bytes: Array(source.utf8.prefix(maxLength)), depth: 0)
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
    ) -> (segment: Segment, script: String?) {
        var index = 0
        var found: [String] = []
        var command = ""
        while index < words.count {
            let word = words[index]
            if isAssignment(word) || keywords.contains(word) {
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
        let segment = Segment(
            command: command, wrappers: found, args: args, redirects: redirects,
            text: text, feeds: feeds)

        var script: String?
        if shells.contains(command) {
            // -c, or a flag cluster ending in c (-lc, -ic)
            if let flag = args.firstIndex(where: {
                $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")
            }), flag + 1 < args.count {
                script = args[flag + 1]
            }
        } else if command == "eval" {
            script = args.joined(separator: " ")
        }
        return (segment, script)
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
        private var heredocs: [String] = []

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
            return result
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
            feeds.append(contentsOf: parser.run())
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
                heredocs.append(text)
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
                let built = ShellCommandSplitter.makeSegment(
                    words: words, redirects: redirects, feeds: feeds, text: text)
                pipeline.append(built.segment)
                nested.append(contentsOf: feeds)
                if let script = built.script, depth < ShellCommandSplitter.maxDepth {
                    var parser = Parser(bytes: Array(script.utf8), depth: depth + 1)
                    nested.append(contentsOf: parser.run())
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
            for delimiter in heredocs {
                var closed = false
                while index < bytes.count, !closed {
                    var lineEnd = index
                    while lineEnd < bytes.count, bytes[lineEnd] != UInt8(ascii: "\n") { lineEnd += 1 }
                    let line = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                        .trimmingCharacters(in: .whitespaces)
                    closed = line == delimiter
                    index = min(lineEnd + 1, bytes.count)
                }
            }
            heredocs = []
            segmentStart = index
        }
    }
}
