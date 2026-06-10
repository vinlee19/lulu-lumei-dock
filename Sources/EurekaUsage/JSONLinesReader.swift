import Foundation

/// 按 offset 增量读取 JSONL：只消费完整行，返回新 offset。
/// 文件被截断/换 inode 由调用方判定后传 offset=0 重读。
enum JSONLinesReader {
    struct Chunk {
        var lines: [Data]
        var newOffset: UInt64
    }

    static func read(path: String, from offset: UInt64) -> Chunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset else { return nil }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty
        else { return nil }

        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return nil }
        let complete = data[data.startIndex...lastNewline]
        let lines = complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        return Chunk(lines: lines, newOffset: offset + UInt64(complete.count))
    }

    static func fileInfo(path: String) -> (inode: Int64, size: UInt64)? {
        var info = Darwin.stat()
        // 同名 C 函数被 struct 遮蔽，用 lstat（transcript/rollout 不是符号链接）
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}
