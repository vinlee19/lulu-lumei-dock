import Foundation

/// Recursive enumerator for every rollout-*.jsonl under ~/.codex/sessions.
/// Same logic as EurekaIngest.CodexRolloutFiles: EurekaUsage can't depend on EurekaIngest,
/// so it carries its own copy (the cross-module convention of JSONLinesReader /
/// CodexRolloutDecoderProxy).
/// A resumed old session appends in place under its creation-day directory (mtime refreshes,
/// no new day directory is created),
/// so "count the last N date directories" always misses it → every consumer walks the whole tree.
enum CodexRolloutFiles {
    /// A rollout file and its mtime (nil when unreadable; the caller decides what to do with it)
    struct Entry {
        let url: URL
        let mtime: Date?
    }

    /// Enumerates rollout-*.jsonl in every numeric YYYY/MM/DD directory under sessionsRoot
    static func enumerate(sessionsRoot: URL) -> [Entry] {
        var results: [Entry] = []
        for year in numericSubdirs(of: sessionsRoot, digits: 4) {
            for month in numericSubdirs(of: year, digits: 2) {
                for day in numericSubdirs(of: month, digits: 2) {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: day, includingPropertiesForKeys: [.contentModificationDateKey]
                    )) ?? []
                    for file in files
                    where file.lastPathComponent.hasPrefix("rollout-")
                        && file.pathExtension == "jsonl" {
                        results.append(Entry(
                            url: file,
                            mtime: (try? file.resourceValues(
                                forKeys: [.contentModificationDateKey]))?
                                .contentModificationDate))
                    }
                }
            }
        }
        return results
    }

    /// Lists subdirectories named with exactly N digits (YYYY = 4, MM/DD = 2); every other entry is
    /// skipped
    private static func numericSubdirs(of dir: URL, digits: Int) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return children.filter { url in
            let name = url.lastPathComponent
            return name.count == digits && name.allSatisfy(\.isNumber)
                && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
