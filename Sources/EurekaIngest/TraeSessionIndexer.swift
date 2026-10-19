import Foundation
import EurekaKit

/// Trae session index - **inferred from the plaintext memory library**, because the session
/// DB itself is unreadable.
///
/// Session bodies/titles/times all live in `ModularData/ai-agent/database.db`, which is
/// SQLCipher encrypted (see `TraePaths`). The only plaintext side evidence is the memory
/// library Trae writes itself:
///
/// ```
/// ~/.trae-cn/memory/projects/<encoded>/
///   project_memory.md                              ← project memory (Memory tab, unused here)
///   <YYYYMMDD>/topics.md                           ← one narrative summary + session_id + time per session
///   <YYYYMMDD>/session_memory_<sessionId>.jsonl    ← one line per turn (intent/actions/outcome + time)
/// ```
///
/// A `topics.md` entry looks like this (observed; blocks may run together with no newline, so
/// entries are delimited by "the next block header" rather than split by line):
///
/// ```
/// [session_id: 6a75a6cd602f315c19ec63ac | topic_summary_time: 2026-08-07 17:51:40]User requested…
/// ```
///
/// **This index lags**: Trae generates summaries asynchronously
/// (`compact_summary_meta.mode = async`), and there is nothing at all if the user turns the
/// memory feature off. So it only serves session browsing and is **not a live channel** -
/// live activity comes from hooks (see `TraeHooksInstaller`).
public enum TraeSessionIndexer {
    /// One entry parsed from a single day dir
    public struct Topic: Equatable, Sendable {
        public var sessionId: String
        public var summary: String
        public var summaryTime: Date?
    }

