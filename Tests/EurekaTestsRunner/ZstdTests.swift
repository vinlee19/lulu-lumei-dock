import CryptoKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

private struct ZstdExpectation: Decodable {
    let sha256: String
    let size: Int
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Reads a whole stream in uneven slices, so slice boundaries land mid-block
private func decodeInSlices(_ path: String, slice: Int = 7_777) throws -> Data {
    guard let stream = ZstdStream(path: path) else {
        throw ExpectationError(description: "cannot open \(path)")
    }
    var out = Data()
    while true {
        let piece = try stream.read(upToCount: slice)
        if piece.isEmpty { return out }
        out.append(piece)
    }
}

private func writeTemp(_ bytes: [UInt8], name: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-zstd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try Data(bytes).write(to: url)
    return url
}

func zstdTests(_ t: TestRunner) {
    t.suite("ZstdStream")

    t.test("fixtures 逐字节还原（多 block / RLE / raw / 校验和 / 多帧 + skippable / 无 content size）") {
        let manifest = try JSONDecoder().decode(
            [String: ZstdExpectation].self, from: try fixtureData("zstd/manifest.json"))
        try expectEqual(manifest.count, 7)
        for (name, expected) in manifest.sorted(by: { $0.key < $1.key }) {
            let data = try decodeInSlices(try fixtureURL("zstd/\(name)").path)
            try expectEqual(data.count, expected.size, name)
            try expectEqual(sha256Hex(data), expected.sha256, name)
        }
    }

    t.test("帧头给出解压大小：多帧求和，不带 content size 的流返回 nil") {
        let manifest = try JSONDecoder().decode(
            [String: ZstdExpectation].self, from: try fixtureData("zstd/manifest.json"))
        for name in ["prose-19.zst", "prose-1-checksum.zst", "rle.zst", "multi-frame.zst", "tiny.zst"] {
            let size = ZstdFrameInfo.contentSize(path: try fixtureURL("zstd/\(name)").path)
            try expectEqual(size, UInt64(manifest[name]!.size), name)
        }
        let streamPath = try fixtureURL("zstd/stream-no-size.zst").path
        try expect(ZstdFrameInfo.contentSize(path: streamPath) == nil)
    }

    t.test("skip 之后接着读，和整段解码的后半截一致") {
        let path = try fixtureURL("zstd/prose-19.zst").path
        let whole = try decodeInSlices(path)
        let stream = ZstdStream(path: path)!
        try expectEqual(try stream.skip(150_001), 150_001)
        let rest = try stream.readToEnd()
        try expectEqual(rest, whole.suffix(from: whole.startIndex + 150_001))
    }

    t.test("超过 64 MiB 的窗口拒绝解码") {
        let stream = ZstdStream(path: try fixtureURL("zstd/long-window.zst").path)!
        do {
            _ = try stream.read(upToCount: 1)
            throw ExpectationError(description: "128 MiB window should be refused")
        } catch let error as ZstdError {
            guard case .unsupported = error else { throw error }
        }
    }

    t.test("截断的文件报错，不当成空文件或短文件") {
        let full = try fixtureData("zstd/prose-19.zst")
        let url = try writeTemp([UInt8](full.prefix(full.count / 2)), name: "cut.zst")
        var threw = false
        do { _ = try decodeInSlices(url.path) } catch { threw = true }
        try expect(threw, "truncated input must throw")
        try expect(RolloutByteSource.contents(atPath: url.path) == nil)
        try expect(ZstdFrameInfo.contentSize(path: url.path) == nil)
    }

    t.test("带字典 ID 的帧拒绝解码") {
        // magic, descriptor (dictionary id flag 1, no content size), window byte, dictionary id 7
        let url = try writeTemp([0x28, 0xB5, 0x2F, 0xFD, 0x01, 0x00, 0x07, 0x01, 0x00, 0x00],
                                name: "dict.zst")
        do {
            _ = try ZstdStream(path: url.path)!.read(upToCount: 16)
            throw ExpectationError(description: "dictionary frame should be refused")
        } catch let error as ZstdError {
            try expectEqual(error, .unsupported("dictionary frame"))
        }
    }

    t.test("JSONLinesReader 读 .zst：大小是解压大小，切片续读与明文逐行一致") {
        let zst = try fixtureURL("zstd/codex-rollout-trail.jsonl.zst").path
        let plain = try fixtureData("codex-rollout-trail.jsonl")
        try expectEqual(JSONLinesReader.fileInfo(path: zst)?.size, UInt64(plain.count))

        var lines: [Data] = []
        var offset: UInt64 = 0
        var reads = 0
        while let chunk = JSONLinesReader.read(path: zst, from: offset, maxBytes: 300) {
            lines += chunk.lines
            offset = chunk.newOffset
            reads += 1
            if chunk.reachedEnd { break }
        }
        try expect(reads > 2, "small slices should take several reads")
        try expectEqual(offset, UInt64(plain.count))
        try expectEqual(
            lines, plain.split(separator: UInt8(ascii: "\n")).map { Data($0) })
        try expect(JSONLinesReader.read(path: zst, from: offset) == nil, "nothing past the end")
    }

    t.suite("Codex 压缩 rollout（.jsonl.zst）")

    func todayDir(_ root: URL) throws -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    func tempRoot(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }
    let rolloutName = "rollout-2026-06-11T10-00-00-019eaaaa-bbbb-7ccc-8ddd-eeeeffff0002.jsonl"

    t.test("会话索引读出压缩会话；同一会话明文和压缩并存时只取明文") {
        let root = tempRoot("cxzst-idx")
        defer { try? FileManager.default.removeItem(at: root) }
        let day = try todayDir(root)
        let zst = day.appendingPathComponent(rolloutName + ".zst")
        try FileManager.default.copyItem(
            at: fixtureURL("zstd/codex-rollout-lifecycle.jsonl.zst"), to: zst)

        var sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1)
        try expectEqual(sessions[0].id, "fixture-codex-1")
        try expectEqual(sessions[0].cwd, "/Users/me/work/demo")
        try expectEqual(sessions[0].name, "跑一下集成测试并修复失败用例")
        try expectEqual(URL(fileURLWithPath: sessions[0].transcriptPath).lastPathComponent, zst.lastPathComponent)

        // Resume in progress: Codex has decompressed next to the compressed copy
        let plain = day.appendingPathComponent(rolloutName)
        try FileManager.default.copyItem(at: fixtureURL("codex-rollout-lifecycle.jsonl"), to: plain)
        sessions = CodexSessionIndexer.index(sessionsRoot: root)
        try expectEqual(sessions.count, 1)
        try expectEqual(URL(fileURLWithPath: sessions[0].transcriptPath).lastPathComponent, plain.lastPathComponent)
    }

