import Foundation

/// Streaming Zstandard decompressor (RFC 8878), decode only, no dictionaries.
///
/// Codex closes a session by compressing its rollout to `rollout-*.jsonl.zst` (one frame, 2 MiB
/// window, no checksum) and decompresses it again on resume. macOS ships no zstd (Compression has
/// LZ4 / zlib / LZMA / Brotli / LZFSE only) and the app takes no third-party runtime dependency
/// besides Sparkle, so this is a hand-rolled decoder in the spirit of the Parquet writer and the
/// protobuf reader.
///
/// Memory stays bounded: compressed input is read in 1 MiB slices, and only the window (which
/// matches may reach back into) plus the output not yet handed to the caller is kept. A frame whose
/// window exceeds `maxWindowSize` is refused instead of being buffered.
public final class ZstdStream {
    public static let maxWindowSize = 64 << 20
    static let maxBlockSize = 128 << 10
    static let frameMagic: UInt32 = 0xFD2F_B528

    private let handle: FileHandle
    private var input = [UInt8]()
    private var inputPos = 0
    private var inputEOF = false

    /// Decoded bytes: the window first, then output the caller hasn't read yet
    private let history = ZstdHistory()
    private var readIndex = 0
    /// Where the block being decoded started in `history`
    private var blockStart = 0

    private var frame: FrameState?
    private var finished = false

    public init(handle: FileHandle) {
        self.handle = handle
    }

    public convenience init?(path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        self.init(handle: handle)
    }

    deinit { try? handle.close() }

    /// Up to `count` decoded bytes; an empty result means the end of the stream
    public func read(upToCount count: Int) throws -> Data {
        while history.count - readIndex < count, !finished {
            try decodeNext()
        }
        let available = min(count, history.count - readIndex)
        let data = history.data(from: readIndex, count: available)
        readIndex += available
        compact()
        return data
    }

    /// Decodes and discards up to `count` bytes; returns how many were skipped
    @discardableResult
    public func skip(_ count: UInt64) throws -> UInt64 {
        var skipped: UInt64 = 0
        while skipped < count {
            if history.count == readIndex {
                if finished { break }
                try decodeNext()
                continue
            }
            let step = min(UInt64(history.count - readIndex), count - skipped)
            readIndex += Int(step)
            skipped += step
            compact()
        }
        return skipped
    }

    /// Every remaining decoded byte
    public func readToEnd() throws -> Data {
        var out = Data()
        while true {
            let piece = try read(upToCount: 1 << 20)
            if piece.isEmpty { return out }
            out.append(piece)
        }
    }

    /// Drops history that is both delivered and outside the window
    private func compact() {
        let keep = frame?.windowSize ?? 0
        let droppable = min(readIndex, history.count - keep)
        // Shift only once a sizable prefix is dead, so the copy amortizes
        guard droppable > max(keep, 1 << 20) else { return }
        history.dropFirst(droppable)
        readIndex -= droppable
    }

    // MARK: - Input

    private func ensureInput(_ count: Int) throws -> Bool {
        while input.count - inputPos < count {
            if inputEOF { return false }
            if inputPos > 0 {
                input.removeFirst(inputPos)
                inputPos = 0
            }
            let chunk = (try? handle.read(upToCount: 1 << 20)) ?? Data()
            if chunk.isEmpty {
                inputEOF = true
            } else {
                input.append(contentsOf: chunk)
            }
        }
        return true
    }

    private func requireInput(_ count: Int) throws {
        guard try ensureInput(count) else { throw ZstdError.truncated }
    }

    private func takeByte() throws -> UInt8 {
        try requireInput(1)
        defer { inputPos += 1 }
        return input[inputPos]
    }

