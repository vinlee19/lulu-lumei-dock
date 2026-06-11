import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

private func makeStore() throws -> EurekaStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("eureka-usage-\(UUID().uuidString)/test.sqlite")
    return try EurekaStore(path: url)
}

private func copyFixtureToTemp(_ fixture: String, as name: String, in dir: URL) throws -> URL {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dst = dir.appendingPathComponent(name)
    try FileManager.default.copyItem(at: fixtureURL(fixture), to: dst)
    return dst
}

func claudeScannerTests(_ t: TestRunner) {
    t.suite("ClaudeTranscriptScanner")

    t.test("流式重复行去重：同 (requestId,message.id) 只记一次") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        _ = try copyFixtureToTemp(
            "claude-transcript-usage-dups.jsonl", as: "s1.jsonl",
            in: root.appendingPathComponent("-Users-me-work-demo"))

        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        let inserted = try scanner.scanOnce()
        // fixture: msg_01AAA 重复两行 → 1 条；msg_01BBB 1 条；sidechain msg_01CCC 1 条
        try expectEqual(inserted, 3)

        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date())
        let fable = totals.first { $0.model == "claude-fable-5" }
        try expectEqual(fable?.requestCount, 2)
        try expectEqual(fable?.inputTokens, 1200 + 3400)
        // 流式重复行 output 递增（40 → 100），应取最终值
        try expectEqual(fable?.outputTokens, 100 + 250)
        try expectEqual(fable?.cacheCreation1hTokens, 500)
        let haiku = totals.first { $0.model.hasPrefix("claude-haiku") }
        try expectEqual(haiku?.requestCount, 1, "sidechain 用量也要记")
    }

    t.test("跨扫描回填：第一轮记了部分 output，第二轮见到更大值要更新") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        let dir = root.appendingPathComponent("-Users-me-work-demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("s1.jsonl")

        func assistantLine(output: Int) -> String {
            """
            {"type":"assistant","uuid":"u-x","timestamp":"2026-06-09T10:00:05.000Z","requestId":"req_X","message":{"id":"msg_X","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":500,"output_tokens":\(output),"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}},"sessionId":"s","cwd":"/w"}

            """
        }
        try Data(assistantLine(output: 30).utf8).write(to: file)
        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 1)

        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(assistantLine(output: 220).utf8))
        try handle.close()
        try expectEqual(try scanner.scanOnce(), 0, "重复键不算新增")

        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date())
        try expectEqual(totals.first?.outputTokens, 220, "应回填为最终 output")
        try expectEqual(totals.first?.requestCount, 1)
    }

    t.test("增量扫描：第二次扫描无新增；追加行只记增量") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        let file = try copyFixtureToTemp(
            "claude-transcript-usage-dups.jsonl", as: "s1.jsonl",
            in: root.appendingPathComponent("-Users-me-work-demo"))

        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        _ = try scanner.scanOnce()
        try expectEqual(try scanner.scanOnce(), 0, "offset 之后无新内容")

        // 追加一条新 assistant 行
        let newLine = """
        {"type":"assistant","uuid":"u-9","timestamp":"2026-06-09T11:00:00.000Z","requestId":"req_NEW","message":{"id":"msg_NEW","model":"claude-fable-5","role":"assistant","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"cache_creation":{"ephemeral_1h_input_tokens":0,"ephemeral_5m_input_tokens":0}}},"sessionId":"fixture-session-1","cwd":"/Users/me/work/demo"}

        """
        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data(newLine.utf8))
        try handle.close()
        try expectEqual(try scanner.scanOnce(), 1)
    }

    t.test("resume 复制旧行到新文件：跨文件去重不重复记账") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent("-Users-me-work-demo")
        _ = try copyFixtureToTemp(
            "claude-transcript-usage-dups.jsonl", as: "s1.jsonl", in: projectDir)
        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        let first = try scanner.scanOnce()

        // 模拟 resume：同内容复制成新会话文件
        try FileManager.default.copyItem(
            at: projectDir.appendingPathComponent("s1.jsonl"),
            to: projectDir.appendingPathComponent("s2-resumed.jsonl"))
        try expectEqual(try scanner.scanOnce(), 0, "复制文件的行已全局去重")
        try expectEqual(first, 3)
    }

    t.test("会话级费用：sessionId 入库且可按会话聚合") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        _ = try copyFixtureToTemp(
            "claude-transcript-usage-dups.jsonl", as: "s1.jsonl",
            in: root.appendingPathComponent("-Users-me-work-demo"))
        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        _ = try scanner.scanOnce()

        let bySession = try store.usage.totalsForSessions(["fixture-session-1", "ghost"])
        let rows = bySession["fixture-session-1"]
        try expect(rows != nil, "应有该会话的聚合")
        let fable = rows?.first { $0.model == "claude-fable-5" }
        try expectEqual(fable?.inputTokens, 1200 + 3400)
        try expect(bySession["ghost"] == nil)
    }

    t.test("synthetic 错误行不记用量") {
        let store = try makeStore()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-claude-\(UUID().uuidString)", isDirectory: true)
        _ = try copyFixtureToTemp(
            "claude-transcript-api-error.jsonl", as: "s1.jsonl",
            in: root.appendingPathComponent("-Users-me-work-demo"))
        let scanner = ClaudeTranscriptScanner(projectsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 0)
    }
}

