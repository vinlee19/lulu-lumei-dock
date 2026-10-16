import Foundation
import zlib

/// Minimal Parquet reader (pure Swift, no third-party dependencies): the inverse of `ParquetWriter`.
/// It reads the subset that writer produces (and that pyarrow emits with `use_dictionary=False`):
/// flat schema, Data Page v1, PLAIN values, RLE / bit-packed definition levels, UNCOMPRESSED or GZIP.
/// Anything else (dictionary pages, Snappy, nested / repeated columns, Data Page v2) throws a
/// descriptive error instead of returning wrong values. All reads are bounds-checked: corrupt or
/// truncated input throws, it never traps.
public enum ParquetReader {
    public struct Table: Equatable {
        public let columns: [ParquetWriter.Column]
        public let rowCount: Int
        public let createdBy: String?
    }

    public struct ReadError: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    private static let magic: [UInt8] = Array("PAR1".utf8)
    /// Upper bounds that keep a corrupt header from triggering a huge allocation
    private static let maxValuesPerPage = 50_000_000
    private static let maxPageBytes = 1 << 30

    public static func read(contentsOf url: URL) throws -> Table {
        try read(try Data(contentsOf: url))
    }

    public static func read(_ file: Data) throws -> Table {
        let bytes = [UInt8](file)
        guard bytes.count >= 12, Array(bytes.prefix(4)) == magic, Array(bytes.suffix(4)) == magic else {
            throw ReadError("not a Parquet file (missing PAR1 magic)")
        }
        let footerLength = Int(readUInt32(bytes, at: bytes.count - 8))
        guard footerLength > 0, footerLength <= bytes.count - 12 else {
            throw ReadError("footer length \(footerLength) is out of range")
        }
        let footerStart = bytes.count - 8 - footerLength
        var thrift = ThriftCompactReader(bytes: Array(bytes[footerStart..<bytes.count - 8]))
        let meta = try thrift.readStruct()

        let leaves = try schemaLeaves(meta)
        guard let groups = meta[4]?.listValue else { throw ReadError("footer has no row groups list") }

        // Per-column accumulators, appended to across row groups
        var accumulators = leaves.map { Accumulator(kind: $0.kind) }
        var totalRows = 0
        for group in groups {
            guard let fields = group.structValue,
                  let chunks = fields[1]?.listValue,
                  let rows = fields[3]?.intValue, rows >= 0
            else { throw ReadError("malformed row group") }
            guard chunks.count == leaves.count else {
                throw ReadError("row group has \(chunks.count) column chunks, schema has \(leaves.count)")
            }
            for (index, chunk) in chunks.enumerated() {
                try readChunk(
                    chunk, leaf: leaves[index], rows: Int(rows), file: bytes, into: &accumulators[index])
            }
            totalRows += Int(rows)
        }
        if let declared = meta[3]?.intValue, declared != Int64(totalRows) {
            throw ReadError("footer declares \(declared) rows but row groups hold \(totalRows)")
        }
        let columns = zip(leaves, accumulators).map { leaf, accumulator in
            ParquetWriter.Column(
                name: leaf.name, values: accumulator.values(), required: leaf.required)
        }
        return Table(columns: columns, rowCount: totalRows, createdBy: meta[6]?.stringValue)
    }

    // MARK: - Schema

    private enum Kind { case string, int32, bool, timestampMicros }

    private struct Leaf {
        let name: String
        let kind: Kind
        let required: Bool
    }

    private static func schemaLeaves(_ meta: [Int16: ThriftCompactReader.Value]) throws -> [Leaf] {
        guard let elements = meta[2]?.listValue, elements.count >= 1 else {
            throw ReadError("footer has no schema")
        }
        var leaves: [Leaf] = []
        for element in elements.dropFirst() {
            guard let fields = element.structValue, let name = fields[4]?.stringValue else {
                throw ReadError("malformed schema element")
            }
            if let children = fields[5]?.intValue, children > 0 {
                throw ReadError("column \(name) is nested; only flat schemas are supported")
            }
            let repetition = fields[3]?.intValue ?? 0
            guard repetition == 0 || repetition == 1 else {
                throw ReadError("column \(name) is repeated; only REQUIRED / OPTIONAL are supported")
            }
            let converted = fields[6]?.intValue
            let logical = fields[10]?.structValue
            let kind: Kind
            switch fields[1]?.intValue {
            case 0 where converted == nil && logical == nil:
                kind = .bool
            case 1 where converted == nil && logical == nil:
                kind = .int32
            case 2:
                // TIMESTAMP_MICROS, or the TIMESTAMP logical type (field 8) whose unit union holds MICROS (field 2)
                let isMicros = converted == 10 || logical?[8]?.structValue?[2]?.structValue?[2] != nil
                guard isMicros else {
                    throw ReadError("column \(name): INT64 is only supported as TIMESTAMP with MICROS unit")
                }
                kind = .timestampMicros
            case 6 where converted == 0 || logical?[1] != nil:
                kind = .string
            default:
                throw ReadError("column \(name): unsupported physical type \(fields[1]?.intValue ?? -1)")
            }
            leaves.append(Leaf(name: name, kind: kind, required: repetition == 0))
        }
        return leaves
    }

