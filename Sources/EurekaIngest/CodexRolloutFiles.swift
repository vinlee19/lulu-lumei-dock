import Foundation

/// Recursive enumerator for every rollout-*.jsonl under ~/.codex/sessions.
///
/// Rollouts are filed by the session's **creation day** (YYYY/MM/DD); resuming an old session
/// appends to the original file in place (mtime refreshes, the file doesn't move) and never creates
/// today's date dir. So "count the latest N date dirs" is bound to miss sessions created long ago
/// but active now; every consumer (tailer/index/audit) walks the whole tree, then filters by mtime
/// as needed. EurekaUsage can't depend on this module, so it carries its own small copy (same
/// cross-module convention as JSONL reading).
enum CodexRolloutFiles {
    /// A rollout file and its stat info; mtime is nil when it can't be read, and the caller decides
    /// what to do
    struct Entry {
        let url: URL
        let mtime: Date?
        let size: UInt64
    }

    /// Enumerate rollout-*.jsonl in every numeric YYYY/MM/DD dir under sessionsRoot across the
    /// whole tree
    static func enumerate(sessionsRoot: URL) -> [Entry] {
        var results: [Entry] = []
        for year in numericSubdirs(of: sessionsRoot, digits: 4) {
            for month in numericSubdirs(of: year, digits: 2) {
                for day in numericSubdirs(of: month, digits: 2) {
                    let files = (try? FileManager.default.contentsOfDirectory(
                        at: day,
                        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
                    )) ?? []
                    for file in files
                    where file.lastPathComponent.hasPrefix("rollout-")
                        && file.pathExtension == "jsonl" {
                        let values = try? file.resourceValues(
                            forKeys: [.contentModificationDateKey, .fileSizeKey])
                        results.append(Entry(
                            url: file,
                            mtime: values?.contentModificationDate,
                            size: UInt64(values?.fileSize ?? 0)))
                    }
                }
            }
        }
        return results
    }

    /// List subdirectories named with exactly N digits (YYYY = 4, MM/DD = 2); skip every other
    /// entry
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
