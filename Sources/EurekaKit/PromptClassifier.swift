import Foundation

/// Prompt 的复用价值分类（实勘 2395 条本机数据定的阈值，数据与取舍记在
/// docs/specs/2026-08-23-prompt-library-design.md 的「修订记录」）。
///
/// 分类是**内存派生**而非入库列：阈值会迭代，加列则每次调参都要刷全库 + 升 schema。
/// `all()` 本就全量载入内存，几千条量级 O(n) 分类在后台队列一次算完可忽略。
public enum PromptKind: String, Sendable, CaseIterable {
    /// 伪用户消息：斜杠命令回显 / 本地命令输出 / 任务通知等注入产物，不是人写的
    case noise
    /// 琐碎短语（"继续"/"好的"），打字比找快，无复用价值
    case trivial
    /// 短追问：脱离会话上下文即失效，默认展示但不置顶
    case followup
    /// 结构化指令：核心复用资产
    case instruction
    /// 长粘贴（日志/SQL/报错），是上下文不是提问
    case paste
}

public enum PromptClassifier {
    public struct Thresholds: Sendable {
        /// ≤ 此字符数视为琐碎（实勘 ≤12 字符的 418 条全是"继续"类）
        public var trivialMaxLength = 12
        /// ≤ 此字符数视为短追问
        public var followupMaxLength = 40
        /// ≥ 此字符数且无 markdown 结构视为长粘贴
        public var pasteMinLength = 2000
        public init() {}
    }

    /// 琐碎词表（长度阈值外的补充：这些即使凑够字符也没有复用价值）
    static let trivialPhrases: Set<String> = [
        "继续", "继续吧", "好的", "好", "可以", "行", "嗯", "对", "对的", "不", "不用",
        "你好", "谢谢", "开始", "开始吧", "试试", "再试试", "重试", "提交", "跑一下",
        "ok", "okay", "yes", "no", "go", "go on", "go ahead", "hi", "hello",
        "thanks", "retry", "run", "commit", "continue", "proceed", "done", "next",
    ]

    /// 伪用户消息前缀。**是前缀判定而非剥块**：这里服务的是存量库里未剥标签的原文
    /// （实勘 296 条噪音全以标签开头）；采集端的剥块走 TurnSlicer.realPrompt。
    /// 前 7 个与 TurnSlicer.injectedTags 对应，后 4 个是它清单外的
    /// （bash 桥接与 Codex 注入的环境上下文）。
    static let injectedPrefixes = [
        "<command-name>", "<command-message>", "<command-args>",
        "<local-command-stdout>", "<local-command-caveat>",
        "<task-notification>", "<system-reminder>",
        "<bash-input>", "<bash-stdout>",
        "<environment_context>", "<user_instructions>",
    ]

    /// 是否为注入产物 / 裸斜杠命令（非人类提问）
    public static func isInjectedArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        for prefix in injectedPrefixes where trimmed.hasPrefix(prefix) { return true }
        // 裸斜杠命令（"/compact"、"/effort high"）：单行、短、首字符 / 且后续不再含 /
        // （"/usr/bin/…" 这类路径含第二个 /，不算）
        if trimmed.hasPrefix("/"), !trimmed.contains("\n"), trimmed.count <= 64,
           !trimmed.dropFirst().contains("/") {
            return true
        }
        return false
    }

    public static func classify(
        _ text: String, thresholds: Thresholds = Thresholds()
    ) -> PromptKind {
        if isInjectedArtifact(text) { return .noise }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        if trimmed.count <= thresholds.trivialMaxLength || trivialPhrases.contains(lowered) {
            return .trivial
        }
        if trimmed.count >= thresholds.pasteMinLength && looksLikePaste(trimmed) {
            return .paste
        }
        if trimmed.count <= thresholds.followupMaxLength { return .followup }
        return .instruction
    }

    /// 长文本是否更像粘贴而非手写指令：手写长 prompt 通常带 markdown 结构
    /// （标题/列表/引用），日志与 SQL 粘贴没有。只扫前 200 行封顶成本。
    static func looksLikePaste(_ text: String) -> Bool {
        let structured = text.split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(200)
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                return t.hasPrefix("#") || t.hasPrefix("- ") || t.hasPrefix("* ")
                    || t.hasPrefix("> ")
            }
            .count
        return structured < 3
    }

    /// 重复聚类指纹：lowercase + 压空白，只取前 512 字符 —— 大粘贴不值得整段扫，
    /// 且前缀相同的长文本本来就该聚成一组
    public static func normalizedFingerprint(_ text: String) -> String {
        String(text.prefix(512))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// 入库截断：按字符计（安全，不切碎合字），尾附标记。
    /// 实勘最长一条 1.98MB 的日志粘贴 —— 复用库不需要也不该存这种全文。
    public static func truncateForStorage(_ text: String, limit: Int = 65536) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "\n…[已截断]"
    }
}
