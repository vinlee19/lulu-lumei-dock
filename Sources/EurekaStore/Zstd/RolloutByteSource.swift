import Foundation

/// Sequential reader for a transcript that may be zstd-compressed (`*.zst`).
///
/// Codex compresses a rollout to `.jsonl.zst` when the session closes, so every reader of rollouts
/// opens them through here (or through `JSONLinesReader`, which does the same), never through a
/// bare `FileHandle`. A compressed file can only be read front to back; offsets are always
/// positions in the decompressed bytes.
public final class RolloutByteSource {
    private let handle: FileHandle?
    private let stream: ZstdStream?

    public static func isCompressed(_ path: String) -> Bool {
        path.hasSuffix(".zst")
    }

    public init?(path: String) {
        if Self.isCompressed(path) {
            guard let stream = ZstdStream(path: path) else { return nil }
            self.stream = stream
            handle = nil
        } else {
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            self.handle = handle
            stream = nil
        }
    }

    deinit { try? handle?.close() }

    /// Up to `count` bytes; empty at the end, nil when the file can't be read or decoded
    public func read(upToCount count: Int) -> Data? {
        if let stream { return try? stream.read(upToCount: count) }
        do {
            return try handle?.read(upToCount: count) ?? Data()
        } catch {
            return nil
        }
    }

    /// Everything from the current position; nil when the file can't be read or decoded
    public func readToEnd() -> Data? {
        if let stream { return try? stream.readToEnd() }
        do {
            return try handle?.readToEnd() ?? Data()
        } catch {
            return nil
        }
    }

    /// Moves past the first `offset` bytes; false when the file is shorter or can't be decoded
    public func skip(to offset: UInt64) -> Bool {
        if let stream { return (try? stream.skip(offset)) == offset }
        guard let handle, (try? handle.seek(toOffset: offset)) != nil else { return false }
        return true
    }

    /// Whole decoded contents (`FileManager.contents(atPath:)` for either kind of file)
    public static func contents(atPath path: String) -> Data? {
        guard isCompressed(path) else { return FileManager.default.contents(atPath: path) }
        return RolloutByteSource(path: path)?.readToEnd()
    }

    /// The file name without `.jsonl` / `.jsonl.zst`
    public static func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        if name.hasSuffix(".zst") { name.removeLast(".zst".count) }
        if name.hasSuffix(".jsonl") { name.removeLast(".jsonl".count) }
        return name
    }
}

/// Decompressed size of a `.zst` file, read from frame headers without decoding.
///
/// Frames carry their content size (every Codex rollout does); a file with a frame that doesn't is
/// reported as unknown, and the scanners then skip it rather than guess. Walking the block headers
/// of a 10 MB file takes a few hundred small reads, so results are cached per (inode, size, mtime).
public enum ZstdFrameInfo {
    private static let lock = NSLock()
    private static var cache: [String: (key: FileKey, size: UInt64?)] = [:]

    private struct FileKey: Equatable {
        let inode: UInt64
        let size: Int64
        let mtime: Int
    }

    public static func contentSize(path: String) -> UInt64? {
        var info = Darwin.stat()
        guard lstat(path, &info) == 0 else { return nil }
        let key = FileKey(
            inode: UInt64(info.st_ino), size: Int64(info.st_size),
            mtime: info.st_mtimespec.tv_sec * 1_000_000_000 + info.st_mtimespec.tv_nsec)
        lock.lock()
        if let hit = cache[path], hit.key == key {
            lock.unlock()
            return hit.size
        }
        lock.unlock()
        let size = walk(path: path)
        lock.lock()
        cache[path] = (key, size)
        lock.unlock()
        return size
    }

    private static func walk(path: String) -> UInt64? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), (try? handle.seek(toOffset: 0)) != nil else {
            return nil
        }
        func bytes(_ count: Int) -> [UInt8]? {
            guard let data = try? handle.read(upToCount: count), data.count == count else {
                return nil
            }
            return [UInt8](data)
        }
        func le(_ raw: ArraySlice<UInt8>) -> UInt64 {
            raw.enumerated().reduce(0) { $0 | UInt64($1.element) << UInt64(8 * $1.offset) }
        }

        var total: UInt64 = 0
        var position: UInt64 = 0
        while position < end {
            guard let magicBytes = bytes(4) else { return nil }
            let magic = UInt32(le(magicBytes[...]))
            position += 4
            if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
                guard let sizeBytes = bytes(4) else { return nil }
                position += 4 + le(sizeBytes[...])
                guard (try? handle.seek(toOffset: position)) != nil else { return nil }
                continue
            }
            guard magic == ZstdStream.frameMagic, let descriptor = bytes(1)?.first else { return nil }
            let singleSegment = descriptor & 0x20 != 0
            let contentBytes = [singleSegment ? 1 : 0, 2, 4, 8][Int(descriptor >> 6)]
            let headerRest = (singleSegment ? 0 : 1) + [0, 1, 2, 4][Int(descriptor & 3)]
                + contentBytes
            guard contentBytes > 0, let header = bytes(headerRest) else { return nil }
            var content = le(header[(headerRest - contentBytes)...])
            if contentBytes == 2 { content += 256 }
            total += content
            position += 1 + UInt64(headerRest)

            var last = false
            while !last {
                guard let blockHeader = bytes(3) else { return nil }
                let value = Int(le(blockHeader[...]))
                last = value & 1 != 0
                let type = (value >> 1) & 3
                let size = UInt64(type == 1 ? 1 : value >> 3)
                position += 3 + size
                guard position <= end, (try? handle.seek(toOffset: position)) != nil else {
                    return nil
                }
            }
            if descriptor & 0x04 != 0 {
                position += 4
                guard position <= end, (try? handle.seek(toOffset: position)) != nil else {
                    return nil
                }
            }
        }
        return total
    }
}
