import Foundation

/// Minimal schema-less protobuf wire-format reader: understands only varint / fixed64 /
/// length-delimited / fixed32,
/// and reads values by field-number path. Used for Antigravity's undocumented protobuf (field
/// meanings are verified against structure; see the callers' comments).
/// Any out-of-bounds read, illegal wire type or truncated data returns nil and **never crashes** -
/// if the format changes it degrades gracefully.
public enum ProtobufReader {
    public enum Value: Equatable, Sendable {
        case varint(UInt64)
        case fixed64(UInt64)
        case bytes(Data)
        case fixed32(UInt32)
    }

    public struct Field: Equatable, Sendable {
        public let number: Int
        public let value: Value

        public var uint: UInt64? {
            if case .varint(let raw) = value { return raw }
            return nil
        }

        public var data: Data? {
            if case .bytes(let raw) = value { return raw }
            return nil
        }

        public var string: String? {
            data.flatMap { String(data: $0, encoding: .utf8) }
        }

        public var float: Float? {
            if case .fixed32(let raw) = value { return Float(bitPattern: raw) }
            return nil
        }
    }

    /// Parses a single level; nil on invalid data
    public static func fields(_ data: Data) -> [Field]? {
        let bytes = [UInt8](data)
        var index = 0
        var result: [Field] = []
        while index < bytes.count {
            guard let key = readVarint(bytes, &index) else { return nil }
            let number = Int(key >> 3)
            guard number > 0 else { return nil }
            switch key & 7 {
            case 0:
                guard let raw = readVarint(bytes, &index) else { return nil }
                result.append(Field(number: number, value: .varint(raw)))
            case 1:
                guard index + 8 <= bytes.count else { return nil }
                let raw = bytes[index..<index + 8].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
                index += 8
                result.append(Field(number: number, value: .fixed64(raw)))
            case 2:
                guard let length = readVarint(bytes, &index), length <= UInt64(bytes.count - index)
                else { return nil }
                let end = index + Int(length)
                result.append(Field(number: number, value: .bytes(Data(bytes[index..<end]))))
                index = end
            case 5:
                guard index + 4 <= bytes.count else { return nil }
                let raw = bytes[index..<index + 4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                index += 4
                result.append(Field(number: number, value: .fixed32(raw)))
            default:
                return nil  // group (3/4) and other deprecated wire types: treated as a format mismatch
            }
        }
        return result
    }

    /// First field matching the path (intermediate levels must be parseable submessages)
    public static func first(_ data: Data, _ path: [Int]) -> Field? {
        guard let head = path.first, let fields = fields(data) else { return nil }
        guard let hit = fields.first(where: { $0.number == head }) else { return nil }
        if path.count == 1 { return hit }
        guard let inner = hit.data else { return nil }
        return first(inner, Array(path.dropFirst()))
    }

    /// All repeated values of one field at the same level
    public static func all(_ data: Data, _ number: Int) -> [Field] {
        (fields(data) ?? []).filter { $0.number == number }
    }

    private static func readVarint(_ bytes: [UInt8], _ index: inout Int) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }
}