    // MARK: - Column chunks and pages

    private struct Accumulator {
        let kind: Kind
        var strings: [String?] = []
        var int32s: [Int32?] = []
        var bools: [Bool?] = []
        var int64s: [Int64?] = []

        init(kind: Kind) { self.kind = kind }

        func values() -> ParquetWriter.Values {
            switch kind {
            case .string: return .string(strings)
            case .int32: return .int32(int32s)
            case .bool: return .bool(bools)
            case .timestampMicros: return .timestampMicros(int64s)
            }
        }
    }

    private static func readChunk(
        _ chunk: ThriftCompactReader.Value, leaf: Leaf, rows: Int, file: [UInt8],
        into accumulator: inout Accumulator
    ) throws {
        guard let meta = chunk.structValue?[3]?.structValue,
              let codec = meta[4]?.intValue,
              let numValues = meta[5]?.intValue,
              let pageOffset = meta[9]?.intValue
        else { throw ReadError("column \(leaf.name): malformed column chunk metadata") }
        guard meta[11] == nil else {
            throw ReadError("column \(leaf.name): dictionary encoding is not supported (write with use_dictionary=False)")
        }
        guard codec == 0 || codec == 2 else {
            throw ReadError("column \(leaf.name): compression codec \(codec) is not supported (only UNCOMPRESSED and GZIP)")
        }
        guard numValues == Int64(rows) else {
            throw ReadError("column \(leaf.name): \(numValues) values for \(rows) rows")
        }
        guard pageOffset >= 4, pageOffset <= Int64(file.count) else {
            throw ReadError("column \(leaf.name): page offset out of range")
        }

        var offset = Int(pageOffset)
        var valuesRead = 0
        while valuesRead < rows {
            var header = ThriftCompactReader(bytes: file, position: offset)
            let page = try header.readStruct()
            guard page[1]?.intValue == 0 else {
                throw ReadError("column \(leaf.name): only Data Page v1 is supported (page type \(page[1]?.intValue ?? -1))")
            }
            guard let uncompressed = page[2]?.intValue, let compressed = page[3]?.intValue,
                  let dataHeader = page[5]?.structValue,
                  let pageValues = dataHeader[1]?.intValue, let encoding = dataHeader[2]?.intValue
            else { throw ReadError("column \(leaf.name): malformed page header") }
            guard encoding == 0 else {
                throw ReadError("column \(leaf.name): value encoding \(encoding) is not supported (only PLAIN)")
            }
            guard pageValues > 0, pageValues <= Int64(maxValuesPerPage), pageValues <= Int64(rows - valuesRead) else {
                throw ReadError("column \(leaf.name): page value count \(pageValues) is invalid")
            }
            guard uncompressed >= 0, uncompressed <= Int64(maxPageBytes), compressed >= 0 else {
                throw ReadError("column \(leaf.name): page size is invalid")
            }
            let bodyStart = header.position
            guard compressed <= Int64(file.count - bodyStart) else {
                throw ReadError("column \(leaf.name): page body runs past end of file")
            }
            let stored = file[bodyStart..<bodyStart + Int(compressed)]
            let body: [UInt8]
            if codec == 2 {
                body = try gunzip(stored, expectedSize: Int(uncompressed))
            } else {
                guard compressed == uncompressed else {
                    throw ReadError("column \(leaf.name): uncompressed page sizes disagree")
                }
                body = Array(stored)
            }
            try decodePage(body, count: Int(pageValues), leaf: leaf, into: &accumulator)
            valuesRead += Int(pageValues)
            offset = bodyStart + Int(compressed)
        }
    }

