import EurekaSync
import Foundation

func parquetReaderTests(_ t: TestRunner) {
    t.suite("ParquetReader · 读取器")

    typealias Column = ParquetWriter.Column

    /// Deterministic pseudo-random generator so every run exercises the same data
    struct LCG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state >> 33
        }
    }

    func sampleColumns(rows: Int, seed: UInt64) -> [Column] {
        var rng = LCG(state: seed)
        func maybe<T>(_ value: T) -> T? { rng.next() % 4 == 0 ? nil : value }
        let words = ["", "a", "审计", "emoji 🎉", "NUL\u{0}inside", "line\nbreak", String(repeating: "长", count: 300)]
        return [
            Column(name: "id", values: .int32((0..<rows).map { Int32($0) }), required: true),
            Column(name: "s", values: .string((0..<rows).map { _ in maybe(words[Int(rng.next() % 7)]) }), required: false),
            Column(name: "req", values: .string((0..<rows).map { _ in words[Int(rng.next() % 7)] }), required: true),
            Column(name: "n", values: .int32((0..<rows).map { _ in
                maybe([Int32.min, -1, 0, 1, Int32.max][Int(rng.next() % 5)]) }), required: false),
            Column(name: "b", values: .bool((0..<rows).map { _ in maybe(rng.next() % 2 == 0) }), required: false),
            Column(name: "t", values: .timestampMicros((0..<rows).map { _ in
                maybe([Int64.min / 2, -1, 0, 1_790_769_600_123_456][Int(rng.next() % 4)]) }), required: false),
        ]
    }

    t.test("往返：写入器 → 读取器逐值相等（0/1/7/8/9/17/1000 行，含空值，GZIP 与未压缩）") {
        for rows in [0, 1, 2, 7, 8, 9, 15, 16, 17, 64, 1000] {
            for compression in [ParquetWriter.Compression.gzip, .uncompressed] {
                let columns = sampleColumns(rows: rows, seed: UInt64(rows) &+ 7)
                let file = try ParquetWriter.write(columns: columns, compression: compression, createdBy: "eureka test")
                let table = try ParquetReader.read(file)
                try expectEqual(table.rowCount, rows)
                try expectEqual(table.createdBy, "eureka test")
                try expect(table.columns == columns, "rows=\(rows) \(compression): columns differ after round trip")
            }
        }
    }

    t.test("往返：2 MB 长字符串、全空可空列、全真布尔列") {
        let big = String(repeating: "x审", count: 700_000)  // ~2.8 MB UTF-8
        let columns = [
            Column(name: "big", values: .string([big, nil, ""]), required: false),
            Column(name: "allnull", values: .int32([nil, nil, nil]), required: false),
            Column(name: "alltrue", values: .bool([true, true, true]), required: true),
        ]
        let table = try ParquetReader.read(try ParquetWriter.write(columns: columns, createdBy: "t"))
        try expect(table.columns == columns)
    }

    // pyarrow-written fixtures (Tests/EurekaTestsRunner/Fixtures/parquet): the same 21-row table, see generator below
    func expectedFixture(_ rows: Range<Int>) -> [Column] {
        let base: Int64 = 1_790_769_600_123_456  // 2026-09-30T12:00:00.123456Z in epoch micros
        return [
            Column(name: "id", values: .int32(rows.map { Int32($0) }), required: true),
            Column(name: "name", values: .string(rows.map { i in
                i == 4 ? "" : i == 5 ? "emoji 🎉 and\nnewline" : (i % 3 == 0 ? nil : "名称-\(i)") }), required: false),
            Column(name: "score", values: .int32(rows.map { i in
                i % 5 == 0 ? nil : (i % 2 == 1 ? Int32.max : Int32.min) }), required: false),
            Column(name: "flag", values: .bool(rows.map { i in i % 6 == 0 ? nil : i % 2 == 0 }), required: false),
            Column(name: "at", values: .timestampMicros(rows.map { i in
                i == 0 ? -1 : (i % 4 == 0 ? nil : base + Int64(i) * 1_000_000) }), required: false),
        ]
    }

    t.test("pyarrow 写的文件：GZIP / 未压缩 / 多 row group 都能读出相同的值") {
        for name in ["pyarrow-gzip-plain", "pyarrow-none-plain", "pyarrow-gzip-2groups"] {
            let table = try ParquetReader.read(try fixtureData("parquet/\(name).parquet"))
            try expectEqual(table.rowCount, 21)
            try expect(table.columns == expectedFixture(0..<21), "\(name): decoded values differ from what pyarrow wrote")
            try expect(table.createdBy?.contains("parquet-cpp-arrow") == true, "\(name): createdBy \(table.createdBy ?? "nil")")
        }
    }

    t.test("不支持的编码明确报错而不是读出错值：Snappy + 字典编码") {
        do {
            _ = try ParquetReader.read(try fixtureData("parquet/pyarrow-snappy-dict.parquet"))
            throw ExpectationError(description: "应当抛错")
        } catch let error as ParquetReader.ReadError {
            try expect(error.description.contains("not supported"), "错误信息应说明不支持: \(error)")
        }
    }

    t.test("损坏输入：任意截断都抛错，任意单字节翻转都不崩溃") {
        let file = try ParquetWriter.write(
            columns: sampleColumns(rows: 20, seed: 99), compression: .gzip, createdBy: "t")
        for length in 0..<file.count {
            do {
                _ = try ParquetReader.read(file.prefix(length))
                throw ExpectationError(description: "截断到 \(length) 字节应当失败")
            } catch is ParquetReader.ReadError {
                continue
            }
        }
        // Reaching the end without a trap is the assertion: a flipped byte may still decode or throw, never crash
        var survived = 0
        for index in 0..<file.count {
            for mask: UInt8 in [0x01, 0x80, 0xFF] {
                var copy = file
                copy[copy.startIndex + index] ^= mask
                _ = try? ParquetReader.read(copy)
                survived += 1
            }
        }
        try expectEqual(survived, file.count * 3)
    }

    t.test("非 Parquet 输入：空、纯文本、只有魔数") {
        for data in [Data(), Data("hello world, not parquet".utf8), Data("PAR1PAR1".utf8), Data("PAR1".utf8 + [0, 0, 0, 0] + "PAR1".utf8)] {
            do {
                _ = try ParquetReader.read(data)
                throw ExpectationError(description: "应当抛错")
            } catch is ParquetReader.ReadError {
                continue
            }
        }
    }
}