    private func takeLE(_ count: Int) throws -> UInt64 {
        try requireInput(count)
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(input[inputPos + i]) << UInt64(8 * i)
        }
        inputPos += count
        return value
    }

    // MARK: - Frames

    private struct FrameState {
        var windowSize: Int
        var contentSize: UInt64?
        var hasChecksum: Bool
        var produced: UInt64 = 0
        var huffman: ZstdHuffmanTable?
        var literalLengths: ZstdFSETable?
        var offsets: ZstdFSETable?
        var matchLengths: ZstdFSETable?
        var repeats: (Int, Int, Int) = (1, 4, 8)
    }

    private func decodeNext() throws {
        if frame == nil {
            guard try beginFrame() else {
                finished = true
                return
            }
            return
        }
        try decodeBlock()
    }

    /// Reads the next frame header; false at a clean end of input
    private func beginFrame() throws -> Bool {
        guard try ensureInput(4) else {
            if input.count - inputPos > 0 { throw ZstdError.truncated }
            return false
        }
        let magic = UInt32(try takeLE(4))
        if magic & 0xFFFF_FFF0 == 0x184D_2A50 {
            let size = Int(try takeLE(4))
            try requireInput(size)
            inputPos += size
            return true
        }
        guard magic == Self.frameMagic else { throw ZstdError.corrupt("bad frame magic") }

        let descriptor = try takeByte()
        let contentSizeFlag = Int(descriptor >> 6)
        let singleSegment = descriptor & 0x20 != 0
        guard descriptor & 0x08 == 0 else { throw ZstdError.corrupt("reserved frame bit set") }
        let hasChecksum = descriptor & 0x04 != 0
        let dictionaryFlag = Int(descriptor & 0x03)

        var windowSize = 0
        if !singleSegment {
            let window = try takeByte()
            let windowLog = 10 + Int(window >> 3)
            guard windowLog <= 31 else { throw ZstdError.corrupt("window too large") }
            let base = 1 << windowLog
            windowSize = base + (base / 8) * Int(window & 0x07)
        }
        let dictionaryBytes = [0, 1, 2, 4][dictionaryFlag]
        if dictionaryBytes > 0, try takeLE(dictionaryBytes) != 0 {
            throw ZstdError.unsupported("dictionary frame")
        }
        let contentBytes = [singleSegment ? 1 : 0, 2, 4, 8][contentSizeFlag]
        var contentSize: UInt64?
        if contentBytes > 0 {
            var value = try takeLE(contentBytes)
            if contentBytes == 2 { value += 256 }
            contentSize = value
        }
        if singleSegment { windowSize = Int(clamping: contentSize ?? 0) }
        guard windowSize <= Self.maxWindowSize else {
            throw ZstdError.unsupported("window of \(windowSize) bytes")
        }
        frame = FrameState(windowSize: windowSize, contentSize: contentSize, hasChecksum: hasChecksum)
        return true
    }

    private func endFrame() throws {
        guard let state = frame else { return }
        if let expected = state.contentSize, expected != state.produced {
            throw ZstdError.corrupt("frame size mismatch")
        }
        if state.hasChecksum {
            // The XXH64 checksum is skipped, not verified
            try requireInput(4)
            inputPos += 4
        }
        frame = nil
    }

    // MARK: - Blocks

    private func decodeBlock() throws {
        let header = Int(try takeLE(3))
        let last = header & 1 != 0
        let type = (header >> 1) & 3
        let size = header >> 3
        blockStart = history.count
        switch type {
        case 0:
            try requireInput(size)
            input.withUnsafeBufferPointer { buffer in
                history.append(UnsafeBufferPointer(rebasing: buffer[inputPos..<(inputPos + size)]))
            }
            inputPos += size
        case 1:
            history.appendRepeated(try takeByte(), count: size)
        case 2:
            guard size <= Self.maxBlockSize else { throw ZstdError.corrupt("block too large") }
            try requireInput(size)
            let block = Array(input[inputPos..<(inputPos + size)])
            inputPos += size
            try block.withUnsafeBufferPointer { try decodeCompressed($0) }
        default:
            throw ZstdError.corrupt("reserved block type")
        }
        frame!.produced += UInt64(history.count - blockStart)
        if let expected = frame!.contentSize, frame!.produced > expected {
            throw ZstdError.corrupt("frame larger than declared")
        }
        if last { try endFrame() }
    }

    private var literals = [UInt8](repeating: 0, count: maxBlockSize)

    private func decodeCompressed(_ block: UnsafeBufferPointer<UInt8>) throws {
        let (literalCount, consumed) = try decodeLiterals(block)
        try decodeSequences(
            UnsafeBufferPointer(rebasing: block[consumed...]), literalCount: literalCount)
    }

    /// Decodes the literals section into `literals`; returns the literal count and section size
    private func decodeLiterals(_ block: UnsafeBufferPointer<UInt8>) throws -> (Int, Int) {
        guard let first = block.first else { throw ZstdError.corrupt("empty block") }
        let type = Int(first & 3)
        let sizeFormat = Int(first >> 2) & 3
        func byte(_ i: Int) throws -> Int {
            guard i < block.count else { throw ZstdError.corrupt("literals header truncated") }
            return Int(block[i])
        }

        if type == 0 || type == 1 {
            var headerSize = 1
            var regenerated = Int(first >> 3)
            if sizeFormat == 1 {
                headerSize = 2
                regenerated = Int(first >> 4) + (try byte(1) << 4)
            } else if sizeFormat == 3 {
                headerSize = 3
                regenerated = Int(first >> 4) + (try byte(1) << 4) + (try byte(2) << 12)
            }
            guard regenerated <= Self.maxBlockSize else { throw ZstdError.corrupt("literals too long") }
            if type == 0 {
                guard block.count >= headerSize + regenerated else { throw ZstdError.truncated }
                for i in 0..<regenerated { literals[i] = block[headerSize + i] }
                return (regenerated, headerSize + regenerated)
            }
            let value = UInt8(try byte(headerSize))
            for i in 0..<regenerated { literals[i] = value }
            return (regenerated, headerSize + 1)
        }

        let headerSize = [3, 3, 4, 5][sizeFormat]
        let fieldBits = [10, 10, 14, 18][sizeFormat]
        var header = 0
        for i in 0..<headerSize { header |= try byte(i) << (8 * i) }
        let mask = (1 << fieldBits) - 1
        let regenerated = (header >> 4) & mask
        let compressed = (header >> (4 + fieldBits)) & mask
        let streams = sizeFormat == 0 ? 1 : 4
        guard regenerated <= Self.maxBlockSize, block.count >= headerSize + compressed else {
            throw ZstdError.corrupt("literals section out of bounds")
        }
        var body = UnsafeBufferPointer(rebasing: block[headerSize..<(headerSize + compressed)])
        if type == 2 {
            let (table, used) = try ZstdHuffmanTable.read(body)
            frame!.huffman = table
            body = UnsafeBufferPointer(rebasing: body[used...])
        }
        guard let table = frame!.huffman else { throw ZstdError.corrupt("treeless literals without a table") }

        try literals.withUnsafeMutableBufferPointer { out in
            let base = out.baseAddress!
            if streams == 1 {
                try table.decode(body, into: base, count: regenerated)
                return
            }
            guard body.count >= 6 else { throw ZstdError.corrupt("jump table truncated") }
            let s1 = Int(body[0]) | Int(body[1]) << 8
            let s2 = Int(body[2]) | Int(body[3]) << 8
            let s3 = Int(body[4]) | Int(body[5]) << 8
            let s4 = body.count - 6 - s1 - s2 - s3
            guard s4 > 0 else { throw ZstdError.corrupt("bad jump table") }
            let each = (regenerated + 3) / 4
            guard regenerated >= 3 * each else { throw ZstdError.corrupt("too few literals for 4 streams") }
            var start = 6
            var written = 0
            for (index, size) in [s1, s2, s3, s4].enumerated() {
                let count = index == 3 ? regenerated - 3 * each : each
                try table.decode(
                    UnsafeBufferPointer(rebasing: body[start..<(start + size)]),
                    into: base + written, count: count)
                start += size
                written += count
            }
        }
        return (regenerated, headerSize + compressed)
    }

    private func decodeSequences(_ section: UnsafeBufferPointer<UInt8>, literalCount: Int) throws {
        guard let first = section.first else { throw ZstdError.corrupt("sequences header missing") }
        var pos = 1
        func byte() throws -> Int {
            guard pos < section.count else { throw ZstdError.corrupt("sequences header truncated") }
            defer { pos += 1 }
            return Int(section[pos])
        }
        var count = Int(first)
        if count >= 128 {
            if count < 255 {
                count = ((count - 128) << 8) + (try byte())
            } else {
                count = (try byte()) + ((try byte()) << 8) + 0x7F00
            }
        }
        if count == 0 {
            guard pos == section.count else { throw ZstdError.corrupt("trailing bytes after literals") }
            literals.withUnsafeBufferPointer {
                history.append(UnsafeBufferPointer(rebasing: $0[0..<literalCount]))
            }
            return
        }

        let modes = try byte()
        guard modes & 3 == 0 else { throw ZstdError.corrupt("reserved sequence mode bits") }
        func table(
            mode: Int, current: ZstdFSETable?, predefined: ZstdFSETable, maxSymbol: Int, maxLog: Int
        ) throws -> ZstdFSETable {
            switch mode {
            case 0:
                return predefined
            case 1:
                let symbol = try byte()
                guard symbol <= maxSymbol else { throw ZstdError.corrupt("RLE symbol out of range") }
                return .rle(UInt8(symbol))
            case 2:
                let (built, used) = try ZstdFSETable.read(
                    UnsafeBufferPointer(rebasing: section[pos...]),
                    maxSymbol: maxSymbol, maxAccuracyLog: maxLog)
                pos += used
                return built
            default:
                guard let current else { throw ZstdError.corrupt("repeat mode without a table") }
                return current
            }
        }
        let llTable = try table(
            mode: modes >> 6, current: frame!.literalLengths,
            predefined: ZstdSequenceCodes.literalLengthTable, maxSymbol: 35, maxLog: 9)
        let ofTable = try table(
            mode: (modes >> 4) & 3, current: frame!.offsets,
            predefined: ZstdSequenceCodes.offsetTable, maxSymbol: 31, maxLog: 8)
        let mlTable = try table(
            mode: (modes >> 2) & 3, current: frame!.matchLengths,
            predefined: ZstdSequenceCodes.matchLengthTable, maxSymbol: 52, maxLog: 9)
        frame!.literalLengths = llTable
        frame!.offsets = ofTable
        frame!.matchLengths = mlTable

        var stream = try ZstdBackwardBits(UnsafeBufferPointer(rebasing: section[pos...]))
        var llState = Int(stream.read(llTable.accuracyLog))
        var ofState = Int(stream.read(ofTable.accuracyLog))
        var mlState = Int(stream.read(mlTable.accuracyLog))
        var reps = frame!.repeats
        var literalPos = 0

        try literals.withUnsafeBufferPointer { lits in
            for index in 0..<count {
                let ofCode = Int(ofTable.symbol[ofState])
                let llCode = Int(llTable.symbol[llState])
                let mlCode = Int(mlTable.symbol[mlState])
                guard ofCode <= 31, llCode <= 35, mlCode <= 52 else {
                    throw ZstdError.corrupt("sequence code out of range")
                }
                let offsetValue = (1 << ofCode) + Int(stream.read(ofCode))
                let matchLength = Int(ZstdSequenceCodes.matchLengthBase[mlCode])
                    + Int(stream.read(Int(ZstdSequenceCodes.matchLengthBits[mlCode])))
                let literalLength = Int(ZstdSequenceCodes.literalLengthBase[llCode])
                    + Int(stream.read(Int(ZstdSequenceCodes.literalLengthBits[llCode])))

                var offset: Int
                if offsetValue > 3 {
                    offset = offsetValue - 3
                    reps = (offset, reps.0, reps.1)
                } else {
                    let repeatIndex = literalLength == 0 ? offsetValue + 1 : offsetValue
                    switch repeatIndex {
                    case 1:
                        offset = reps.0
                    case 2:
                        offset = reps.1
                        reps = (offset, reps.0, reps.2)
                    case 3:
                        offset = reps.2
                        reps = (offset, reps.0, reps.1)
                    default:
                        offset = reps.0 - 1
                        guard offset > 0 else { throw ZstdError.corrupt("zero repeat offset") }
                        reps = (offset, reps.0, reps.1)
                    }
                }

                guard literalPos + literalLength <= literalCount else {
                    throw ZstdError.corrupt("sequence reads past the literals")
                }
                history.append(UnsafeBufferPointer(
                    rebasing: lits[literalPos..<(literalPos + literalLength)]))
                literalPos += literalLength
                guard offset <= referenceableBytes() else {
                    throw ZstdError.corrupt("match offset beyond the window")
                }
                history.copyMatch(offset: offset, length: matchLength)

                if index < count - 1 {
                    llState = Int(llTable.baseline[llState])
                        + Int(stream.read(Int(llTable.nbBits[llState])))
                    mlState = Int(mlTable.baseline[mlState])
                        + Int(stream.read(Int(mlTable.nbBits[mlState])))
                    ofState = Int(ofTable.baseline[ofState])
                        + Int(stream.read(Int(ofTable.nbBits[ofState])))
                }
            }
            guard stream.position == 0 else {
                throw ZstdError.corrupt("sequence stream not fully consumed")
            }
            history.append(UnsafeBufferPointer(rebasing: lits[literalPos..<literalCount]))
        }
        frame!.repeats = reps
    }

    /// How many bytes of the current frame `history` still holds: a match may reach back into the
    /// current frame only, and never past what compaction kept
    private func referenceableBytes() -> Int {
        let frameBytes = Int(clamping: frame!.produced) + (history.count - blockStart)
        return min(history.count, frameBytes)
    }
}

