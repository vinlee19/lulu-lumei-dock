import Foundation
import EurekaKit

/// Codex session index: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
/// Resumed old sessions append in place under their creation-date dir, so the whole tree is
/// enumerated and then filtered by an mtime window.
/// The official thread_name wins; when missing, fall back to streaming session_meta and the first
/// complete user_message.
public enum CodexSessionIndexer {
    public static func index(
        sessionsRoot: URL,
        threadNameIndexURL: URL? = nil,
        window: TimeInterval = 30 * 86400,
        maxSessions: Int = 300,
        now: Date = Date()
    ) -> [AgentSessionInfo] {
        // window may be .greatestFiniteMagnitude ("show all"), so this must be a plain interval
        // comparison - dividing by 86400 and converting to Int would overflow and crash.
        var candidates: [(URL, Date, UInt64)] = []
        for entry in CodexRolloutFiles.enumerate(sessionsRoot: sessionsRoot) {
            guard let mtime = entry.mtime, now.timeIntervalSince(mtime) < window
            else { continue }
            candidates.append((entry.url, mtime, entry.size))
        }
        candidates.sort { $0.1 > $1.1 }
        let names = CodexThreadNameIndex.load(
            threadNameIndexURL ?? CodexThreadNameIndex.resolvedURL(for: sessionsRoot))
        return candidates.prefix(maxSessions).map { file, mtime, size in
            let head = headInfo(fileURL: file)
            let id = head.id ?? fallbackId(file)
            return AgentSessionInfo(
                source: .codex,
                id: id,
                cwd: head.cwd,
                name: names[id] ?? head.name,
                startedAt: head.startedAt,
                lastActiveAt: mtime,
                sizeBytes: size,
                transcriptPath: file.path
            )
        }
    }

    /// Upper bound in bytes for the head scan.
    ///
    /// **Why it must exist**: the stop condition is "both id and name found", and `name` waits for
    /// the first `event_msg/user_message` - sessions without a user message (subagent / automation
    /// / post-compact sessions, **29** of 121 recent rollouts surveyed) never satisfy it, so **the
    /// whole file gets parsed as JSON line by line**. A single Codex rollout measured up to 70 MB,
    /// and 121 files took 65-145 s in total, while Claude's 94 sessions took 0.4 s - the difference
    /// isn't data volume, it's this.
    ///
    /// 1 MB is enough: `session_meta` is the first line of a rollout (guaranteed by the format;
    /// `CodexRolloutDecoder` relies on it too), and `user_message` is the session's first
    /// utterance. Past the limit we give up on the title, and `AgentSessionInfo.displayName` falls
    /// back to the localized "Session <first 8 of id>" - **exactly the same result as scanning the
    /// whole file**, just without the wasted reads.
    static let headScanLimit = 1 << 20

    /// First-level probe window. In 92 of 121 surveyed rollouts, `session_meta` (line one) and the
    /// first `user_message` both fall within the first 64 KB - read that much and stop once both
    /// are found; only extend to `headScanLimit` otherwise. Saves about 3/4 of the reads;
    /// rescanning those 64 KB costs far less than reading another 960 KB.
    static let headProbeLimit = 64 << 10

    /// Byte-level prefilter markers: **search bytes first, then decide whether to pay for JSON
    /// parsing**. A single rollout line easily runs to hundreds of KB (tool output / file contents
    /// echoed whole), while only two fields are needed here; running `JSONSerialization` on every
    /// line indiscriminately measured about 0.9 s per 1 MB. A false hit (the body happens to
    /// mention these words) just parses one extra line, and the `switch` skips it on mismatch -
    /// harmless.
    private static let metaMarker = Data("session_meta".utf8)
    private static let userMarker = Data("user_message".utf8)