    public static func index(
        memoryProjectsRoot: URL = TraePaths.memoryProjectsRoot(),
        workspaceStorageRoots: [URL] = TraePaths.workspaceStorageRoots(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        let fm = FileManager.default
        let knownCwds = workspaceFolders(roots: workspaceStorageRoots)
        let cutoff = now.addingTimeInterval(-window)

        // sessionId → accumulated state. A session can span several <YYYYMMDD> dirs and must
        // be merged across them.
        struct Accum {
            var cwd: String?
            var summary: String?
            /// `topic_summary_time` of the current summary; decides which one wins
            var summaryAt: Date?
            var first: Date?
            var last: Date?
            var topicsPath: String?
        }
        var accum: [String: Accum] = [:]

        func note(
            sessionId: String, cwd: String?, summary: String?, summaryAt: Date?,
            times: [Date], topicsPath: String?
        ) {
            var entry = accum[sessionId] ?? Accum()
            if entry.cwd == nil { entry.cwd = cwd }
            // The newer the narrative, the closer it is to the session's final shape → take
            // the latest by topic_summary_time. **Don't rely on traversal order**:
            // `contentsOfDirectory` guarantees no order, so the day dirs come back shuffled and
            // we'd randomly pick the first day's summary (a test failed here once because of it).
            if let summary, !summary.isEmpty {
                let newer = switch (entry.summaryAt, summaryAt) {
                case (nil, _): true                              // no summary yet → take it
                case (_, nil): false                             // new one has no time → keep existing
                case (let old?, let new?): new >= old
                }
                if newer {
                    entry.summary = summary
                    entry.summaryAt = summaryAt
                }
            }
            for time in times {
                entry.first = entry.first.map { min($0, time) } ?? time
                entry.last = entry.last.map { max($0, time) } ?? time
            }
            if let topicsPath { entry.topicsPath = topicsPath }
            accum[sessionId] = entry
        }

        let projectDirs = ((try? fm.contentsOfDirectory(
            at: memoryProjectsRoot, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

        for projectDir in projectDirs {
            let cwd = resolveCwd(encodedDirName: projectDir.lastPathComponent, knownCwds: knownCwds)
            let dayDirs = ((try? fm.contentsOfDirectory(
                at: projectDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }

            for dayDir in dayDirs {
                let topicsURL = dayDir.appendingPathComponent("topics.md")
                for topic in parseTopics(fileURL: topicsURL) {
                    note(
                        sessionId: topic.sessionId, cwd: cwd, summary: topic.summary,
                        summaryAt: topic.summaryTime,
                        times: [topic.summaryTime].compactMap { $0 },
                        topicsPath: topicsURL.path)
                }
                // Per-turn log: timestamps only (the body belongs to the Memory tab, not the
                // session title)
                let files = (try? fm.contentsOfDirectory(at: dayDir, includingPropertiesForKeys: nil))
                    ?? []
                for file in files
                where file.lastPathComponent.hasPrefix("session_memory_")
                    && file.pathExtension == "jsonl" {
                    let sessionId = String(
                        file.deletingPathExtension().lastPathComponent
                            .dropFirst("session_memory_".count))
                    guard !sessionId.isEmpty else { continue }
                    let times = turnTimestamps(fileURL: file)
                    guard !times.isEmpty else { continue }
                    note(
                        sessionId: sessionId, cwd: cwd, summary: nil, summaryAt: nil,
                        times: times, topicsPath: nil)
                }
            }
        }

        return accum.compactMap { sessionId, entry -> AgentSessionInfo? in
            guard let last = entry.last, last >= cutoff else { return nil }
            return AgentSessionInfo(
                source: .trae,
                id: sessionId,
                cwd: entry.cwd,
                name: entry.summary.map { tightenPlanTitle($0, maxLength: 80) },
                startedAt: entry.first,
                lastActiveAt: last,
                // Same as cursor / hermes / opencode: shared-DB sources report no per-session size
                sizeBytes: 0,
                // Deliberately **not the encrypted DB path**; use where the info actually comes
                // from (the plaintext topics.md). `usesSharedSessionDatabase == true` keeps the
                // UI from showing this path; this just avoids leaving an empty string.
                transcriptPath: entry.topicsPath ?? "")
        }
        .sorted { $0.lastActiveAt > $1.lastActiveAt }
        .prefix(maxSessions)
        .map { $0 }
    }

    /// Project dirs the sessions touched (merged into project discovery)
    public static func recentDirectories(
        memoryProjectsRoot: URL = TraePaths.memoryProjectsRoot(),
        workspaceStorageRoots: [URL] = TraePaths.workspaceStorageRoots(),
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [String] {
        var seen = Set<String>()
        return index(
            memoryProjectsRoot: memoryProjectsRoot,
            workspaceStorageRoots: workspaceStorageRoots,
            window: window, maxSessions: maxSessions, now: now
        )
        .compactMap { $0.cwd }
        .filter { seen.insert($0).inserted }
    }

    // MARK: - topics.md parsing

    /// Cuts each session's entry out of `topics.md`.
    ///
    /// Delimited by "the start of the next block header" rather than by line: observed files
    /// are a **single line with no newline**, `[header]body`, and a second session may follow
    /// directly without a line break.
    public static func parseTopics(fileURL: URL) -> [Topic] {
        guard let data = try? Data(contentsOf: fileURL),
            let text = String(data: data, encoding: .utf8), !text.isEmpty
        else { return [] }

        // [session_id: <id> | topic_summary_time: <yyyy-MM-dd HH:mm:ss>]
        let pattern = #"\[\s*session_id\s*:\s*([^\s|\]]+)\s*\|\s*topic_summary_time\s*:\s*([^\]]*)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, range: full)
        guard !matches.isEmpty else { return [] }

        var result: [Topic] = []
        for (offset, match) in matches.enumerated() {
            guard let idRange = Range(match.range(at: 1), in: text) else { continue }
            let sessionId = String(text[idRange]).trimmingCharacters(in: .whitespaces)
            guard !sessionId.isEmpty else { continue }

            let time = Range(match.range(at: 2), in: text)
                .map { String(text[$0]).trimmingCharacters(in: .whitespaces) }
                .flatMap(parseLocalTimestamp)

            // Body = end of this header → start of the next header (last block runs to EOF)
            guard let bodyStart = Range(match.range, in: text)?.upperBound else { continue }
            let bodyEnd: String.Index = offset + 1 < matches.count
                ? (Range(matches[offset + 1].range, in: text)?.lowerBound ?? text.endIndex)
                : text.endIndex
            guard bodyStart <= bodyEnd else { continue }
            let summary = text[bodyStart..<bodyEnd]
                .trimmingCharacters(in: .whitespacesAndNewlines)

            result.append(Topic(sessionId: sessionId, summary: summary, summaryTime: time))
        }
        return result
    }

    /// Per-turn times from `session_memory_<id>.jsonl`.
    /// Prefers `compact_summary_meta.created_at_ms` (epoch millis, no timezone ambiguity),
    /// falling back to `message_summary_time` (local time string, no timezone marker).
    static func turnTimestamps(fileURL: URL, maxBytes: Int = 1 << 20) -> [Date] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        // One line per turn, a few hundred bytes each; past the cap read only the head (times
        // only set first/last, so that's enough)
        let slice = data.count > maxBytes ? data.prefix(maxBytes) : data
        guard let text = String(data: slice, encoding: .utf8) else { return [] }

        var result: [Date] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)),
                let root = object as? [String: Any]
            else { continue }
            if let meta = root["compact_summary_meta"] as? [String: Any],
                let millis = (meta["created_at_ms"] as? NSNumber)?.doubleValue, millis > 0 {
                result.append(Date(timeIntervalSince1970: millis / 1000))
                continue
            }
            if let raw = root["message_summary_time"] as? String,
                let date = parseLocalTimestamp(raw) {
                result.append(date)
            }
        }
        return result
    }

    /// `"2026-08-07 17:51:40"` - no timezone marker, interpreted in the local timezone (Trae
    /// is a local app writing it)
    static func parseLocalTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return localFormatter.date(from: trimmed)
    }

    private static let localFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = .current
        return formatter
    }()

    // MARK: - cwd lookup

    /// The **real absolute paths** given by the `folder` field of `workspace.json` (merged
    /// across channels, deduped). This is the only cwd source that skips the lossy encoding,
    /// so it takes priority.
    static func workspaceFolders(roots: [URL]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for root in roots {
            let dirs = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                let file = dir.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: file),
                    let object = try? JSONSerialization.jsonObject(with: data),
                    let root = object as? [String: Any],
                    let folder = root["folder"] as? String,
                    let path = URL(string: folder)?.path, !path.isEmpty,
                    seen.insert(path).inserted
                else { continue }
                result.append(path)
            }
        }
        return result
    }

    /// Memory library project dir name → real cwd.
    ///
    /// Dir names look like `-Users-wl-xiao-vinlee-workspace-lerobot--p2-832ae42141a2828b9304`:
    /// slash encoding (`/`, `.` and `_` all become `-`, see
    /// `SkillMemoryIndexer.encodeProjectDirName`) plus a `--p<N>-<hash>` suffix.
    ///
    /// **The encoding is many-to-one and irreversible** (a `-` may come from `/`, `.`, `_` or
    /// an original hyphen), so the only option is to **encode known real paths forward** and
    /// compare - never split on `-` in reverse: that turns `aftership-semantic-layer` into
    /// `layer` (this pitfall is recorded in CLAUDE.md).
    /// No match returns nil (better no cwd than a wrong one).
    public static func resolveCwd(encodedDirName: String, knownCwds: [String]) -> String? {
        let stripped = stripProjectSuffix(encodedDirName)
        for cwd in knownCwds {
            let encoded = SkillMemoryIndexer.encodeProjectDirName(
                URL(fileURLWithPath: cwd).standardizedFileURL.path)
            if encoded == stripped || encoded == encodedDirName { return cwd }
        }
        return nil
    }

    /// Strips the `--p<N>-<hash>` suffix. Returns the name unchanged when that shape isn't
    /// found (older versions may have no suffix).
    public static func stripProjectSuffix(_ name: String) -> String {
        guard let range = name.range(of: "--p", options: .backwards) else { return name }
        // Only a digit after `--p` makes it a suffix; otherwise it may be a `--p…` that was in
        // the path all along
        let rest = name[range.upperBound...]
        guard let first = rest.first, first.isNumber else { return name }
        return String(name[..<range.lowerBound])
    }
}
