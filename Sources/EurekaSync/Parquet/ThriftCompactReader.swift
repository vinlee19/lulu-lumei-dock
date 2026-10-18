import Foundation

/// Thrift compact protocol decoder (read-only), the counterpart of `ThriftCompactWriter`.
/// Decodes into a generic tree so callers pick fields by id; unknown fields are skipped for free.
/// Every read is bounds-checked: corrupt input throws, it never traps.
/// Spec: https://github.com/apache/thrift/blob/master/doc/specs/thrift-compact-protocol.md
struct ThriftCompactReader {
    indirect enum Value: Equatable {
        case int(Int64)
        case bool(Bool)
        case double(Double)
        case binary([UInt8])
        case list([Value])
        /// Parquet metadata never uses maps; they are parsed (to stay in sync) and dropped
        case map
        case structure([Int16: Value])

        var intValue: Int64? { if case .int(let v) = self { return v } else { return nil } }
        var listValue: [Value]? { if case .list(let v) = self { return v } else { return nil } }
        var structValue: [Int16: Value]? { if case .structure(let v) = self { return v } else { return nil } }
        var stringValue: String? {
            if case .binary(let v) = self { return String(bytes: v, encoding: .utf8) } else { return nil }
        }
    }

    struct ReadError: Error, CustomStringConvertible {
        let description: String
    }

    /// Nesting limit; Parquet metadata is at most ~6 levels deep
    private static let maxDepth = 32

    private let bytes: [UInt8]
    private(set) var position: Int

    init(bytes: [UInt8], position: Int = 0) {
        self.bytes = bytes
        self.position = position
    }

    // MARK: - Structs

    /// Reads one struct (fields until STOP) at the current position
    mutating func readStruct() throws -> [Int16: Value] {
        try readStruct(depth: 0)
    }

    private mutating func readStruct(depth: Int) throws -> [Int16: Value] {
        guard depth < Self.maxDepth else { throw ReadError(description: "Thrift nesting too deep") }
        var fields: [Int16: Value] = [:]
        var lastId: Int16 = 0
        while true {
            let header = try readByte()
            if header == 0 { return fields }
            let type = header & 0x0F
            let delta = Int16(header >> 4)
            if delta == 0 {
                let raw = try readVarint()
                guard let id = Int16(exactly: Self.unzigzag(raw)) else {
                    throw ReadError(description: "Thrift field id out of range")
                }
                lastId = id
            } else {
                let (sum, overflow) = lastId.addingReportingOverflow(delta)
                guard !overflow else { throw ReadError(description: "Thrift field id overflow") }
                lastId = sum
            }
            fields[lastId] = try readValue(type: type, depth: depth)
        }
    }

    // MARK: - Values

    private mutating func readValue(type: UInt8, depth: Int) throws -> Value {
        switch type {
        case 1: return .bool(true)
        case 2: return .bool(false)
        case 3: return .int(Int64(Int8(bitPattern: try readByte())))
        case 4, 5, 6: return .int(Self.unzigzag(try readVarint()))
        case 7:
            let raw = try readBytes(8)
            var bits: UInt64 = 0
            for (index, byte) in raw.enumerated() { bits |= UInt64(byte) << UInt64(8 * index) }
            return .double(Double(bitPattern: bits))
        case 8: return .binary(try readBinary())
        case 9, 10: return try readList(depth: depth)
        case 11: return try readMap(depth: depth)
        case 12: return .structure(try readStruct(depth: depth + 1))
        default: throw ReadError(description: "unknown Thrift type \(type)")
        }
    }

    private mutating func readList(depth: Int) throws -> Value {
        let header = try readByte()
        var size = Int(header >> 4)
        let elementType = header & 0x0F
        if size == 15 {
            guard let long = Int(exactly: try readVarint()) else {
                throw ReadError(description: "Thrift list size out of range")
            }
            size = long
        }
        // Every element takes at least one byte, so a larger claim is corruption (and a memory bomb)
        guard size <= bytes.count - position else { throw ReadError(description: "Thrift list size exceeds data") }
        var items: [Value] = []
        items.reserveCapacity(size)
        for _ in 0..<size {
            if elementType == 1 || elementType == 2 {
                // Booleans inside lists carry their value in a full byte, unlike struct fields
                items.append(.bool(try readByte() == 1))
            } else {
                items.append(try readValue(type: elementType, depth: depth))
            }
        }
        return .list(items)
    }

    private mutating func readMap(depth: Int) throws -> Value {
        guard let size = Int(exactly: try readVarint()) else {
            throw ReadError(description: "Thrift map size out of range")
        }
        guard size > 0 else { return .map }
        let types = try readByte()
        guard size <= bytes.count - position else { throw ReadError(description: "Thrift map size exceeds data") }
        for _ in 0..<size {
            _ = try readValue(type: types >> 4, depth: depth)
            _ = try readValue(type: types & 0x0F, depth: depth)
        }
        return .map
    }

    // MARK: - Primitives

    private mutating func readByte() throws -> UInt8 {
        guard position < bytes.count else { throw ReadError(description: "unexpected end of Thrift data") }
        defer { position += 1 }
        return bytes[position]
    }

    private mutating func readBytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= bytes.count - position else {
            throw ReadError(description: "Thrift length exceeds data")
        }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }

    private mutating func readBinary() throws -> [UInt8] {
        guard let length = Int(exactly: try readVarint()) else {
            throw ReadError(description: "Thrift binary length out of range")
        }
        return try readBytes(length)
    }

    mutating func readVarint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try readByte()
            // The 10th byte may only contribute the top bit of a UInt64
            if shift == 63, byte > 1 { throw ReadError(description: "varint overflows 64 bits") }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            guard shift <= 63 else { throw ReadError(description: "varint too long") }
        }
    }

    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
    }
}