    t.test("会话详情读压缩 rollout 与明文结果相同") {
        let fromPlain = TranscriptReader.loadCodex(
            path: try fixtureURL("codex-rollout-trail.jsonl").path, maxMessages: 2000)
        let fromZst = TranscriptReader.loadCodex(
            path: try fixtureURL("zstd/codex-rollout-trail.jsonl.zst").path, maxMessages: 2000)
        try expect(!fromPlain.messages.isEmpty)
        try expectEqual(fromZst, fromPlain)
    }

    t.test("限额从压缩 rollout 的末尾读出") {
        let snapshot = CodexRateLimitProvider.lastRateLimits(
            in: try fixtureURL("zstd/codex-rollout-token-count-ratelimits.jsonl.zst"))
        try expectEqual(snapshot?.primary?.usedPercent, 3.5)
        try expectEqual(snapshot?.secondary?.usedPercent, 38.5)
    }

    t.test("用量：只有压缩文件也能记账；明文压缩成 .zst 后重扫不重复入账") {
        func totals(_ store: EurekaStore) throws -> (Int, Int, Int) {
            let codex = try store.usage.totalsByModel(
                from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
                .filter { $0.source == .codex }
            return (codex.reduce(0) { $0 + $1.inputTokens },
                    codex.reduce(0) { $0 + $1.cacheReadTokens },
                    codex.reduce(0) { $0 + $1.outputTokens })
        }
        let name = "rollout-2026-06-09T13-00-00-aaaa.jsonl"

        // Compressed only: the same records as the plain file yields in the existing test
        let rootA = tempRoot("cxzst-usage-a")
        defer { try? FileManager.default.removeItem(at: rootA) }
        let storeA = try EurekaStore(path: rootA.appendingPathComponent("db/test.sqlite"))
        try FileManager.default.copyItem(
            at: fixtureURL("zstd/codex-rollout-token-count-ratelimits.jsonl.zst"),
            to: try todayDir(rootA.appendingPathComponent("sessions")).appendingPathComponent(name + ".zst"))
        let scannerA = CodexUsageScanner(
            sessionsRoot: rootA.appendingPathComponent("sessions"), store: storeA)
        try expectEqual(try scannerA.scanOnce(), 2)
        try expectEqual(try scannerA.scanOnce(), 0, "a fully read .zst is not read again")
        let compressedTotals = try totals(storeA)
        try expectEqual(compressedTotals.0, 8000 + 3000)
        try expectEqual(compressedTotals.1, 2000 + 3000)
        try expectEqual(compressedTotals.2, 500 + 800)

        // Plain first, then Codex compresses it (new path, new inode): nothing new is recorded
        let rootB = tempRoot("cxzst-usage-b")
        defer { try? FileManager.default.removeItem(at: rootB) }
        let storeB = try EurekaStore(path: rootB.appendingPathComponent("db/test.sqlite"))
        let day = try todayDir(rootB.appendingPathComponent("sessions"))
        let plain = day.appendingPathComponent(name)
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"), to: plain)
        let scannerB = CodexUsageScanner(
            sessionsRoot: rootB.appendingPathComponent("sessions"), store: storeB)
        try expectEqual(try scannerB.scanOnce(), 2)
        try FileManager.default.removeItem(at: plain)
        try FileManager.default.copyItem(
            at: fixtureURL("zstd/codex-rollout-token-count-ratelimits.jsonl.zst"),
            to: day.appendingPathComponent(name + ".zst"))
        try expectEqual(try scannerB.scanOnce(), 0, "the compressed copy adds no records")
        try expectEqual(try totals(storeB).0, compressedTotals.0)
        try expectEqual(try totals(storeB).2, compressedTotals.2)
    }
}
