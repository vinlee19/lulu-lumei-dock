import Foundation

/// Index of Cursor session transcript files:
/// `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`.
///
/// Since Cursor 3.13.10, besides writing to `state.vscdb`, it also writes a Claude-style JSONL for
/// every agent turn. How the two channels divide the work (don't treat them as substitutes):
///   - **the DB** is the only complete source: all history, tokens, ctx%, todos, child sessions;
///   - **the transcript** only covers turns since this feature shipped and has no tokens / ctx%,
///     but it has two things the DB lacks -- an explicit `turn_ended`, and the project slug built
///     into its path.
///
/// The slug is a lossy encoding (both `/` and `.` become `-`; `Users-wl-xiao-vinlee-workspace-a-b`
/// can't be decoded back), so cwd **is never reverse-decoded**: known workspace dirs are encoded
/// forward into slugs and compared; only a match counts.
public enum CursorTranscriptIndex {
    public struct Entry: Equatable, Sendable {
        public var composerId: String
        public var url: URL
        /// Project directory; nil for `empty-window` or when no known workspace matches
        public var cwd: String?
    }

    private static let lock = NSLock()
    private static var cache: [String: (value: [Entry], at: Date)] = [:]
    /// A new turn **creates** a new file, so a long-lived cache would miss whole turns → much
    /// shorter than the workspace index's
    private static let cacheTTL: TimeInterval = 3

    /// Every transcript file under `<cliHome>/projects`
    public static func entries(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        now: Date = Date()
    ) -> [Entry] {
        lock.lock()
        if let cached = cache[cliHome.path], now.timeIntervalSince(cached.at) < cacheTTL {
            lock.unlock()
            return cached.value
        }
        lock.unlock()

        // Known workspace dirs → slug, for forward matching (the lossy slug is never
        // reverse-decoded)
        var slugToCwd: [String: String] = [:]
        for cwd in CursorWorkspaceIndex.folders(root: workspaceStorageRoot, now: now).values {
            slugToCwd[slug(forPath: cwd)] = cwd
        }

        let fm = FileManager.default
        let projectsRoot = cliHome.appendingPathComponent("projects", isDirectory: true)
        var results: [Entry] = []
        let projectDirs = (try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for projectDir in projectDirs {
            let cwd = slugToCwd[projectDir.lastPathComponent]
            let transcriptsRoot = projectDir
                .appendingPathComponent("agent-transcripts", isDirectory: true)
            let sessionDirs = (try? fm.contentsOfDirectory(
                at: transcriptsRoot, includingPropertiesForKeys: nil)) ?? []
            for sessionDir in sessionDirs {
                let composerId = sessionDir.lastPathComponent
                guard !composerId.isEmpty else { continue }
                let file = sessionDir.appendingPathComponent("\(composerId).jsonl")
                guard fm.fileExists(atPath: file.path) else { continue }
                results.append(Entry(composerId: composerId, url: file, cwd: cwd))
            }
        }

        lock.lock()
        cache[cliHome.path] = (results, now)
        lock.unlock()
        return results
    }

    /// Set of session ids that have a transcript file (the DB-side tailer uses it to yield
    /// lifecycle-event ownership)
    public static func ownedComposerIds(
        cliHome: URL = CursorPaths.cliHome(),
        workspaceStorageRoot: URL = CursorPaths.workspaceStorageRoot(),
        now: Date = Date()
    ) -> Set<String> {
        Set(entries(cliHome: cliHome, workspaceStorageRoot: workspaceStorageRoot, now: now)
            .map(\.composerId))
    }

    /// Absolute path → Cursor's project dir name. Observed:
    /// `/Users/wl.xiao/vinlee/workspace/aftership-semantic-layer` →
    /// `Users-wl-xiao-vinlee-workspace-aftership-semantic-layer`: drop the leading `/`, and replace
    /// every remaining `/` and `.` with `-`.
    public static func slug(forPath path: String) -> String {
        var text = path
        if text.hasPrefix("/") { text.removeFirst() }
        return text
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    /// Tests only: clear the cache so temp dirs don't bleed into each other
    public static func resetCacheForTesting() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
