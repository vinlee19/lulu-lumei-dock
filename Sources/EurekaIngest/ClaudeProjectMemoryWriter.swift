import EurekaKit
import Foundation

/// Saves one confirmed item from a session review into the project's Claude memory library
/// (`<claude home>/projects/<encoded project path>/memory/`), the place Claude Code reads at the
/// start of a session in that project (`~/.claude/memories` is not loaded, so it is not used).
///
/// The file follows Claude's own memory format (frontmatter `name`, `description`,
/// `metadata.type`, `originSessionId`) so Claude and Eureka's memory pages treat it like any other
/// entry, and a pointer line is appended to `MEMORY.md`. Nothing is ever overwritten: a name that
/// is taken gets a numeric suffix.
public enum ClaudeProjectMemoryWriter {
    public enum Kind: String, Sendable {
        /// Knowledge about the project (a fact, or a decision with its reason)
        case project
        /// How the AI should work with this person (drawn from their corrections)
        case feedback
    }

    public enum WriteError: Error, Equatable {
        case noProjectDirectory
        case emptyContent
    }

    /// The memory directory Claude reads for a project path
    public static func memoryDirectory(
        forProject projectPath: String,
        claudeHome: URL = SkillMemoryIndexer.claudeHome()
    ) -> URL {
        claudeHome
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(SkillMemoryIndexer.encodeProjectDirName(projectPath), isDirectory: true)
            .appendingPathComponent("memory", isDirectory: true)
    }

    /// Writes the entry and its index line; returns the new file
    @discardableResult
    public static func write(
        title: String, content: String, kind: Kind, originSessionId: String?,
        projectPath: String?, now: Date = Date(),
        claudeHome: URL = SkillMemoryIndexer.claudeHome()
    ) throws -> URL {
        guard let projectPath, !projectPath.isEmpty else { throw WriteError.noProjectDirectory }
        let body = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { throw WriteError.emptyContent }

        let directory = memoryDirectory(forProject: projectPath, claudeHome: claudeHome)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let slug = slug(for: heading.isEmpty ? body : heading, now: now)
        let file = uniqueFile(in: directory, base: "\(kind.rawValue)_\(slug)")
        let name = file.deletingPathExtension().lastPathComponent
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var lines = [
            "---",
            "name: \(name)",
            "description: \(yamlQuoted(heading.isEmpty ? String(body.prefix(80)) : heading))",
            "metadata:",
            "  node_type: memory",
            "  type: \(kind.rawValue)",
        ]
        if let originSessionId { lines.append("  originSessionId: \(originSessionId)") }
        lines.append("  modified: \(formatter.string(from: now))")
        lines.append("---")
        lines.append("")
        lines.append(body)
        lines.append("")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try appendIndexLine(
            in: directory, file: file.lastPathComponent,
            title: heading.isEmpty ? name : heading, hook: body)
        return file
    }

    /// `- [Title](file.md) — hook`, appended to MEMORY.md (created when missing)
    static func appendIndexLine(in directory: URL, file: String, title: String, hook: String) throws {
        let index = directory.appendingPathComponent("MEMORY.md")
        let oneLine = hook.split(whereSeparator: \.isNewline).joined(separator: " ")
        let shortHook = oneLine.count > 80 ? String(oneLine.prefix(80)) + "…" : oneLine
        let line = "- [\(title)](\(file)) — \(shortHook)\n"
        if let handle = try? FileHandle(forUpdating: index) {
            defer { try? handle.close() }
            let end = try handle.seekToEnd()
            var prefix = ""
            if end > 0 {
                // Start on a new line when the file doesn't end with one
                try handle.seek(toOffset: end - 1)
                if handle.readData(ofLength: 1) != Data("\n".utf8) { prefix = "\n" }
                try handle.seekToEnd()
            }
            try handle.write(contentsOf: Data((prefix + line).utf8))
        } else {
            try ("# Memory Index\n\n" + line).write(to: index, atomically: true, encoding: .utf8)
        }
    }

    /// Lowercase ASCII words joined by `_`; titles without ASCII words get a dated fallback
    static func slug(for text: String, now: Date) -> String {
        let words = text.lowercased()
            .split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
            .prefix(6)
        let joined = words.joined(separator: "_")
        if !joined.isEmpty { return String(joined.prefix(48)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "review_" + formatter.string(from: now)
    }

    static func uniqueFile(in directory: URL, base: String) -> URL {
        var candidate = directory.appendingPathComponent(base + ".md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)_\(counter).md")
            counter += 1
        }
        return candidate
    }

    /// Double-quoted YAML scalar (quotes and backslashes escaped, newlines flattened)
    static func yamlQuoted(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let escaped = flat.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
