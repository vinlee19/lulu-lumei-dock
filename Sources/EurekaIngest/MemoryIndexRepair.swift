import EurekaKit
import Foundation

/// Deterministic repair of memory library index (`MEMORY.md`) drift:
/// - **Dangling references** → delete list lines pointing at files that no longer exist (the
///   agent loads line by line and would come up empty);
/// - **Unlisted entries** → append `- [title](file.md) — summary` lines at the end (the agent
///   reads the index to decide what to load; an unlisted entry is dead memory).
///
/// Pure text in/out, unit-testable. Detection matches `MemoryLibrary.unindexedEntries` /
/// `danglingIndexRefs` (same normalizeKey), but is recomputed from the **full text** — the
/// indexer's parse has a 64KB head cap, and a rewrite must work from the complete file, or the
/// unread tail would be misjudged as drift and cut off wholesale during repair.
public enum MemoryIndexRepair {
    public struct Outcome: Equatable, Sendable {
        public var text: String
        public var addedCount: Int
        public var removedCount: Int
    }

    /// Produces the repaired full index text; returns nil when there is no drift (no line to
    /// delete, no entry to add). `entries` are the library's real entries (excluding the index
    /// itself).
    public static func repair(indexText: String, entries: [MemoryEntry]) -> Outcome? {
        var actualKeys = Set<String>()
        for entry in entries {
            actualKeys.insert(key(forPath: entry.path))
            actualKeys.insert(MemoryGraphBuilder.normalizeKey(entry.title))
        }

        // 1) Delete dangling lines: only list items, and only when **every** .md link target on the
        //    line is missing from the directory — heading/body lines and lines with a still-valid
        //    link are always kept (conservative first; the index is the agent's entry file)
        var removedCount = 0
        var lines = indexText.components(separatedBy: "\n")
        lines.removeAll { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") else { return false }
            let targets = SkillMemoryIndexer.extractMarkdownLinks(line)
            guard !targets.isEmpty else { return false }
            let allDangling = targets.allSatisfy { !actualKeys.contains(key(forPath: $0)) }
            if allDangling { removedCount += 1 }
            return allDangling
        }

        // 2) Add unlisted entries: recompute listed keys from the cleaned full text; a hit on
        //    either the file name or the frontmatter title counts as listed (same criterion as
        //    MemoryLibrary.unindexedEntries)
        let indexedKeys = Set(
            SkillMemoryIndexer.extractMarkdownLinks(lines.joined(separator: "\n"))
                .map { key(forPath: $0) })
        let missing = entries.filter { entry in
            !indexedKeys.contains(key(forPath: entry.path))
                && !indexedKeys.contains(MemoryGraphBuilder.normalizeKey(entry.title))
        }

        guard removedCount > 0 || !missing.isEmpty else { return nil }

        if !missing.isEmpty {
            // Trim trailing blank lines before appending, then end with a single newline
            while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                lines.removeLast()
            }
            for entry in missing {
                lines.append(indexLine(for: entry))
            }
            lines.append("")
        }
        return Outcome(
            text: lines.joined(separator: "\n"),
            addedCount: missing.count,
            removedCount: removedCount)
    }

    /// One backfill line: `- [title](file name) — summary` (the dash part is omitted without a
    /// summary). Same format as the index lines Claude maintains itself, so it can keep taking over
    /// once written.
    static func indexLine(for entry: MemoryEntry) -> String {
        let file = URL(fileURLWithPath: entry.path).lastPathComponent
        let hook = (entry.summary ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return hook.isEmpty
            ? "- [\(entry.title)](\(file))"
            : "- [\(entry.title)](\(file)) — \(hook)"
    }

    /// Path/link target → normalized key (file name without extension, same as normalizeKey)
    private static func key(forPath path: String) -> String {
        MemoryGraphBuilder.normalizeKey(
            URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
    }
}
