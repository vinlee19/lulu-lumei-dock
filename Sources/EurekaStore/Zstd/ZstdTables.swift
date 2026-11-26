import Foundation

/// A finite state entropy decoding table (RFC 8878, section 4.1).
struct ZstdFSETable {
    var symbol: [UInt8]
    var nbBits: [UInt8]
    var baseline: [UInt16]
    let accuracyLog: Int

    /// The single-symbol table of the RLE compression mode: state 0 forever, no bits read
    static func rle(_ symbol: UInt8) -> ZstdFSETable {
        ZstdFSETable(symbol: [symbol], nbBits: [0], baseline: [0], accuracyLog: 0)
    }

    /// Builds the decoding table from normalized counts (-1 means "less than one")
    init(normalized: [Int], accuracyLog: Int) throws {
        let size = 1 << accuracyLog
        self.accuracyLog = accuracyLog
        symbol = [UInt8](repeating: 0, count: size)
        nbBits = [UInt8](repeating: 0, count: size)
        baseline = [UInt16](repeating: 0, count: size)

        var next = [Int](repeating: 0, count: normalized.count)
        var high = size - 1
        for (s, count) in normalized.enumerated() where count == -1 {
            guard high >= 0 else { throw ZstdError.corrupt("FSE table overflow") }
            symbol[high] = UInt8(s)
            high -= 1
            next[s] = 1
        }
        let step = (size >> 1) + (size >> 3) + 3
        let mask = size - 1
        var position = 0
        for (s, count) in normalized.enumerated() where count > 0 {
            next[s] = count
            for _ in 0..<count {
                symbol[position] = UInt8(s)
                repeat { position = (position + step) & mask } while position > high
            }
        }
        guard position == 0 else { throw ZstdError.corrupt("FSE counts don't fill the table") }
        for state in 0..<size {
            let s = Int(symbol[state])
            let nextState = next[s]
            next[s] += 1
            let bits = accuracyLog - (Int.bitWidth - 1 - nextState.leadingZeroBitCount)
            guard bits >= 0 else { throw ZstdError.corrupt("FSE state out of range") }
            nbBits[state] = UInt8(bits)
            baseline[state] = UInt16((nextState << bits) - size)
        }
    }

    private init(symbol: [UInt8], nbBits: [UInt8], baseline: [UInt16], accuracyLog: Int) {
        self.symbol = symbol
        self.nbBits = nbBits
        self.baseline = baseline
        self.accuracyLog = accuracyLog
    }

    /// Reads an FSE table description; returns the table and how many bytes the description took
    static func read(
        _ input: UnsafeBufferPointer<UInt8>, maxSymbol: Int, maxAccuracyLog: Int
    ) throws -> (ZstdFSETable, Int) {
        var bits = ZstdForwardBits(input)
        let accuracyLog = Int(bits.read(4)) + 5
        guard accuracyLog <= maxAccuracyLog else {
            throw ZstdError.corrupt("FSE accuracy log \(accuracyLog) too large")
        }
        var remaining = (1 << accuracyLog) + 1
        var threshold = 1 << accuracyLog
        var width = accuracyLog + 1
        var counts: [Int] = []
        var previousZero = false
        while remaining > 1 && counts.count <= maxSymbol {
            if previousZero {
                var repeats: Int
                repeat {
                    repeats = Int(bits.read(2))
                    counts.append(contentsOf: repeatElement(0, count: repeats))
                } while repeats == 3
                guard counts.count <= maxSymbol + 1 else {
                    throw ZstdError.corrupt("FSE zero run past the last symbol")
                }
                previousZero = false
                if counts.count > maxSymbol { break }
            }
            let maxValue = (2 * threshold - 1) - remaining
            var value: Int
            let low = Int(bits.peek(width - 1))
            if low < maxValue {
                value = low
                bits.skip(width - 1)
            } else {
                value = Int(bits.peek(width))
                if value >= threshold { value -= maxValue }
                bits.skip(width)
            }
            let count = value - 1
            remaining -= count < 0 ? -count : count
            counts.append(count)
            previousZero = count == 0
            while remaining < threshold {
                width -= 1
                threshold >>= 1
            }
        }
        guard remaining == 1, bits.bytesConsumed <= input.count else {
            throw ZstdError.corrupt("invalid FSE table description")
        }
        return (try ZstdFSETable(normalized: counts, accuracyLog: accuracyLog), bits.bytesConsumed)
    }
}

/// A Huffman decoding table indexed by the next `maxBits` bits (RFC 8878, section 4.2)
struct ZstdHuffmanTable {
    var symbol: [UInt8]
    var nbBits: [UInt8]
    let maxBits: Int

