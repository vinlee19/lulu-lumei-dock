import Foundation
import zlib

/// 最小 Parquet 写入器（纯 Swift，无第三方依赖）。只覆盖审计归档需要的子集：
/// 扁平 schema（无嵌套 / 重复）、每文件一个 row group、每列一个 Data Page v1、PLAIN 编码、
/// 可空列的定义级别用 RLE 混合编码（位宽 1）、GZIP 或不压缩。
/// 读端（DuckDB / pyarrow / Athena / Spark）按标准格式解析即可。
/// 规范：https://github.com/apache/parquet-format（parquet.thrift）
public enum ParquetWriter {
    public enum Compression: Int32 {
        case uncompressed = 0
        case gzip = 2
    }

    public enum Values {
        /// BYTE_ARRAY + STRING 逻辑类型
        case string([String?])
        case int32([Int32?])
        case bool([Bool?])
        /// INT64 + TIMESTAMP(MICROS, UTC)
        case timestampMicros([Int64?])

        var count: Int {
            switch self {
            case .string(let v): return v.count
            case .int32(let v): return v.count
            case .bool(let v): return v.count
            case .timestampMicros(let v): return v.count
            }
        }
    }

    public struct Column {
        public let name: String
        public let values: Values
        /// true = REQUIRED（不允许 nil）；false = OPTIONAL
        public let required: Bool

        public init(name: String, values: Values, required: Bool) {
            self.name = name
            self.values = values
            self.required = required
        }
    }

    public struct WriteError: Error, CustomStringConvertible {
        public let description: String
    }

    // parquet.thrift 枚举值
    private enum PhysicalType: Int32 {
        case boolean = 0, int32 = 1, int64 = 2, byteArray = 6
    }
    private static let encodingPlain: Int32 = 0
    private static let encodingRLE: Int32 = 3
    private static let magic = Data("PAR1".utf8)

    public static func write(
        columns: [Column], compression: Compression = .gzip, createdBy: String
    ) throws -> Data {
        guard let rowCount = columns.first?.values.count else {
            throw WriteError(description: "没有列")
        }
        guard columns.allSatisfy({ $0.values.count == rowCount }) else {
            throw WriteError(description: "各列行数不一致")
        }

        var file = magic
        var chunks: [ChunkMeta] = []
        for column in columns {
            let offset = Int64(file.count)
            let page = try encodePage(column, rowCount: rowCount)
            let body = compression == .gzip ? try gzip(page.body) : page.body
            var header = ThriftCompactWriter()
            header.writeStruct { h in
                h.fieldI32(1, 0)  // DATA_PAGE
                h.fieldI32(2, Int32(page.body.count))
                h.fieldI32(3, Int32(body.count))
                h.fieldStruct(5) { d in
                    d.fieldI32(1, Int32(rowCount))
                    d.fieldI32(2, encodingPlain)
                    d.fieldI32(3, encodingRLE)
                    d.fieldI32(4, encodingRLE)
                }
            }
            file.append(header.data)
            file.append(body)
            chunks.append(ChunkMeta(
                column: column, type: page.type, offset: offset,
                uncompressed: Int64(header.data.count + page.body.count),
                compressed: Int64(header.data.count + body.count),
                nullCount: page.nullCount, minMax: page.minMax))
        }

        var footer = ThriftCompactWriter()
        footer.writeStruct { m in
            m.fieldI32(1, 1)  // version
            m.fieldStructList(2, count: columns.count + 1) { s, index in
                if index == 0 {
                    s.fieldString(4, "schema")
                    s.fieldI32(5, Int32(columns.count))
                    return
                }
                let chunk = chunks[index - 1]
                s.fieldI32(1, chunk.type.rawValue)
                s.fieldI32(3, chunk.column.required ? 0 : 1)
                s.fieldString(4, chunk.column.name)
                switch chunk.column.values {
                case .string:
                    s.fieldI32(6, 0)  // ConvertedType UTF8
                    s.fieldStruct(10) { l in l.fieldStruct(1) { _ in } }  // LogicalType.STRING
                case .timestampMicros:
                    s.fieldI32(6, 10)  // ConvertedType TIMESTAMP_MICROS
                    s.fieldStruct(10) { l in
                        l.fieldStruct(8) { t in  // LogicalType.TIMESTAMP
                            t.fieldBool(1, true)  // isAdjustedToUTC
                            t.fieldStruct(2) { u in u.fieldStruct(2) { _ in } }  // unit = MICROS
                        }
                    }
                case .int32, .bool:
                    break
                }
            }
            m.fieldI64(3, Int64(rowCount))
            m.fieldStructList(4, count: 1) { g, _ in
                g.fieldStructList(1, count: chunks.count) { c, index in
                    let chunk = chunks[index]
                    c.fieldI64(2, chunk.offset)
                    c.fieldStruct(3) { meta in
                        meta.fieldI32(1, chunk.type.rawValue)
                        meta.fieldI32List(2, [encodingPlain, encodingRLE])
                        meta.fieldStringList(3, [chunk.column.name])
                        meta.fieldI32(4, compression.rawValue)
                        meta.fieldI64(5, Int64(rowCount))
                        meta.fieldI64(6, chunk.uncompressed)
                        meta.fieldI64(7, chunk.compressed)
                        meta.fieldI64(9, chunk.offset)
                        meta.fieldStruct(12) { stats in
                            stats.fieldI64(3, Int64(chunk.nullCount))
                            if let (minValue, maxValue) = chunk.minMax {
                                stats.fieldBinary(5, maxValue)
                                stats.fieldBinary(6, minValue)
                            }
                        }
                    }
                }
                g.fieldI64(2, chunks.reduce(0) { $0 + $1.uncompressed })
                g.fieldI64(3, Int64(rowCount))
            }
            m.fieldString(6, createdBy)
        }
        file.append(footer.data)
        file.append(littleEndian(UInt32(footer.data.count)))
        file.append(magic)
        return file
    }