func codexScannerTests(_ t: TestRunner) {
    t.suite("CodexUsageScanner")

    func makeSessionsDir() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-codexscan-\(UUID().uuidString)", isDirectory: true)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        return root
    }
    func dayDir(_ root: URL) -> URL {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        return root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
    }

    t.test("相邻差值法记账") {
        let store = try makeStore()
        let root = try makeSessionsDir()
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-token-count-ratelimits.jsonl"),
            to: dayDir(root).appendingPathComponent("rollout-2026-06-09T13-00-00-aaaa.jsonl"))

        let scanner = CodexUsageScanner(sessionsRoot: root, store: store)
        try expectEqual(try scanner.scanOnce(), 2)

        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date())
        let codex = totals.first { $0.source == .codex }
        // 事件1: in=10000(cached 2000) out=500 → 记 in=8000 cached=2000 out=500
        // 事件2: 差值 in=6000(cached 3000) out=800 → 记 in=3000 cached=3000 out=800
        try expectEqual(codex?.inputTokens, 8000 + 3000)
        try expectEqual(codex?.cacheReadTokens, 2000 + 3000)
        try expectEqual(codex?.outputTokens, 500 + 800)
    }

    t.test("compaction 计数回落：回退 last_token_usage 不算负数") {
        let store = try makeStore()
        let root = try makeSessionsDir()
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-compaction.jsonl"),
            to: dayDir(root).appendingPathComponent("rollout-2026-06-09T14-00-00-bbbb.jsonl"))

        let scanner = CodexUsageScanner(sessionsRoot: root, store: store)
        _ = try scanner.scanOnce()
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date())
        let codex = totals.first { $0.source == .codex }
        // 事件1 全量 200000/150000/8000；事件2 回落 → last(30000/10000/1000)；
        // 事件3 差值 12000/5000/600
        try expectEqual(codex?.inputTokens, 50000 + 20000 + 7000)
        try expectEqual(codex?.cacheReadTokens, 150_000 + 10000 + 5000)
        try expectEqual(codex?.outputTokens, 8000 + 1000 + 600)
        try expect((codex?.inputTokens ?? -1) >= 0, "绝不能出负数")
    }
}

