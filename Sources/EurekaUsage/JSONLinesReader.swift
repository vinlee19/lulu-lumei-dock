import Foundation

/// Reads JSONL incrementally from an offset: consumes only complete lines, returns the new offset.
/// Truncation / inode change is detected by the caller, which then passes offset=0 to reread.
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
        // The C function of the same name is shadowed by the struct; use lstat
        // (transcripts/rollouts are not symlinks)
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}
