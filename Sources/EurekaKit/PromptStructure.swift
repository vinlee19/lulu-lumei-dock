import Foundation

/// Static prompt-structure detection: a heuristic take on the official prompting checklist (name
/// files / give acceptance criteria / self-contained context / sections). **Weak prior**: the link
/// between static features and real outcomes is not locally verified (industry evidence is only
/// "helpful rule of thumb" grade), so it is only a detail-page hint, never escalates severity, and
/// never colors list dots.
public enum PromptStructure {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// Has acceptance criteria (what counts as success / expected output / verify by running
        /// tests)
        public static let acceptance = Flags(rawValue: 1 << 0)
        /// Names files/paths (saves the agent the cost of locating them)
        public static let filePath = Flags(rawValue: 1 << 1)
        /// Starts with a pronoun ("this / that / it": context isn't self-contained and breaks
        /// outside the session)
        public static let deicticStart = Flags(rawValue: 1 << 2)
        /// Structured sections (headings / lists: a readability trait of long instructions)
        public static let sectioned = Flags(rawValue: 1 << 3)

        /// Storage encoding (stable short codes joined by commas; fixed order for easy comparison)
        public var encoded: String {
            var parts: [String] = []
            if contains(.acceptance) { parts.append("a") }
            if contains(.filePath) { parts.append("f") }
            if contains(.deicticStart) { parts.append("d") }
            if contains(.sectioned) { parts.append("s") }
            return parts.joined(separator: ",")
        }

        public static func decode(_ raw: String) -> Flags {
            var flags: Flags = []
            for part in raw.split(separator: ",") {
                switch part {
                case "a": flags.insert(.acceptance)
                case "f": flags.insert(.filePath)
                case "d": flags.insert(.deicticStart)
                case "s": flags.insert(.sectioned)
                default: break
                }
            }
            return flags
        }
    }

    /// Acceptance-criteria wording (compound phrases, not single words: the bare word for "test"
    /// would misflag "help me fix the test" as having criteria)
    static let acceptancePhrases = [
        "验收标准", "怎样算成功", "期望输出", "期望结果", "预期输出", "预期结果",
        "跑一下测试", "运行测试", "测试通过", "全部通过", "验证方式", "验证一下",
        "expected output", "should pass", "should return", "acceptance criteria",
        "make sure tests", "run the tests", "verify that",
    ]

    /// Leading pronouns (a sign the context isn't self-contained)
    static let deicticPrefixes = [
        "这个", "那个", "这里", "这段", "这些", "它", "上面", "刚才", "刚刚",
        "this ", "that ", "it ", "these ", "the above",
    ]

    public static func detect(_ text: String) -> Flags {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var flags: Flags = []
        let lowered = trimmed.lowercased()

        if acceptancePhrases.contains(where: { lowered.contains($0) }) {
            flags.insert(.acceptance)
        }
        // path: a token containing / with an extension (`a/b.swift`, `./x.md`,
        // `~/.claude/CLAUDE.md`)
        if lowered.range(
            of: #"[\w~.@-]+/[\w./@-]*\.[a-z0-9]{1,6}"#, options: .regularExpression
        ) != nil {
            flags.insert(.filePath)
        }
        if deicticPrefixes.contains(where: { lowered.hasPrefix($0) }) {
            flags.insert(.deicticStart)
        }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: true)
        let hasHeading = lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let listLines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.hasPrefix("* ")
                || (t.first?.isNumber == true && (t.dropFirst().hasPrefix(". ") || t.dropFirst().hasPrefix("、")))
        }.count
        if hasHeading || listLines >= 2 {
            flags.insert(.sectioned)
        }
        return flags
    }
}