    private static func decodePage(
        _ body: [UInt8], count: Int, leaf: Leaf, into accumulator: inout Accumulator
    ) throws {
        var cursor = 0
        var defined = [Bool](repeating: true, count: count)
        if !leaf.required {
            guard body.count >= 4 else { throw ReadError("column \(leaf.name): truncated definition levels") }
            let length = Int(readUInt32(body, at: 0))
            guard length <= body.count - 4 else {
                throw ReadError("column \(leaf.name): definition levels run past end of page")
            }
            defined = try decodeDefinitionLevels(body[4..<4 + length], count: count, column: leaf.name)
            cursor = 4 + length
        }
        let present = defined.lazy.filter { $0 }.count

        switch leaf.kind {
        case .string:
            var decoded: [String] = []
            decoded.reserveCapacity(present)
            for _ in 0..<present {
                guard body.count - cursor >= 4 else { throw ReadError("column \(leaf.name): truncated string length") }
                let length = Int(readUInt32(body, at: cursor))
                cursor += 4
                guard length <= body.count - cursor else {
                    throw ReadError("column \(leaf.name): string runs past end of page")
                }
                guard let text = String(bytes: body[cursor..<cursor + length], encoding: .utf8) else {
                    throw ReadError("column \(leaf.name): invalid UTF-8 in string value")
                }
                decoded.append(text)
                cursor += length
            }
            accumulator.strings.append(contentsOf: spread(decoded, over: defined))
        case .int32:
            guard body.count - cursor == present * 4 else {
                throw ReadError("column \(leaf.name): INT32 page size does not match value count")
            }
            let decoded = (0..<present).map { Int32(bitPattern: readUInt32(body, at: cursor + $0 * 4)) }
            accumulator.int32s.append(contentsOf: spread(decoded, over: defined))
        case .timestampMicros:
            guard body.count - cursor == present * 8 else {
                throw ReadError("column \(leaf.name): INT64 page size does not match value count")
            }
            let decoded = (0..<present).map { Int64(bitPattern: readUInt64(body, at: cursor + $0 * 8)) }
            accumulator.int64s.append(contentsOf: spread(decoded, over: defined))
        case .bool:
            guard body.count - cursor == (present + 7) / 8 else {
                throw ReadError("column \(leaf.name): BOOLEAN page size does not match value count")
            }
            let decoded = (0..<present).map { body[cursor + $0 / 8] >> UInt8($0 % 8) & 1 == 1 }
            accumulator.bools.append(contentsOf: spread(decoded, over: defined))
        }
    }

    /// Puts `values` back at the positions flagged in `defined`, nil elsewhere
    private static func spread<T>(_ values: [T], over defined: [Bool]) -> [T?] {
        var result: [T?] = []
        result.reserveCapacity(defined.count)
        var next = 0
        for flag in defined {
            if flag {
                result.append(values[next])
                next += 1
            } else {
                result.append(nil)
            }
        }
        return result
    }

    /// RLE / bit-packed hybrid, bit width 1 (max definition level of a flat OPTIONAL column)
    private static func decodeDefinitionLevels(
        _ slice: ArraySlice<UInt8>, count: Int, column: String
    ) throws -> [Bool] {
        let raw = Array(slice)
        var position = 0
        func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while true {
                guard position < raw.count, shift <= 63 else {
                    throw ReadError("column \(column): malformed definition level run header")
                }
                let byte = raw[position]
                position += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
        }

        var flags: [Bool] = []
        flags.reserveCapacity(count)
        while flags.count < count {
            guard position < raw.count else {
                throw ReadError("column \(column): definition levels end before \(count) values")
            }
            let header = try varint()
            guard let runs = Int(exactly: header >> 1) else {
                throw ReadError("column \(column): definition level run length out of range")
            }
            if header & 1 == 0 {
                // RLE run: `runs` copies of one value stored in a single byte
                guard position < raw.count else { throw ReadError("column \(column): truncated RLE run") }
                let value = raw[position]
                position += 1
                guard value <= 1 else { throw ReadError("column \(column): definition level \(value) exceeds 1") }
                flags.append(contentsOf: repeatElement(value == 1, count: min(runs, count - flags.count)))
            } else {
                // Bit-packed: `runs` groups of 8 values, one byte per group at width 1, LSB first
                guard runs <= raw.count - position else {
                    throw ReadError("column \(column): bit-packed run exceeds definition levels")
                }
                for byteIndex in 0..<runs {
                    let packed = raw[position + byteIndex]
                    for bit in 0..<8 where flags.count < count {
                        flags.append(packed >> UInt8(bit) & 1 == 1)
                    }
                }
                position += runs
            }
        }
        return flags
    }

    // MARK: - Helpers

    private static func readUInt32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << UInt32(8 * $1) }
    }

    private static func readUInt64(_ bytes: [UInt8], at index: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(bytes[index + $1]) << UInt64(8 * $1) }
    }

    /// GZIP (with gzip header / trailer, as the Parquet GZIP codec requires)
    static func gunzip(_ input: ArraySlice<UInt8>, expectedSize: Int) throws -> [UInt8] {
        if expectedSize == 0 { return [] }
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else { throw ReadError("inflateInit2 failed (\(status))") }
        defer { inflateEnd(&stream) }

        var source = Array(input)
        var output = [UInt8](repeating: 0, count: expectedSize)
        let produced: Int = source.withUnsafeMutableBufferPointer { sourceBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                stream.next_in = sourceBuffer.baseAddress
                stream.avail_in = uInt(sourceBuffer.count)
                stream.next_out = outputBuffer.baseAddress
                stream.avail_out = uInt(outputBuffer.count)
                status = inflate(&stream, Z_FINISH)
                return outputBuffer.count - Int(stream.avail_out)
            }
        }
        guard status == Z_STREAM_END, produced == expectedSize else {
            throw ReadError("GZIP page is corrupt or its size disagrees with the header (status \(status))")
        }
        return output
    }
}
