import Foundation
import EurekaStore

/// Reads JSONL incrementally from an offset: consumes only complete lines, returns the new offset.
/// Truncation / inode change is detected by the caller, which then passes offset=0 to reread.
///
/// Reads are capped at `maxBytes` of complete lines per call. A first scan meets transcripts of
/// 150-220 MB; reading one whole and copying every line held 800 MB at peak, enough to push an
/// 8-16 GB machine into swap on first launch. Callers loop until `reachedEnd`, saving the offset
/// after each slice, which is the same as the file having grown in several appends - the case
/// cross-batch dedup already handles.
enum JSONLinesReader {
    struct Chunk {
        var lines: [Data]
        var newOffset: UInt64
        /// No complete line is left after `newOffset` (a trailing partial line may remain)
        var reachedEnd: Bool
    }

    static let defaultMaxBytes = 16 << 20

    static func read(path: String, from offset: UInt64, maxBytes: Int = defaultMaxBytes) -> Chunk? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > offset,
              (try? handle.seek(toOffset: offset)) != nil
        else { return nil }

        // Read one slice; a single line longer than the slice keeps the read going until its
        // newline (or EOF), so a huge line is never split
        var data = Data()
        var hitEOF = false
        repeat {
            guard let piece = try? handle.read(upToCount: max(1, maxBytes)), !piece.isEmpty else {
                hitEOF = true
                break
            }
            data.append(piece)
            if piece.count < maxBytes { hitEOF = true }
        } while !hitEOF && data.lastIndex(of: UInt8(ascii: "\n")) == nil
        guard !data.isEmpty, let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            return nil
        }

        let complete = data[data.startIndex...lastNewline]
        let lines = complete
            .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            .map { Data($0) }
        let newOffset = offset + UInt64(complete.count)
        return Chunk(lines: lines, newOffset: newOffset, reachedEnd: hitEOF || newOffset >= size)
    }

    static func fileInfo(path: String) -> (inode: Int64, size: UInt64)? {
        var info = Darwin.stat()
        // The C function of the same name is shadowed by the struct; use lstat
        // (transcripts/rollouts are not symlinks)
        guard lstat(path, &info) == 0 else { return nil }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}

/// Drives one file through `JSONLinesReader` slice by slice. Each slice runs in its own
/// autorelease pool (per-line JSON parsing autoreleases bridged objects), and the loop stops as
/// soon as a slice saves no progress, so a scanner that returns early can never spin.
enum ScanSlices {
    static func drain(
        path: String, store: EurekaStore, hasMore: () -> Bool, scan: () throws -> Int
    ) throws -> Int {
        var total = 0
        while true {
            let before = try store.scanState.fileState(path: path)?.offset
            total += try autoreleasepool { try scan() }
            guard hasMore() else { return total }
            let after = try store.scanState.fileState(path: path)?.offset
            guard let after, after != before else { return total }
        }
    }
}
