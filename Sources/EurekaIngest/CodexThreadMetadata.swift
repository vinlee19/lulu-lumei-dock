import Foundation

/// Codex JSONL 的流式完整行读取器。
///
/// rollout 的 session_meta 会携带大段 instructions，不能再假设首行落在固定 16/64KB 窗口内。
/// 返回值是最后一个完整换行后的字节偏移，调用方可保留未写完的半行供下次继续读取。
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

/// Codex 正式线程名索引（`~/.codex/session_index.jsonl`）。
/// 文件是 append-only，同一 id 后出现的记录覆盖旧记录。
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

    /// 测试/自定义 sessions 根默认取同级 Codex home 下的 session_index.jsonl。
    public static func siblingURL(of sessionsRoot: URL) -> URL {
        sessionsRoot.deletingLastPathComponent().appendingPathComponent("session_index.jsonl")
    }

    /// 默认跟随传入 sessions 根；显式 Codex 环境覆盖仍保持一致。
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
