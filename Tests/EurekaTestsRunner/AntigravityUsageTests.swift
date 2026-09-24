import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 测试用最小 protobuf 编码器（与 ProtobufReader 对拍）
private enum PB {
    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    static func uint(_ number: Int, _ value: UInt64) -> Data {
        varint(UInt64(number << 3)) + varint(value)
    }

    static func bytes(_ number: Int, _ payload: Data) -> Data {
        varint(UInt64(number << 3 | 2)) + varint(UInt64(payload.count)) + payload
    }

    static func string(_ number: Int, _ text: String) -> Data { bytes(number, Data(text.utf8)) }

    static func float(_ number: Int, _ value: Float) -> Data {
        var bits = value.bitPattern.littleEndian
        return varint(UInt64(number << 3 | 5)) + Data(bytes: &bits, count: 4)
    }
}

/// 一条 gen_metadata：1{4{usage}, 19 model, 20{last_step_index}}
private func genMetadata(model: String?, input: UInt64, output: UInt64, cacheRead: UInt64, step: Int) -> Data {
    let usage = PB.uint(1, 1318) + PB.uint(2, input) + PB.uint(3, output) + PB.uint(5, cacheRead)
        + PB.uint(9, output / 2) + PB.uint(10, output - output / 2)
    var call = PB.uint(3, 1318) + PB.bytes(4, usage)
    if let model { call += PB.string(19, model) }
    call += PB.bytes(20, PB.string(1, "last_step_index") + PB.string(2, "\(step)"))
    return PB.string(4, "conversation-id") + PB.bytes(1, call)
}

private func makeConversation(in dir: URL, id: String) throws -> URL {
    let url = dir.appendingPathComponent("\(id).db")
    let db = try SQLiteDB(path: url.path)
    try db.execute("""
        CREATE TABLE gen_metadata (idx integer PRIMARY KEY, data blob, size integer NOT NULL DEFAULT 0);
        CREATE TABLE steps (idx integer PRIMARY KEY, step_type integer NOT NULL DEFAULT 0, metadata blob);
        """)
    return url
}

private func insertCall(_ url: URL, idx: Int, data: Data, step: Int, at seconds: UInt64) throws {
    let db = try SQLiteDB(path: url.path)
    // SQLiteValue 没有 blob：用 SQL 的 unhex 写真 BLOB
    try db.run("INSERT INTO gen_metadata (idx, data) VALUES (?, unhex(?))",
               [.int(Int64(idx)), .text(data.map { String(format: "%02x", $0) }.joined())])
    let metadata = PB.bytes(1, PB.uint(1, seconds) + PB.uint(2, 5))
    try db.run("INSERT OR REPLACE INTO steps (idx, metadata) VALUES (?, unhex(?))",
               [.int(Int64(step)), .text(metadata.map { String(format: "%02x", $0) }.joined())])
}