func pricingTests(_ t: TestRunner) {
    t.suite("PricingTable")

    let table = PricingTable(models: [
        ModelPrice(match: "claude-opus-4-7", unknown: nil, inputPerM: 5, outputPerM: 25,
                   cacheReadPerM: 0.5, cacheWrite5mPerM: 6.25, cacheWrite1hPerM: 10),
        ModelPrice(match: "claude-opus", unknown: nil, inputPerM: 15, outputPerM: 75,
                   cacheReadPerM: nil, cacheWrite5mPerM: nil, cacheWrite1hPerM: nil),
        ModelPrice(match: "gpt-5.5", unknown: true, inputPerM: nil, outputPerM: nil,
                   cacheReadPerM: nil, cacheWrite5mPerM: nil, cacheWrite1hPerM: nil),
        ModelPrice(match: "gpt-5", unknown: nil, inputPerM: 1.25, outputPerM: 10,
                   cacheReadPerM: 0.125, cacheWrite5mPerM: nil, cacheWrite1hPerM: nil),
    ])

    t.test("最长前缀优先") {
        try expectEqual(table.price(for: "claude-opus-4-7-20260101")?.inputPerM, 5)
        try expectEqual(table.price(for: "claude-opus-4-1")?.inputPerM, 15)
    }

    t.test("unknown 哨兵阻断家族回退") {
        try expect(table.price(for: "gpt-5.5") == nil, "gpt-5.5 明确未定价")
        try expectEqual(table.price(for: "gpt-5-codex")?.inputPerM, 1.25)
    }

    t.test("费用计算含缓存分价（1h=2x、5m=1.25x、读=0.1x 缺省推导）") {
        let totals = UsageTotals(
            source: .claude, model: "claude-opus-4-1",
            inputTokens: 1_000_000, outputTokens: 100_000,
            cacheCreationTokens: 200_000, cacheCreation1hTokens: 50_000,
            cacheReadTokens: 500_000, requestCount: 1)
        // 15 + 7.5 + 读 0.5M*1.5=0.75 + 5m 写 150k*18.75/M=2.8125 + 1h 写 50k*30/M=1.5
        let cost: Double = table.cost(of: totals) ?? 0
        let expected: Double = 15.0 + 7.5 + 0.75 + 2.8125 + 1.5
        try expect(abs(cost - expected) < 0.0001, "got \(cost)")
    }

    t.test("未定价模型 cost 返回 nil") {
        let totals = UsageTotals(
            source: .codex, model: "gpt-5.5", inputTokens: 1000, outputTokens: 100,
            cacheCreationTokens: 0, cacheCreation1hTokens: 0, cacheReadTokens: 0,
            requestCount: 1)
        try expect(table.cost(of: totals) == nil)
    }
}

func aggregatorTests(_ t: TestRunner) {
    t.suite("UsageAggregator")

    t.test("今日/本周窗口：跨午夜与周一边界") {
        let store = try makeStore()
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current

        // 2026-06-10 是周三。周起点应为 6-08（周一）
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 10, hour: 15))!
        let monday = UsageAggregator.weekStart(of: now, calendar: calendar)
        let mondayParts = calendar.dateComponents([.year, .month, .day], from: monday)
        try expectEqual(mondayParts.day, 8)

        func record(_ day: Int, _ hour: Int, tokens: Int) -> UsageRecord {
            UsageRecord(
                source: .claude, model: "claude-fable-5",
                timestamp: calendar.date(from: DateComponents(
                    year: 2026, month: 6, day: day, hour: hour))!,
                inputTokens: tokens, outputTokens: 0)
        }
        try store.usage.insert([
            record(10, 9, tokens: 100),   // 今日
            record(9, 23, tokens: 50),    // 昨日（本周内）
            record(7, 12, tokens: 7),     // 上周日（窗口外）
        ])

        let pricing = PricingTable(models: [])
        let summary = try UsageAggregator.summarize(
            store: store, pricing: pricing, now: now, calendar: calendar)
        try expectEqual(summary.today.first?.inputTokens, 100)
        try expectEqual(summary.thisWeek.first?.inputTokens, 150)
        // 6-07（上周日）在本周窗口外、本月窗口内
        try expectEqual(summary.thisMonth.first?.inputTokens, 157)
    }

    t.test("月度窗口：上月数据不计入") {
        let store = try makeStore()
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(
            year: 2026, month: 6, day: 10, hour: 15))!
        try store.usage.insert([
            UsageRecord(
                source: .claude, model: "m",
                timestamp: calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!,
                inputTokens: 10, outputTokens: 0),
            UsageRecord(
                source: .claude, model: "m",
                timestamp: calendar.date(from: DateComponents(year: 2026, month: 5, day: 31))!,
                inputTokens: 999, outputTokens: 0),
        ])
        let summary = try UsageAggregator.summarize(
            store: store, pricing: PricingTable(models: []), now: now, calendar: calendar)
        try expectEqual(summary.thisMonth.first?.inputTokens, 10)
    }
}
