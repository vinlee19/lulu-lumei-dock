import Foundation

/// Streaming complete-line reader for Codex JSONL.
///
/// A rollout's session_meta carries large instructions, so the first line can no longer be assumed
/// to fit a fixed 16/64KB window. Returns the byte offset after the last complete newline, so
/// callers can keep an unfinished half line for the next read.
enum CodexJSONLReader {
    @discardableResult
    static func forEachCompleteLine(
        _ url: URL,
        maxLineBytes: Int = 8 * 1024 * 1024,
        includeTrailingLine: Bool = false,
        _ body: (Data) -> Bool
    ) -> UInt64 {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return 0 }
        defer { try? handle.close() }

        var buffer = Data()
        var consumed: UInt64 = 0
        var skippedBytes: UInt64 = 0
        var droppingOversizeLine = false

        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)

            if droppingOversizeLine {
                guard let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) else {
                    skippedBytes += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)
                    continue
                }
                let next = buffer.index(after: newline)
                skippedBytes += UInt64(buffer.distance(from: buffer.startIndex, to: next))
                consumed += skippedBytes
                skippedBytes = 0
                buffer = Data(buffer[next...])
                droppingOversizeLine = false
            }

            while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[..<newline])
                let next = buffer.index(after: newline)
                let completeBytes = buffer.distance(from: buffer.startIndex, to: next)
                consumed += UInt64(completeBytes)
                buffer = Data(buffer[next...])

                if line.count <= maxLineBytes, !line.isEmpty, !body(line) {
                    return consumed
                }
            }

            if buffer.count > maxLineBytes {
                skippedBytes = UInt64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                droppingOversizeLine = true
            }
        }
        if includeTrailingLine, !droppingOversizeLine,
           !buffer.isEmpty, buffer.count <= maxLineBytes {
            _ = body(buffer)
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
