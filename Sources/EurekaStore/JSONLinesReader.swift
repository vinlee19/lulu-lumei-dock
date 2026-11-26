import Foundation

/// Reads JSONL incrementally from an offset: consumes only complete lines, returns the new offset.
/// Truncation / inode change is detected by the caller, which then passes offset=0 to reread.
/// Shared by the usage scanners (EurekaUsage) and the audit scanners (EurekaIngest).
///
/// Reads are capped at `maxBytes` of complete lines per call. A first scan meets transcripts of
/// 150-220 MB; reading one whole and copying every line held 800 MB at peak, enough to push an
/// 8-16 GB machine into swap on first launch. Callers loop until `reachedEnd`, saving the offset
/// after each slice, which is the same as the file having grown in several appends - the case
/// cross-batch dedup already handles.
public enum JSONLinesReader {
    public struct Chunk {
        public var lines: [Data]
        public var newOffset: UInt64
        /// No complete line is left after `newOffset` (a trailing partial line may remain)
        public var reachedEnd: Bool
    }

    public static let defaultMaxBytes = 16 << 20

    /// A `.zst` file is read through `RolloutByteSource`: `offset` and the sizes are positions in
    /// the decompressed bytes, and reaching `offset` means decoding everything before it (the file
    /// never changes once compressed, so callers resume past it at most a few times).
    public static func read(path: String, from offset: UInt64, maxBytes: Int = defaultMaxBytes) -> Chunk? {
        let size: UInt64
        let readPiece: (Int) -> Data?
        var plainHandle: FileHandle?
        defer { try? plainHandle?.close() }
        if RolloutByteSource.isCompressed(path) {
            guard let contentSize = ZstdFrameInfo.contentSize(path: path), contentSize > offset,
                  let source = RolloutByteSource(path: path), source.skip(to: offset)
            else { return nil }
            size = contentSize
            readPiece = { source.read(upToCount: $0) }
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            plainHandle = handle
            guard let end = try? handle.seekToEnd(), end > offset,
                  (try? handle.seek(toOffset: offset)) != nil
            else { return nil }
            size = end
            readPiece = { try? handle.read(upToCount: $0) }
        }

        // Read one slice; a single line longer than the slice keeps the read going until its
        // newline (or EOF), so a huge line is never split
        var data = Data()
        var hitEOF = false
        repeat {
            guard let piece = readPiece(max(1, maxBytes)), !piece.isEmpty else {
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

    /// Inode and size; for a `.zst` file the size is the decompressed size (nil when the frames
    /// don't declare it), so it compares against the same offsets `read` returns
    public static func fileInfo(path: String) -> (inode: Int64, size: UInt64)? {
        var info = Darwin.stat()
        // The C function of the same name is shadowed by the struct; use lstat
        // (transcripts/rollouts are not symlinks)
        guard lstat(path, &info) == 0 else { return nil }
        if RolloutByteSource.isCompressed(path) {
            guard let size = ZstdFrameInfo.contentSize(path: path) else { return nil }
            return (Int64(info.st_ino), size)
        }
        return (Int64(info.st_ino), UInt64(info.st_size))
    }
}

/// Drives one file through `JSONLinesReader` slice by slice. Each slice runs in its own
/// autorelease pool (per-line JSON parsing autoreleases bridged objects), and the loop stops as
/// soon as a slice saves no progress, so a scanner that returns early can never spin.
public enum ScanSlices {
    /// `stateKey` is the scan_files key the scanner saves its offset under (the transcript path,
    /// or `audit://<path>` for the audit scanners)
    public static func drain(
        stateKey: String, store: EurekaStore, hasMore: () -> Bool, scan: () throws -> Int
    ) throws -> Int {
        var total = 0
        while true {
            let before = try store.scanState.fileState(path: stateKey)?.offset
            total += try autoreleasepool { try scan() }
            guard hasMore() else { return total }
            let after = try store.scanState.fileState(path: stateKey)?.offset
            guard let after, after != before else { return total }
        }
    }
}
