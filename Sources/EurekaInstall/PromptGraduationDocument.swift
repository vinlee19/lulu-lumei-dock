import Foundation

/// Document body written when a prompt graduates (is promoted to a skill / instruction). Pure
/// string functions, dependency-free, unit-testable; writing to disk, backups and path resolution
/// stay in the app layer (SkillMemoryService).
public enum PromptGraduationDocument {
    /// Full SKILL.md text. description goes into a YAML value: collapsed to one line and wrapped in
    /// double quotes (escape backslashes first, then quotes - the order matters), so colons and
    /// quotes are safe; the body ends with exactly one newline.
    public static func skill(slug: String, description: String, body: String) -> String {
        let desc = description
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "---\nname: \(slug)\ndescription: \"\(desc)\"\n---\n\n"
            + singleTrailingNewline(body)
    }

    /// Appends a section to a shared instruction file (the "append" in read-append-write).
    /// existing = nil means the file does not exist, so it starts with defaultHeader; otherwise the
    /// original's trailing blank lines collapse to exactly one before the new section.
    public static func appendingInstructionSection(
        to existing: String?, title: String, body: String,
        defaultHeader: String = "# AGENTS.md"
    ) -> String {
        singleTrailingNewline(existing ?? defaultHeader)
            + "\n## \(title)\n\n"
            + singleTrailingNewline(body)
    }

    /// In each directory Codex loads only the first existing file of AGENTS.override.md /
    /// AGENTS.md, so appends must go into the one that actually takes effect - writing AGENTS.md
    /// while an override exists goes into a black hole.
    public static func codexInstructionFileName(overrideExists: Bool) -> String {
        overrideExists ? "AGENTS.override.md" : "AGENTS.md"
    }

    /// Strips all trailing newlines, then adds exactly one
    static func singleTrailingNewline(_ text: String) -> String {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == "\n" || last == "\r" {
            trimmed = trimmed.dropLast()
        }
        return String(trimmed) + "\n"
    }
}
