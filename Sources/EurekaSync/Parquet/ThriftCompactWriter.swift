import Foundation

/// Thrift compact protocol encoder (write-only, covers the types Parquet metadata uses).
/// Spec: https://github.com/apache/thrift/blob/master/doc/specs/thrift-compact-protocol.md
struct ThriftCompactWriter {
    enum FieldType: UInt8 {
        case boolTrue = 1
        case boolFalse = 2
        case byte = 3
        case i16 = 4
        case i32 = 5
        case i64 = 6
        case double = 7
        case binary = 8
        case list = 9
        case set = 10
        case map = 11
        case `struct` = 12
    }

    private(set) var data = Data()
    /// Last field id per struct level (field headers are delta-encoded; pushed when entering a
    /// nested struct)
    private var lastFieldIds: [Int16] = [0]

    // MARK: - Fields

    mutating func fieldI32(_ id: Int16, _ value: Int32) {
        fieldHeader(id, .i32)
        writeVarint(zigzag32(value))
    }

    mutating func fieldI64(_ id: Int16, _ value: Int64) {
        fieldHeader(id, .i64)
        writeVarint(zigzag64(value))
    }

    mutating func fieldBool(_ id: Int16, _ value: Bool) {
        fieldHeader(id, value ? .boolTrue : .boolFalse)
    }

    mutating func fieldBinary(_ id: Int16, _ value: Data) {
        fieldHeader(id, .binary)
        writeBinary(value)
    }

    mutating func fieldString(_ id: Int16, _ value: String) {
        fieldBinary(id, Data(value.utf8))
    }

    /// Nested struct field: body writes the struct's fields, STOP is appended automatically at the
    /// end
    mutating func fieldStruct(_ id: Int16, _ body: (inout ThriftCompactWriter) -> Void) {
        fieldHeader(id, .struct)
        writeStruct(body)
    }

    /// List of structs
    mutating func fieldStructList(_ id: Int16, count: Int, _ element: (inout ThriftCompactWriter, Int) -> Void) {
        fieldHeader(id, .list)
        listHeader(count: count, elementType: .struct)
        for index in 0..<count {
            writeStruct { element(&$0, index) }
        }
    }

    mutating func fieldI32List(_ id: Int16, _ values: [Int32]) {
        fieldHeader(id, .list)
        listHeader(count: values.count, elementType: .i32)
        for value in values { writeVarint(zigzag32(value)) }
    }

    mutating func fieldStringList(_ id: Int16, _ values: [String]) {
        fieldHeader(id, .list)
        listHeader(count: values.count, elementType: .binary)
        for value in values { writeBinary(Data(value.utf8)) }
    }

    /// Top-level struct (FileMetaData / PageHeader): write fields + STOP
    mutating func writeStruct(_ body: (inout ThriftCompactWriter) -> Void) {
        lastFieldIds.append(0)
        body(&self)
        data.append(0)  // STOP
        lastFieldIds.removeLast()
    }

    // MARK: - Low-level encoding

    private mutating func fieldHeader(_ id: Int16, _ type: FieldType) {
        let delta = Int(id) - Int(lastFieldIds[lastFieldIds.count - 1])
        if delta > 0 && delta <= 15 {
            data.append(UInt8(delta << 4) | type.rawValue)
        } else {
            data.append(type.rawValue)
            writeVarint(UInt64(zigzag32(Int32(id))))
        }
        lastFieldIds[lastFieldIds.count - 1] = id
    }

    private mutating func listHeader(count: Int, elementType: FieldType) {
        if count < 15 {
            data.append(UInt8(count << 4) | elementType.rawValue)
        } else {
            data.append(0xF0 | elementType.rawValue)
            writeVarint(UInt64(count))
        }
    }

    private mutating func writeBinary(_ value: Data) {
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func writeVarint(_ value: UInt64) {
        var value = value
        while value >= 0x80 {
            data.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        data.append(UInt8(value))
    }

    private func zigzag32(_ value: Int32) -> UInt64 {
        UInt64(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }

    private func zigzag64(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }
}
