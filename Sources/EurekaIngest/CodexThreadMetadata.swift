import Foundation

/// Streaming complete-line reader for Codex JSONL.
///
/// A rollout's session_meta carries large instructions, so the first line can no longer be assumed
/// to fit a fixed 16/64KB window. Returns the byte offset after the last complete newline, so
/// callers can keep an unfinished half line for the next read.
enum CodexJSONLReader {
    /// Lines are sliced out by index and the buffer is compacted once per chunk. The previous
    /// version re-copied the rest of the buffer after every line and re-searched long lines from
    /// their start on every chunk, which measured ~3.4 MB/s; first-install Plans and session
    /// discovery walk whole rollout histories through here.
    @discardableResult
    static func forEachCompleteLine(
        _ url: URL,
        maxLineBytes: Int = 8 * 1024 * 1024,
        includeTrailingLine: Bool = false,
        _ body: (Data) -> Bool
    ) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return 0 }
        defer { try? handle.close() }

        let newline = UInt8(ascii: "\n")
        var buffer = Data()
        var lineStart = 0   // start of the pending line in buffer
        var scanFrom = 0    // bytes before this have been searched for a newline already
        var consumed: UInt64 = 0
        var skippedBytes: UInt64 = 0
        var droppingOversizeLine = false

        func nextNewline(from start: Int) -> Int? {
            guard start < buffer.count else { return nil }
            return buffer.withUnsafeBytes { raw -> Int? in
                guard let base = raw.baseAddress,
                      let hit = memchr(base + start, Int32(newline), raw.count - start)
                else { return nil }
                return base.distance(to: UnsafeRawPointer(hit))
            }
        }

        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            buffer.append(chunk)

            if droppingOversizeLine {
                guard let end = nextNewline(from: scanFrom) else {
                    skippedBytes += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    scanFrom = 0
                    continue
                }
                skippedBytes += UInt64(end + 1)
                consumed += skippedBytes
                skippedBytes = 0
                lineStart = end + 1
                scanFrom = lineStart
                droppingOversizeLine = false
            }

            while let end = nextNewline(from: max(scanFrom, lineStart)) {
                let line = Data(buffer[lineStart..<end])
                consumed += UInt64(end + 1 - lineStart)
                lineStart = end + 1
                scanFrom = lineStart
                if line.count <= maxLineBytes, !line.isEmpty, !body(line) {
                    return consumed
                }
            }
            scanFrom = buffer.count

            // Compact once per chunk: keep only the pending partial line
            if lineStart > 0 {
                buffer.removeSubrange(0..<lineStart)
                scanFrom -= lineStart
                lineStart = 0
            }
            if buffer.count > maxLineBytes {
                skippedBytes = UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                scanFrom = 0
                droppingOversizeLine = true
            }
        }
        if includeTrailingLine, !droppingOversizeLine,
           !buffer.isEmpty, buffer.count <= maxLineBytes {
            _ = body(Data(buffer))
            consumed += UInt64(buffer.count)
        }
        return consumed
    }
}

/// Codex formal thread-name index (`~/.codex/session_index.jsonl`). The file is append-only; a
/// later record for the same id overrides earlier ones.
public enum CodexThreadNameIndex {
    public static func defaultURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEX_SESSION_INDEX"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let customHome = environment["EUREKA_CODEX_HOME"], !customHome.isEmpty {
            return URL(fileURLWithPath: customHome, isDirectory: true)
                .appendingPathComponent("session_index.jsonl")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/session_index.jsonl")
    }

    /// For tests / custom sessions roots, defaults to session_index.jsonl in the sibling Codex
    /// home.
    public static func siblingURL(of sessionsRoot: URL) -> URL {
        sessionsRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    /// Follows the given sessions root by default; an explicit Codex environment override stays
    /// consistent.
    public static func resolvedURL(
        for sessionsRoot: URL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let custom = environment["EUREKA_CODEX_SESSION_INDEX"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        if let customHome = environment["EUREKA_CODEX_HOME"], !customHome.isEmpty {
            return URL(fileURLWithPath: customHome, isDirectory: true)
                .appendingPathComponent("session_index.jsonl")
        }
        return siblingURL(of: sessionsRoot)
    }

    public static func load(_ url: URL) -> [String: String] {
        var names: [String: String] = [:]
        CodexJSONLReader.forEachCompleteLine(url, includeTrailingLine: true) { line in
            guard let root = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = root["id"] as? String
            else { return true }
            let name = (root["thread_name"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let name, !name.isEmpty {
                names[id] = name
            } else {
                names.removeValue(forKey: id)
            }
            return true
        }
        return names
    }
}
