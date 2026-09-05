import Foundation

/// Prompt 毕业（升级为技能 / 指令）时写盘的文档正文。纯字符串函数、零依赖、可单测；
/// 写盘、备份、路径解析留在 app 层（SkillMemoryService）。
public enum PromptGraduationDocument {
    /// SKILL.md 全文。description 进 YAML 值：压成单行 + 双引号包裹（反斜杠先转义再转义
    /// 引号，顺序不可换），冒号/引号都安全；正文尾部收成恰好一个换行。
    public static func skill(slug: String, description: String, body: String) -> String {
        let desc = description
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "---\nname: \(slug)\ndescription: \"\(desc)\"\n---\n\n"
            + singleTrailingNewline(body)
    }

    /// 向共享指令文件追加一节（读-追加-写里的"追加"）。existing = nil 表示文件不存在，
    /// 以 defaultHeader 起头；否则原文尾部空行收成恰好一个空行再接新节。
    public static func appendingInstructionSection(
        to existing: String?, title: String, body: String,
        defaultHeader: String = "# AGENTS.md"
    ) -> String {
        singleTrailingNewline(existing ?? defaultHeader)
            + "\n## \(title)\n\n"
            + singleTrailingNewline(body)
    }

    /// Codex 每一级目录只加载 AGENTS.override.md / AGENTS.md 中第一个存在的文件，
    /// 追加必须写进真正生效的那个 —— override 存在时写 AGENTS.md 等于写进黑洞。
    public static func codexInstructionFileName(overrideExists: Bool) -> String {
        overrideExists ? "AGENTS.override.md" : "AGENTS.md"
    }

    /// 去掉尾部全部换行后补恰好一个换行
    static func singleTrailingNewline(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == "\n" || last == "\r" {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed) + "\n"
    }
}