    /// Builds the table from per-symbol weights; the last symbol's weight is implied
    init(weights partial: [UInt8]) throws {
        guard !partial.isEmpty, partial.count < 256 else {
            throw ZstdError.corrupt("bad Huffman weight count")
        }
        var total = 0
        for w in partial where w > 0 {
            guard w <= 11 else { throw ZstdError.corrupt("Huffman weight too large") }
            total += 1 << (Int(w) - 1)
        }
        guard total > 0 else { throw ZstdError.corrupt("all Huffman weights are zero") }
        let maxBits = Int.bitWidth - total.leadingZeroBitCount
        guard maxBits <= 11 else { throw ZstdError.corrupt("Huffman code too long") }
        let leftover = (1 << maxBits) - total
        guard leftover > 0, leftover & (leftover - 1) == 0 else {
            throw ZstdError.corrupt("Huffman weights don't complete a tree")
        }
        var weights = partial
        weights.append(UInt8(leftover.trailingZeroBitCount + 1))

        self.maxBits = maxBits
        let size = 1 << maxBits
        symbol = [UInt8](repeating: 0, count: size)
        nbBits = [UInt8](repeating: 0, count: size)
        // Codes are assigned in ascending order of weight, then of symbol
        var position = 0
        for weight in 1...maxBits {
            let span = 1 << (weight - 1)
            let bits = UInt8(maxBits + 1 - weight)
            for (s, w) in weights.enumerated() where Int(w) == weight {
                for i in position..<(position + span) {
                    symbol[i] = UInt8(s)
                    nbBits[i] = bits
                }
                position += span
            }
        }
        guard position == size else { throw ZstdError.corrupt("Huffman table incomplete") }
    }

    /// Reads a Huffman tree description; returns the table and how many bytes it took
    static func read(_ input: UnsafeBufferPointer<UInt8>) throws -> (ZstdHuffmanTable, Int) {
        guard let header = input.first else { throw ZstdError.truncated }
        var weights: [UInt8] = []
        let used: Int
        if header >= 128 {
            let count = Int(header) - 127
            let bytes = (count + 1) / 2
            guard input.count >= 1 + bytes else { throw ZstdError.truncated }
            for i in 0..<count {
                let byte = input[1 + i / 2]
                weights.append(i % 2 == 0 ? byte >> 4 : byte & 0x0F)
            }
            used = 1 + bytes
        } else {
            let size = Int(header)
            guard input.count >= 1 + size else { throw ZstdError.truncated }
            let body = UnsafeBufferPointer(rebasing: input[1..<(1 + size)])
            let (table, tableBytes) = try ZstdFSETable.read(body, maxSymbol: 255, maxAccuracyLog: 6)
            guard tableBytes < size else { throw ZstdError.corrupt("Huffman weights missing") }
            var stream = try ZstdBackwardBits(UnsafeBufferPointer(rebasing: body[tableBytes...]))
            var state1 = Int(stream.read(table.accuracyLog))
            var state2 = Int(stream.read(table.accuracyLog))
            // Two interleaved states; once the stream is overread the other state emits the
            // final symbol
            while true {
                weights.append(table.symbol[state1])
                state1 = Int(table.baseline[state1]) + Int(stream.read(Int(table.nbBits[state1])))
                if stream.position < 0 {
                    weights.append(table.symbol[state2])
                    break
                }
                weights.append(table.symbol[state2])
                state2 = Int(table.baseline[state2]) + Int(stream.read(Int(table.nbBits[state2])))
                if stream.position < 0 {
                    weights.append(table.symbol[state1])
                    break
                }
                guard weights.count < 255 else { throw ZstdError.corrupt("too many Huffman weights") }
            }
            used = 1 + size
        }
        return (try ZstdHuffmanTable(weights: weights), used)
    }

    /// Decodes one Huffman stream into `out[start..<start+count]`
    func decode(
        _ input: UnsafeBufferPointer<UInt8>, into out: UnsafeMutablePointer<UInt8>, count: Int
    ) throws {
        var stream = try ZstdBackwardBits(input)
        try symbol.withUnsafeBufferPointer { symbols in
            try nbBits.withUnsafeBufferPointer { lengths in
                for i in 0..<count {
                    let index = Int(stream.peek(maxBits))
                    out[i] = symbols[index]
                    stream.skip(Int(lengths[index]))
                }
                guard stream.position == 0 else {
                    throw ZstdError.corrupt("Huffman stream not fully consumed")
                }
            }
        }
    }
}

/// Literal length / match length / offset code tables and predefined distributions
/// (RFC 8878, sections 3.1.1.3.2.1 and 3.1.1.3.2.2)
enum ZstdSequenceCodes {
    static let literalLengthBase: [UInt32] = [
        0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
        16, 18, 20, 22, 24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
        8192, 16384, 32768, 65536,
    ]
    static let literalLengthBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
        13, 14, 15, 16,
    ]
    static let matchLengthBase: [UInt32] = [
        3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18,
        19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34,
        35, 37, 39, 41, 43, 47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
        4099, 8195, 16387, 32771, 65539,
    ]
    static let matchLengthBits: [UInt8] = [
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        1, 1, 1, 1, 2, 2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
        12, 13, 14, 15, 16,
    ]

    static let literalLengthDefault: [Int] = [
        4, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
        2, 2, 2, 2, 2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
        -1, -1, -1, -1,
    ]
    static let matchLengthDefault: [Int] = [
        1, 4, 3, 2, 2, 2, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
        -1, -1, -1, -1, -1,
    ]
    static let offsetDefault: [Int] = [
        1, 1, 1, 1, 1, 1, 2, 2, 2, 1, 1, 1, 1, 1, 1, 1,
        1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
    ]

    // swiftlint:disable force_try
    static let literalLengthTable = try! ZstdFSETable(normalized: literalLengthDefault, accuracyLog: 6)
    static let matchLengthTable = try! ZstdFSETable(normalized: matchLengthDefault, accuracyLog: 6)
    static let offsetTable = try! ZstdFSETable(normalized: offsetDefault, accuracyLog: 5)
    // swiftlint:enable force_try
}
