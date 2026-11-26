import Foundation

/// Recursive enumerator for every rollout-*.jsonl (and compressed rollout-*.jsonl.zst) under
/// ~/.codex/sessions.
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
        /// `rollout-*.jsonl.zst`: Codex compressed the rollout when the session closed
        var isCompressed: Bool { url.pathExtension == "zst" }
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
                    let names = Set(files.map(\.lastPathComponent))
                    for file in files where isRollout(file.lastPathComponent, siblings: names) {
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

    /// `rollout-*.jsonl`, or `rollout-*.jsonl.zst` unless the plain file sits next to it.
    ///
    /// Codex compresses a rollout to `.jsonl.zst` when the session closes and decompresses it
    /// when the session resumes, so both can exist for a moment; the plain file is the live one.
    static func isRollout(_ name: String, siblings: Set<String>) -> Bool {
        guard name.hasPrefix("rollout-") else { return false }
        if name.hasSuffix(".jsonl") { return true }
        guard name.hasSuffix(".jsonl.zst") else { return false }
        return !siblings.contains(String(name.dropLast(".zst".count)))
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