func antigravityUsageTests(_ t: TestRunner) {
    t.suite("ProtobufReader")

    t.test("嵌套路径、重复字段、float、未知字段跳过") {
        let data = PB.uint(1, 7) + PB.bytes(2, PB.string(1, "a") + PB.float(3, 0.25))
            + PB.bytes(2, PB.string(1, "b")) + PB.uint(99, 1)
        try expectEqual(ProtobufReader.first(data, [1])?.uint, 7)
        try expectEqual(ProtobufReader.first(data, [2, 1])?.string, "a")
        try expectEqual(ProtobufReader.first(data, [2, 3])?.float, 0.25)
        try expectEqual(ProtobufReader.all(data, 2).count, 2)
        try expect(ProtobufReader.first(data, [5]) == nil)
    }

    t.test("截断 / 非法 wire type 返回 nil 不崩") {
        let data = PB.bytes(1, Data(repeating: 0x41, count: 10))
        try expect(ProtobufReader.fields(data.prefix(5)) == nil)
        try expect(ProtobufReader.fields(Data([0x0B])) == nil)  // wire type 3（group）
        try expect(ProtobufReader.fields(Data([0x08, 0xFF])) == nil)  // varint 未结束
        try expect(ProtobufReader.fields(Data()) == [])
    }

    t.suite("AntigravityUsageScanner")

    t.test("gen_metadata → 用量入账：输入不含缓存读、时间取对应 step、增量与幂等") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-agy-test-\(UUID().uuidString)")
        let conversations = root.appendingPathComponent("conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let conv = try makeConversation(in: conversations, id: "conv-1")
        try insertCall(conv, idx: 0, data: genMetadata(
            model: "gemini-3.8-flash", input: 1000, output: 200, cacheRead: 5000, step: 3),
            step: 3, at: 1_790_000_000)
        try insertCall(conv, idx: 1, data: genMetadata(
            model: nil, input: 0, output: 0, cacheRead: 0, step: 4), step: 4, at: 1_790_000_100)

        let store = try EurekaStore(path: root.appendingPathComponent("eureka.sqlite"))
        let scanner = AntigravityUsageScanner(
            conversationsRoot: conversations, store: store, cwdResolver: { _ in "/Users/me/demo" })
        try expectEqual(try scanner.scanOnce(), 1)  // 全零那行跳过
        var rows = try store.usage.totalsForSessions(["conv-1"])["conv-1"] ?? []
        let row = try expectSome(rows.first)
        try expectEqual(row.model, "gemini-3.8-flash")
        try expectEqual(row.inputTokens, 1000)
        try expectEqual(row.cacheReadTokens, 5000)
        try expectEqual(row.outputTokens, 200)
        try expectEqual(row.provider, "google")
        let records = try store.usage.recentRecords(limit: 5)
        try expectEqual(records.first?.ts, Date(timeIntervalSince1970: 1_790_000_000))

        // 指纹没变：不重扫
        try expectEqual(try scanner.scanOnce(), 0)
        // 新增一行：只入新行
        try insertCall(conv, idx: 2, data: genMetadata(
            model: "gemini-3.8-flash", input: 10, output: 20, cacheRead: 0, step: 5),
            step: 5, at: 1_790_000_200)
        try expectEqual(try scanner.scanOnce(), 1)
        rows = try store.usage.totalsForSessions(["conv-1"])["conv-1"] ?? []
        try expectEqual(rows.first?.requestCount, 2)
        // 扫描不留临时副本
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path))?.filter { $0.hasPrefix("eureka-agy-") && !$0.hasPrefix("eureka-agy-test-") } ?? []
        try expect(leftovers.isEmpty, "\(leftovers)")
    }

    t.suite("AntigravityRateLimitProvider")

    /// 构造 userStatus：外层 base64(1{1:key, 2{1: base64(inner)}})；inner 里混入假姓名/邮箱字段
    func userStatus(models: [(String, Float, UInt64)], plan: String) -> Data {
        var quotas = Data()
        for (label, remaining, reset) in models {
            let quota = PB.float(1, remaining) + PB.bytes(2, PB.uint(1, reset))
            quotas += PB.bytes(1, PB.string(1, label) + PB.bytes(15, quota))
        }
        let inner = PB.string(3, "Test Person") + PB.string(7, "someone@example.com")
            + PB.bytes(33, quotas) + PB.bytes(36, PB.string(1, "tier") + PB.string(2, plan))
        let wrapped = PB.bytes(1, PB.string(1, "userStatusSentinelKey")
            + PB.bytes(2, PB.string(1, inner.base64EncodedString())))
        return Data(wrapped.base64EncodedString().utf8)
    }

    t.test("按模型家族取剩余最少者，套餐名取 36.2") {
        let raw = userStatus(models: [
            ("Gemini 3.6 Flash (High)", 0.8, 1_790_100_000),
            ("Gemini 3.1 Pro (High)", 0.25, 1_790_050_000),
            ("Claude Opus 4.6 (Thinking)", 1.0, 1_790_200_000),
        ], plan: "Google AI Pro")
        let snapshot = try expectSome(AntigravityRateLimitProvider.parse(
            userStatus: raw, asOf: Date(timeIntervalSince1970: 1_790_000_000)))
        try expectEqual(snapshot.planType, "Google AI Pro")
        try expect(abs((snapshot.primary?.usedPercent ?? 0) - 75) < 0.001)
        try expectEqual(snapshot.primary?.label, "Gemini 模型")
        try expectEqual(snapshot.primary?.resetsAt, Date(timeIntervalSince1970: 1_790_050_000))
        try expectEqual(snapshot.secondary?.usedPercent, 0)
        // 快照里只有额度与套餐，不含账号信息
        let dump = String(describing: snapshot)
        try expect(!dump.contains("someone@example.com") && !dump.contains("Test Person"), dump)
    }

    t.test("格式不符 / 剩余比例越界 → nil") {
        try expect(AntigravityRateLimitProvider.parse(
            userStatus: Data("not base64!".utf8), asOf: Date()) == nil)
        let bad = userStatus(models: [("Gemini X", 1.5, 1)], plan: "p")
        try expect(AntigravityRateLimitProvider.parse(userStatus: bad, asOf: Date()) == nil)
    }
}