/// Growable byte buffer with raw-pointer copies: appending a slice of a Swift array to the same
/// array would copy the whole buffer on every match.
final class ZstdHistory {
    private var storage = UnsafeMutablePointer<UInt8>.allocate(capacity: 1 << 20)
    private var capacity = 1 << 20
    private(set) var count = 0

    private func reserve(_ extra: Int) {
        guard count + extra > capacity else { return }
        var newCapacity = capacity * 2
        while newCapacity < count + extra { newCapacity *= 2 }
        let grown = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        grown.update(from: storage, count: count)
        storage.deallocate()
        storage = grown
        capacity = newCapacity
    }

    func append(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard let base = bytes.baseAddress, bytes.count > 0 else { return }
        reserve(bytes.count)
        (storage + count).update(from: base, count: bytes.count)
        count += bytes.count
    }

    func appendRepeated(_ byte: UInt8, count n: Int) {
        reserve(n)
        (storage + count).initialize(repeating: byte, count: n)
        count += n
    }

    /// Copies `length` bytes starting `offset` back; overlapping copies repeat the pattern
    func copyMatch(offset: Int, length: Int) {
        reserve(length)
        let source = storage + (count - offset)
        let target = storage + count
        if offset >= length {
            target.update(from: source, count: length)
        } else {
            for i in 0..<length { target[i] = source[i] }
        }
        count += length
    }

    func data(from start: Int, count n: Int) -> Data {
        Data(bytes: storage + start, count: n)
    }

    func dropFirst(_ n: Int) {
        memmove(storage, storage + n, count - n)
        count -= n
    }

    deinit { storage.deallocate() }
}
