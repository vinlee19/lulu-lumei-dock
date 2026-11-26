import Foundation

/// Errors raised while decoding a Zstandard stream. Callers treat every one of them as "this file
/// can't be read" and never as "this file is empty".
public enum ZstdError: Error, Equatable {
    /// The input ended inside a frame
    case truncated
    /// The bytes don't follow RFC 8878
    case corrupt(String)
    /// Valid Zstandard this decoder deliberately doesn't handle (dictionaries, oversized windows)
    case unsupported(String)
}

/// Little-endian, least-significant-bit-first reader used for FSE table descriptions and the
/// direct Huffman weight header. Reading past the end yields zero bits; callers compare
/// `bytesConsumed` against the bytes they were given.
struct ZstdForwardBits {
    let base: UnsafePointer<UInt8>
    let count: Int
    private(set) var bitPos = 0

    init(_ buffer: UnsafeBufferPointer<UInt8>) {
        base = buffer.baseAddress ?? UnsafePointer(bitPattern: 1)!
        count = buffer.count
    }

    var bytesConsumed: Int { (bitPos + 7) >> 3 }

    func peek(_ n: Int) -> UInt64 {
        let byte = bitPos >> 3
        var value: UInt64 = 0
        for i in 0..<8 where byte + i < count {
            value |= UInt64(base[byte + i]) << UInt64(8 * i)
        }
        return (value >> UInt64(bitPos & 7)) & ((1 << UInt64(n)) - 1)
    }

    mutating func skip(_ n: Int) { bitPos += n }

    mutating func read(_ n: Int) -> UInt64 {
        let value = peek(n)
        bitPos += n
        return value
    }
}

/// Reader for the backward bitstreams Zstandard writes for Huffman literals, FSE weights and
/// sequences: the stream is read from its last byte toward its first, the highest set bit of the
/// last byte is a padding marker, and every read returns its bits most significant first.
///
/// `position` counts the bits still unread. Reads past the start yield zero bits and drive it
/// negative, which is how the FSE weight decoder detects the end and how the other decoders detect
/// corruption (they require exactly zero at the end).
struct ZstdBackwardBits {
    let base: UnsafePointer<UInt8>
    let count: Int
    private(set) var position: Int

    init(_ buffer: UnsafeBufferPointer<UInt8>) throws {
        guard let address = buffer.baseAddress, buffer.count > 0 else {
            throw ZstdError.corrupt("empty bitstream")
        }
        let last = buffer[buffer.count - 1]
        guard last != 0 else { throw ZstdError.corrupt("bitstream without end marker") }
        base = address
        count = buffer.count
        position = (buffer.count - 1) * 8 + (7 - last.leadingZeroBitCount)
    }

    @inline(__always)
    private func load64(_ byte: Int) -> UInt64 {
        if byte >= 0, byte + 8 <= count {
            return UnsafeRawPointer(base + byte).loadUnaligned(as: UInt64.self).littleEndian
        }
        var value: UInt64 = 0
        for i in 0..<8 where byte + i >= 0 && byte + i < count {
            value |= UInt64(base[byte + i]) << UInt64(8 * i)
        }
        return value
    }

    /// The next `n` bits (n <= 56) without consuming them
    @inline(__always)
    func peek(_ n: Int) -> UInt64 {
        guard n > 0 else { return 0 }
        let mask: UInt64 = (1 << UInt64(n)) - 1
        if position >= n {
            let start = position - n
            return (load64(start >> 3) >> UInt64(start & 7)) & mask
        }
        guard position > 0 else { return 0 }
        let low = load64(0) & ((1 << UInt64(position)) - 1)
        return (low << UInt64(n - position)) & mask
    }

    @inline(__always)
    mutating func skip(_ n: Int) { position -= n }

    @inline(__always)
    mutating func read(_ n: Int) -> UInt64 {
        let value = peek(n)
        position -= n
        return value
    }
}