    // MARK: - 页编码

    private struct ChunkMeta {
        let column: Column
        let type: PhysicalType
        let offset: Int64
        let uncompressed: Int64
        let compressed: Int64
        let nullCount: Int
        let minMax: (Data, Data)?
    }

    private struct EncodedPage {
        let type: PhysicalType
        let body: Data
        let nullCount: Int
        let minMax: (Data, Data)?
    }

    private static func encodePage(_ column: Column, rowCount: Int) throws -> EncodedPage {
        func present<T>(_ values: [T?]) throws -> ([T], [Bool]) {
            let defined = values.map { $0 != nil }
            if column.required, defined.contains(false) {
                throw WriteError(description: "必填列 \(column.name) 含空值")
            }
            return (values.compactMap { $0 }, defined)
        }

        var plain = Data()
        let type: PhysicalType
        let defined: [Bool]
        var minMax: (Data, Data)?
        switch column.values {
        case .string(let values):
            type = .byteArray
            let (items, flags) = try present(values)
            defined = flags
            for item in items {
                let bytes = Data(item.utf8)
                plain.append(littleEndian(UInt32(bytes.count)))
                plain.append(bytes)
            }
        case .int32(let values):
            type = .int32
            let (items, flags) = try present(values)
            defined = flags
            for item in items { plain.append(littleEndian(UInt32(bitPattern: item))) }
            if let low = items.min(), let high = items.max() {
                minMax = (littleEndian(UInt32(bitPattern: low)), littleEndian(UInt32(bitPattern: high)))
            }
        case .bool(let values):
            type = .boolean
            let (items, flags) = try present(values)
            defined = flags
            var byte: UInt8 = 0
            for (index, item) in items.enumerated() {
                if item { byte |= 1 << UInt8(index % 8) }
                if index % 8 == 7 {
                    plain.append(byte)
                    byte = 0
                }
            }
            if items.count % 8 != 0 { plain.append(byte) }
        case .timestampMicros(let values):
            type = .int64
            let (items, flags) = try present(values)
            defined = flags
            for item in items { plain.append(littleEndian(UInt64(bitPattern: item))) }
            if let low = items.min(), let high = items.max() {
                minMax = (littleEndian(UInt64(bitPattern: low)), littleEndian(UInt64(bitPattern: high)))
            }
        }

        var body = Data()
        if !column.required {
            // 定义级别：RLE/bit-packed 混合编码，前置 4 字节长度（Data Page v1）
            let levels = rleRuns(defined)
            body.append(littleEndian(UInt32(levels.count)))
            body.append(levels)
        }
        body.append(plain)
        return EncodedPage(
            type: type, body: body, nullCount: defined.filter { !$0 }.count, minMax: minMax)
    }

    /// 位宽 1 的 RLE 段：每段 = varint(runLength << 1) + 1 字节取值
    static func rleRuns(_ flags: [Bool]) -> Data {
        var out = Data()
        var index = 0
        while index < flags.count {
            let value = flags[index]
            var end = index
            while end < flags.count && flags[end] == value { end += 1 }
            var writer = ThriftCompactWriter()
            writer.writeVarint(UInt64(end - index) << 1)
            out.append(writer.data)
            out.append(value ? 1 : 0)
            index = end
        }
        return out
    }

    /// GZIP（带 gzip 头尾，Parquet 的 GZIP codec 要求）
    static func gzip(_ input: Data) throws -> Data {
        var stream = z_stream()
        var status = deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw WriteError(description: "deflateInit2 失败 \(status)") }
        defer { deflateEnd(&stream) }

        var output = Data(count: Int(deflateBound(&stream, UInt(input.count))) + 64)
        var source = input
        let produced: Int = source.withUnsafeMutableBytes { sourceBuffer in
            output.withUnsafeMutableBytes { outputBuffer in
                stream.next_in = sourceBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_in = uInt(input.count)
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                status = deflate(&stream, Z_FINISH)
                return outputBuffer.count - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END else { throw WriteError(description: "deflate 未完成 \(status)") }
        return output.prefix(produced)
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
