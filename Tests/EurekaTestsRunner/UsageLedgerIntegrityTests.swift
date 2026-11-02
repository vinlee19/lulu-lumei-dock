import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

private func makeLedgerStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-ledger-\(UUID().uuidString)/test.sqlite")
}

private func allTotals(_ store: EurekaStore) throws -> [UsageTotals] {
    try store.usage.totalsByModel(
        from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
        .sorted { "\($0.source.rawValue)|\($0.model)" < "\($1.source.rawValue)|\($1.model)" }
}

private extension ISO8601DateFormatter {
    /// Same format the Claude scanner parses transcript timestamps with
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

private func rowCount(_ store: EurekaStore, _ sql: String) throws -> Int {
    try store.db.query(sql) { Int($0.int(0)) }.first ?? -1
}

private func hasRecordKeyIndex(_ store: EurekaStore) throws -> Bool {
    try rowCount(
        store,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = 'idx_usage_record_key'"
    ) == 1
}

/// Simulates lost scan progress (a rewritten file gets a new inode, a dedup key ages out): the
/// next pass reads every source file from the start again.
private func forgetScanProgress(_ store: EurekaStore) throws {
    try store.db.execute("DELETE FROM scan_files; DELETE FROM dedup_keys;")
}

func usageLedgerIntegrityTests(_ t: TestRunner) {
    t.suite("用量账本 · 重扫幂等")

    t.test("同一条用量重复写入只留一行，较大的 output 会被保留") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let indexed = try hasRecordKeyIndex(store)
        try expect(indexed, "新库应直接带唯一索引")
        var record = UsageRecord(
            source: .claude, model: "claude-opus-5", project: "p", sessionId: "s",
            timestamp: Date(timeIntervalSince1970: 1_790_000_000.125),
            inputTokens: 100, outputTokens: 10,
            cacheCreationTokens: 0, cacheReadTokens: 50)

        let first = try store.usage.insertReturningId(record)
        try expect(first.inserted)
        record.outputTokens = 30
        let second = try store.usage.insertReturningId(record)
        try expect(!second.inserted, "同一条记录第二次写入应被忽略")
        try expectEqual(second.id, first.id)
        try expectEqual(try store.usage.insert([record]), 0)

        record.timestamp = record.timestamp.addingTimeInterval(1)
        try expectEqual(try store.usage.insert([record]), 1, "不同时间点是另一条请求")

        let claude = try allTotals(store).first { $0.source == .claude }
        try expectEqual(claude?.requestCount, 2)
        try expectEqual(claude?.outputTokens, 30 + 30)
    }

    t.test("扫描进度丢失后重扫 Claude transcript 不重复入账") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-claude-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureURL("claude-transcript-usage-dups.jsonl"),
            to: dir.appendingPathComponent("s1.jsonl"))

        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 3)
        let before = try allTotals(store)

        try forgetScanProgress(store)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应算作新记录")
        try expectEqual(try allTotals(store), before)
    }

    t.test("扫描进度丢失后重扫 Codex rollout 不重复入账") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-codex-\(UUID().uuidString)", isDirectory: true)
        let dayDir = root.appendingPathComponent("2026/06/09", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"),
            to: dayDir.appendingPathComponent("rollout-2026-06-09T13-00-00-aaaa.jsonl"))

        let scanner = CodexUsageScanner(sessionsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 2)
        let before = try allTotals(store)

        try forgetScanProgress(store)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应算作新记录")
        try expectEqual(try allTotals(store), before)
    }

    t.test("Codex 重写 rollout 并改写事件时间戳：重扫仍认得是同一批请求") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-restamp-\(UUID().uuidString)", isDirectory: true)
        let dayDir = root.appendingPathComponent("2026/06/09", isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        let file = dayDir.appendingPathComponent("rollout-2026-06-09T13-00-00-aaaa.jsonl")
        let original = try String(
            contentsOf: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"), encoding: .utf8)
        try original.write(to: file, atomically: true, encoding: .utf8)

        let scanner = CodexUsageScanner(sessionsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 2)
        let before = try allTotals(store)

        // Codex rewrote old rollouts once (2026-09-08), giving replayed events the time of the
        // rewrite; the atomic write also gives the path a new inode
        let restamped = original
            .replacingOccurrences(of: #""timestamp":"2026-06-09T13:"#, with: #""timestamp":"2026-06-09T19:"#)
            .replacingOccurrences(of: #""timestamp":"2026-06-09T12:"#, with: #""timestamp":"2026-06-09T18:"#)
        try expect(restamped != original, "fixture 里应有可改写的时间戳")
        try restamped.write(to: file, atomically: true, encoding: .utf8)
        try expectEqual(try scanner.scanOnce(), 0, "改写时间戳后的同一批事件不是新请求")
        try expectEqual(try allTotals(store), before)
    }

    t.test("Claude 消息被读到一半、回填 output 后，重扫仍认得是同一行") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-stream-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s1.jsonl")

        // One message written as two content-block lines; the second carries a larger output
        func line(_ uuid: String, _ timestamp: String, output: Int) -> String {
            """
            {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","requestId":"req_S","message":{"id":"msg_S","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":7,"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":900},"content":[{"type":"text","text":"x"}]},"sessionId":"s","cwd":"/w"}
            """ + "\n"
        }
        try line("u1", "2026-07-06T10:00:00.000Z", output: 5)
            .write(to: file, atomically: true, encoding: .utf8)
        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 1)

        // The stream finishes after the first pass read it
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(line("u2", "2026-07-06T10:00:04.000Z", output: 20).utf8))
        try handle.close()
        try expectEqual(try scanner.scanOnce(), 0)

        try forgetScanProgress(store)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应算作新记录")
        let claude = try allTotals(store).first { $0.source == .claude }
        try expectEqual(claude?.requestCount, 1)
        try expectEqual(claude?.outputTokens, 20)
    }

    t.test("存量 Claude 旧行（读到一半入账、回填过 output 但时间戳没动）：重扫认出同一条") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-legacy-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Shape seen in a real subagent transcript: three lines, output 8 → 8 → 405
        func line(_ uuid: String, _ timestamp: String, output: Int) -> String {
            """
            {"type":"assistant","uuid":"\(uuid)","timestamp":"\(timestamp)","requestId":"req_L","message":{"id":"msg_L","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":2,"output_tokens":\(output),"cache_creation_input_tokens":40,"cache_read_input_tokens":28007},"content":[{"type":"text","text":"x"}]},"sessionId":"s","cwd":"/w"}
            """
        }
        try [
            line("u1", "2026-09-24T02:35:04.631Z", output: 8),
            line("u2", "2026-09-24T02:35:05.169Z", output: 8),
            line("u3", "2026-09-24T02:35:07.467Z", output: 405),
        ].joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        // What a pre-fix scan left behind: inserted at the first line, output back-filled later,
        // and the dedup key long pruned
        let firstLine = try expectSome(ISO8601DateFormatter.fractional.date(from: "2026-09-24T02:35:04.631Z"))
        try store.usage.insert([UsageRecord(
            source: .claude, model: "claude-opus-5", project: "w", sessionId: "s",
            timestamp: firstLine, inputTokens: 2, outputTokens: 405,
            cacheCreationTokens: 40, cacheReadTokens: 28007)])

        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 0, "旧行与这条消息是同一请求")
        try forgetScanProgress(store)
        try expectEqual(try scanner.scanOnce(), 0, "再次重扫依然命中")
        let rows = try store.usage.recentRecords(limit: 10)
        try expectEqual(rows.count, 1)
        try expectEqual(rows.first?.outputTokens, 405)
    }

    t.test("近期两个并行请求 token 完全相同、时间交错：仍记两条（跨度匹配只用于去重键可能已过期的旧消息）") {
        let store = try EurekaStore(path: makeLedgerStoreURL())
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-ledger-parallel-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Two subagents started together with the same prompt: same session, model and prompt-side
        // tokens, but distinct requests whose lines interleave
        let now = Date()
        func line(_ request: String, secondsAgo: Double, output: Int) -> String {
            let timestamp = ISO8601DateFormatter.fractional.string(
                from: now.addingTimeInterval(-secondsAgo))
            return """
            {"type":"assistant","uuid":"\(UUID().uuidString)","timestamp":"\(timestamp)","requestId":"req_\(request)","message":{"id":"msg_\(request)","model":"claude-opus-5","role":"assistant","usage":{"input_tokens":3,"output_tokens":\(output),"cache_creation_input_tokens":500,"cache_read_input_tokens":12000},"content":[{"type":"text","text":"x"}]},"sessionId":"s","cwd":"/w"}
            """
        }
        try [
            line("A", secondsAgo: 10, output: 8),
            line("B", secondsAgo: 6, output: 8),
            line("A", secondsAgo: 4, output: 300),
            line("B", secondsAgo: 2, output: 120),
        ].joined(separator: "\n").appending("\n")
            .write(to: dir.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 2)
        let claude = try allTotals(store).first { $0.source == .claude }
        try expectEqual(claude?.requestCount, 2)
        try expectEqual(claude?.outputTokens, 300 + 120)
    }

    t.suite("用量账本 · 存量重复行修复")

    /// Puts a store into the shape an existing install has: no unique index, duplicate copies
    /// of the same request (later copies carry the provider the scanner learned meanwhile).
    func seedLegacyLedger(at url: URL) throws -> (keptA: Int64, keptB: Int64) {
        let store = try EurekaStore(path: url)
        try store.db.execute("DROP INDEX idx_usage_record_key")
        func insert(
            _ source: String, _ session: String, _ ts: Double, output: Int, provider: String?
        ) throws -> Int64 {
            try store.db.run("""
            INSERT INTO usage_records
                (source, model, project, session_id, ts, input_tokens, output_tokens,
                 cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, provider)
            VALUES (?, 'm', 'p', ?, ?, 10, ?, 0, 0, 5, ?)
            """, [.text(source), .text(session), .real(ts), .int(Int64(output)), .string(provider)])
            return store.db.lastInsertRowID
        }
        let keptA = try insert("codex", "s1", 1000.5, output: 7, provider: nil)
        _ = try insert("codex", "s1", 1000.5, output: 7, provider: "openai")
        _ = try insert("codex", "s1", 1000.5, output: 7, provider: "openai")
        let keptB = try insert("claude", "s2", 2000.25, output: 5, provider: nil)
        let laterB = try insert("claude", "s2", 2000.25, output: 9, provider: nil)
        _ = try insert("claude", "s2", 3000, output: 4, provider: nil)
        try store.scanState.upsertDedupKey(
            "c:req:msg", recordId: laterB, outputTokens: 9, at: Date())
        return (keptA, keptB)
    }

    t.test("打开库时就地去重：保留最早一行、合并 provider 与最大 output、备份全部组内行") {
        let url = makeLedgerStoreURL()
        let kept = try seedLegacyLedger(at: url)

        let store = try EurekaStore(path: url)
        try expectEqual(store.usageLedgerRepair, .enforced(removedRows: 3))
        try expectEqual(try hasRecordKeyIndex(store), true)
        try expectEqual(try rowCount(store, "SELECT COUNT(*) FROM usage_records"), 3)

        let rowA = try store.db.query(
            "SELECT provider, output_tokens FROM usage_records WHERE id = ?",
            [.int(kept.keptA)]) { ($0.text(0), Int($0.int(1))) }.first
        try expectEqual(rowA?.0, "openai")
        try expectEqual(rowA?.1, 7)
        let rowB = try store.db.query(
            "SELECT output_tokens FROM usage_records WHERE id = ?",
            [.int(kept.keptB)]) { Int($0.int(0)) }.first
        try expectEqual(rowB, 9, "流式读到一半的旧行取组内最大 output")

        // Every row of an affected group is kept in the backup, so the repair can be undone
        try expectEqual(
            try rowCount(store, "SELECT COUNT(*) FROM usage_records_dedup_backup"), 5)
        try expectEqual(
            try rowCount(store, "SELECT COUNT(*) FROM usage_records_dedup_backup WHERE kept = 1"), 2)
        // A dedup key that pointed at a removed copy now points at the kept row
        let keyed = try store.scanState.existingDedupKeys(["c:req:msg"])["c:req:msg"]
        try expectEqual(keyed?.recordId, kept.keptB)
    }

    t.test("存量近似副本：token 全同且在来源窗口内（Codex 1 天、Claude 600 秒）的合并，其余保留") {
        let url = makeLedgerStoreURL()
        var ids: [String: Int64] = [:]
        do {
            let store = try EurekaStore(path: url)
            try store.db.execute("DROP INDEX idx_usage_record_key")
            func insert(
                _ name: String, _ source: String, _ session: String, _ ts: Double,
                output: Int, provider: String? = nil
            ) throws {
                try store.db.run("""
                INSERT INTO usage_records
                    (source, model, project, session_id, ts, input_tokens, output_tokens,
                     cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens, provider)
                VALUES (?, 'm', 'p', ?, ?, 100, ?, 0, 0, 50, ?)
                """, [.text(source), .text(session), .real(ts), .int(Int64(output)),
                      .string(provider)])
                ids[name] = store.db.lastInsertRowID
            }
            // Codex rewrote the rollout and re-stamped the event 3 hours later
            try insert("codexKept", "codex", "s1", 1_000, output: 7)
            try insert("codexCopy", "codex", "s1", 1_000 + 3 * 3_600, output: 7, provider: "openai")
            try insert("codexOtherOutput", "codex", "s1", 1_000 + 3_600, output: 8)
            try insert("codexTwoDaysLater", "codex", "s1", 1_000 + 2 * 86_400, output: 7)
            // Claude row read mid-stream plus the copy a later re-read stamped with the final line
            try insert("claudeKept", "claude", "s2", 5_000, output: 405)
            try insert("claudeCopy", "claude", "s2", 5_003, output: 405)
            try insert("claudeLater", "claude", "s2", 6_000, output: 405)
            // No evidence of near copies for other sources: left alone
            try insert("kimiA", "kimi", "s3", 9_000, output: 5)
            try insert("kimiB", "kimi", "s3", 9_010, output: 5)
            try store.scanState.upsertDedupKey(
                "c:req:copy", recordId: ids["claudeCopy"], outputTokens: 405, at: Date())
        }

        let store = try EurekaStore(path: url)
        try expectEqual(store.usageLedgerRepair, .enforced(removedRows: 2))
        let remaining = Set(try store.db.query("SELECT id FROM usage_records") { $0.int(0) })
        try expectEqual(
            remaining,
            Set(["codexKept", "codexOtherOutput", "codexTwoDaysLater", "claudeKept",
                 "claudeLater", "kimiA", "kimiB"].compactMap { ids[$0] }))
        let provider = try store.db.query(
            "SELECT provider FROM usage_records WHERE id = ?",
            [.int(ids["codexKept"] ?? -1)]) { $0.text(0) }.first
        try expectEqual(provider, "openai")
        try expectEqual(
            try rowCount(store, "SELECT COUNT(*) FROM usage_records_dedup_backup WHERE kept = 0"), 2)
        let keyed = try store.scanState.existingDedupKeys(["c:req:copy"])["c:req:copy"]
        try expectEqual(keyed?.recordId, ids["claudeKept"])
    }

    t.test("精确去重保留的行被近似副本阶段删掉：备份里的 kept 标记跟着改为 0") {
        let url = makeLedgerStoreURL()
        var ids: [String: Int64] = [:]
        do {
            let store = try EurekaStore(path: url)
            try store.db.execute("DROP INDEX idx_usage_record_key")
            func insert(_ name: String, _ ts: Double) throws {
                try store.db.run("""
                INSERT INTO usage_records
                    (source, model, session_id, ts, input_tokens, output_tokens,
                     cache_creation_tokens, cache_creation_1h_tokens, cache_read_tokens)
                VALUES ('codex', 'm', 's1', ?, 100, 7, 0, 0, 50)
                """, [.real(ts)])
                ids[name] = store.db.lastInsertRowID
            }
            // The re-stamped copy was scanned first, so it holds the oldest id; the real-time
            // event was then recorded twice
            try insert("restamped", 1_000 + 3 * 3_600)
            try insert("realTime", 1_000)
            try insert("realTimeCopy", 1_000)
        }

        let store = try EurekaStore(path: url)
        try expectEqual(store.usageLedgerRepair, .enforced(removedRows: 2))
        let remaining = try store.db.query("SELECT id FROM usage_records") { $0.int(0) }
        try expectEqual(remaining, [ids["restamped"] ?? -1])
        let flagged = try store.db.query(
            "SELECT id FROM usage_records_dedup_backup WHERE kept = 1") { $0.int(0) }
        try expectEqual(flagged, [ids["restamped"] ?? -1], "备份里只有真正留下的行标为 kept")
    }

    t.test("修复只做一次：再次打开是空操作，干净的库不建备份表") {
        let url = makeLedgerStoreURL()
        _ = try seedLegacyLedger(at: url)
        _ = try EurekaStore(path: url)

        let reopened = try EurekaStore(path: url)
        try expectEqual(reopened.usageLedgerRepair, .alreadyEnforced)
        try expectEqual(
            try rowCount(reopened, "SELECT COUNT(*) FROM usage_records_dedup_backup"), 5)

        let clean = try EurekaStore(path: makeLedgerStoreURL())
        try expectEqual(
            try rowCount(
                clean,
                "SELECT COUNT(*) FROM sqlite_master WHERE name = 'usage_records_dedup_backup'"),
            0)
    }

    t.test("9 个连接同时打开存量库：修复恰好执行一次") {
        for round in 0..<10 {
            let url = makeLedgerStoreURL()
            _ = try seedLegacyLedger(at: url)
            let lock = NSLock()
            var failures: [String] = []
            var outcomes: [UsageLedgerRepair] = []
            DispatchQueue.concurrentPerform(iterations: 9) { _ in
                do {
                    let store = try EurekaStore(path: url)
                    lock.lock(); outcomes.append(store.usageLedgerRepair); lock.unlock()
                } catch {
                    lock.lock(); failures.append("\(error)"); lock.unlock()
                }
            }
            try expect(failures.isEmpty, "round \(round): \(failures)")
            try expectEqual(
                outcomes.filter { $0 == .enforced(removedRows: 3) }.count, 1, "round \(round)")
            let store = try EurekaStore(path: url)
            try expectEqual(try rowCount(store, "SELECT COUNT(*) FROM usage_records"), 3)
            try expectEqual(
                try rowCount(store, "SELECT COUNT(*) FROM usage_records_dedup_backup"), 5)
        }
    }
}