    /// Reads only the file head, **not via `CodexJSONLReader`**: that reader maintains offset
    /// bookkeeping and over-long-line semantics, and for every line copies the remaining buffer
    /// with `Data(buffer[next...])` plus a full `firstIndex` scan; measured throughput is only
    /// about 3.4 MB/s (36 s for 121 files). The need here is much simpler - read a fixed-size head,
    /// split lines, find two fields - so one read + one `split` is enough. (The reader's own O(n^2)
    /// barely affects tailers: they only read newly appended bytes, so the buffer stays small.)
    static func headInfo(fileURL: URL) -> (id: String?, cwd: String?, name: String?, startedAt: Date?) {
        guard let handle = FileHandle(forReadingAtPath: fileURL.path) else {
            return (nil, nil, nil, nil)
        }
        defer { try? handle.close() }
        guard var head = try? handle.read(upToCount: Self.headProbeLimit), !head.isEmpty else {
            return (nil, nil, nil, nil)
        }
        var result = scan(head)
        // First level came up short (very long instructions on line one, or this session has no
        // user_message at all) → extend to the limit and rescan
        if result.id == nil || result.name == nil, head.count == Self.headProbeLimit,
           let more = try? handle.read(upToCount: Self.headScanLimit - Self.headProbeLimit),
           !more.isEmpty {
            head.append(more)
            result = scan(head)
        }
        return result
    }

    /// Finds `session_meta` and the first `user_message` in a chunk of head bytes. Pure function,
    /// so both read levels can reuse it.
    ///
    /// **Line-by-line cursor instead of `split`**: `split` slices out every line up front (hundreds
    /// of slices in 1 MB), while most files are done within the first two lines - the `split`
    /// version measured 30% slower than the cursor version. The cursor resumes the newline search
    /// from its last position, never rescans processed bytes, and stops on a hit.
    private static func scan(
        _ head: Data
    ) -> (id: String?, cwd: String?, name: String?, startedAt: Date?) {
        var id: String?
        var cwd: String?
        var name: String?
        var startedAt: Date?
        var cursor = head.startIndex
        while cursor < head.endIndex {
            let lineEnd = head[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? head.endIndex
            let line = head[cursor..<lineEnd]
            cursor = lineEnd < head.endIndex ? head.index(after: lineEnd) : head.endIndex
            guard !line.isEmpty else { continue }
            // Could this line carry a field we want? If not, skip even the JSON parse.
            let mayHaveMeta = id == nil && line.range(of: Self.metaMarker) != nil
            let mayHaveUser = name == nil && line.range(of: Self.userMarker) != nil
            guard mayHaveMeta || mayHaveUser else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line)),
                let root = object as? [String: Any],
                let payload = root["payload"] as? [String: Any]
            else { continue }
            switch root["type"] as? String {
            case "session_meta":
                // **Only the first one counts**. Resumed / forked rollouts get a second
                // session_meta (observed: `session_meta` appears twice in files over 5 MB);
                // scanning to EOF used to let the later one overwrite `id` with **another session's
                // id** - 121 files yielded only 91 unique ids, and 30 sessions were wrongly merged
                // in the list/index.
                guard id == nil else { break }
                id = payload["id"] as? String
                cwd = payload["cwd"] as? String
                // Newer Codex gives the real start time in payload.timestamp; older ones fall
                // back to the top-level timestamp.
                if let ts = payload["timestamp"] as? String ?? root["timestamp"] as? String {
                    startedAt = ClaudeSessionFirstTimestamp.parse(ts)
                }
            case "event_msg":
                if name == nil, payload["type"] as? String == "user_message",
                   let message = payload["message"] as? String {
                    name = summarizeTitle(message)
                }
            default:
                break
            }
            if id != nil, name != nil { break }
        }
        return (id, cwd, name, startedAt)
    }

    /// rollout-2026-06-08T23-36-02-<uuid>.jsonl → uuid
    private static func fallbackId(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let parts = stem.split(separator: "-")
        return parts.count >= 5 ? parts.suffix(5).joined(separator: "-") : stem
    }
}
