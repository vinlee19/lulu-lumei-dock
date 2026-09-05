import Foundation

/// Prompt 静态结构检测：官方提示词清单（点名文件 / 给验收标准 / 上下文自足 / 分节）
/// 的启发式落地。**弱先验**：静态特征与实际效果的相关性未经本地验证（业界结论也仅
/// "有益经验"级），所以只作详情页提示，不参与严重度升级、不进列表色点。
public enum PromptStructure {
    public struct Flags: OptionSet, Equatable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// 带验收标准（怎样算成功/期望输出/跑测试验证）
        public static let acceptance = Flags(rawValue: 1 << 0)
        /// 点名了文件/路径（省掉 agent 的定位开销）
        public static let filePath = Flags(rawValue: 1 << 1)
        /// 指代词开头（"这个/那个/它"——上下文不自足，离开会话即失效）
        public static let deicticStart = Flags(rawValue: 1 << 2)
        /// 结构化分节（标题/列表——长指令的可读性特征）
        public static let sectioned = Flags(rawValue: 1 << 3)

        /// 落库编码（稳定短码，逗号相连；顺序固定便于比对）
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

    /// 验收标准字样（用复合短语而不是单词——"测试"单字会把"帮我修测试"误判成带验收）
    static let acceptancePhrases = [
        "验收标准", "怎样算成功", "期望输出", "期望结果", "预期输出", "预期结果",
        "跑一下测试", "运行测试", "测试通过", "全部通过", "验证方式", "验证一下",
        "expected output", "should pass", "should return", "acceptance criteria",
        "make sure tests", "run the tests", "verify that",
    ]

    /// 指代词开头（上下文不自足的标志）
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
        // 路径：含 / 且带扩展名的 token（`a/b.swift`、`./x.md`、`~/.claude/CLAUDE.md`）
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
