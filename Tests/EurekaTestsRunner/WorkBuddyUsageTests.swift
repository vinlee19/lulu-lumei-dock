import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSync
import EurekaUsage
import Foundation

// WorkBuddy usage-side tests: token ledger, quota card, and the transcript scrubbing that guards
// the backup. Fixtures come from WorkBuddyFixture (WorkBuddyIngestTests.swift).

func workBuddyUsageScannerTests(_ t: TestRunner) {
    t.suite("CodeBuddyUsageScanner (WorkBuddy)")
    typealias F = WorkBuddyFixture

    t.test("末条助手消息上的用量也入账；提问只数真正的一轮；DeferExecuteTool 记真实工具") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([
            F.prompt("画一张图", ts: 1_793_618_000_000),
            F.call("DeferExecuteTool", args: ["toolName": "ImageGen", "params": [:]],
                   ts: 1_793_618_001_000, callId: "c1",
                   usage: F.usage(input: 32_916, cached: 31_744, output: 103), messageId: "m1"),
            F.result("DeferExecuteTool", callId: "c1", ts: 1_793_618_002_000),
            F.steer("换个颜色", ts: 1_793_618_002_500),
            F.compactionSummary(ts: 1_793_618_002_600),
            F.assistant("画好了", ts: 1_793_618_003_000,
                        usage: F.usage(input: 34_000, cached: 32_000, output: 200), messageId: "m2"),
        ], to: session.file)
        let store = try EurekaStore(path: session.home.appendingPathComponent("eureka.sqlite"))
        let scanner = CodeBuddyUsageScanner(
            projectsRoot: session.home.appendingPathComponent("projects"), store: store,
            dialect: .workbuddy,
            workspaceRoot: URL(fileURLWithPath: "/Users/demo/WorkBuddy"))
        try expectEqual(try scanner.scanOnce(), 2, "function_call 与末条助手消息各一条")

        let rows = (try store.usage.totalsForSessions([F.sessionId]))[F.sessionId] ?? []
        try expectEqual(rows.count, 1)
        try expectEqual(rows.first?.model, "deepseek-v4.1-flash")
        try expectEqual(rows.first?.inputTokens, (32_916 - 31_744) + (34_000 - 32_000))
        try expectEqual(rows.first?.cacheReadTokens, 31_744 + 32_000)
        try expectEqual(rows.first?.outputTokens, 303)
        try expectEqual(
            try store.sessionStats.promptCounts(for: [F.sessionId])[F.sessionId] ?? 0, 1,
            "插话和压缩摘要不算提问")

        let tools = try store.toolCalls.totals(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000),
            source: .workbuddy)
        try expectEqual(tools.first?.name, "ImageGen")
        try expectEqual(try scanner.scanOnce(), 0, "重扫幂等")
    }

    t.test("定时任务的 token 照常入账；WorkBuddy 工作目录归到同一个项目") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        try F.append([
            F.prompt("每日简报", ts: 1_793_618_000_000, automation: true),
            F.assistant("已发送", ts: 1_793_618_001_000,
                        usage: F.usage(input: 1000, cached: 0, output: 50), messageId: "m1"),
        ], to: session.file)
        let store = try EurekaStore(path: session.home.appendingPathComponent("eureka.sqlite"))
        let scanner = CodeBuddyUsageScanner(
            projectsRoot: session.home.appendingPathComponent("projects"), store: store,
            dialect: .workbuddy,
            workspaceRoot: URL(fileURLWithPath: "/Users/demo/WorkBuddy"))
        try expectEqual(try scanner.scanOnce(), 1)
        let ledger = try SQLiteDB(
            path: session.home.appendingPathComponent("eureka.sqlite").path, readOnly: true)
        let projects = try ledger.query(
            "SELECT DISTINCT project FROM usage_records WHERE source = 'workbuddy'") { $0.text(0) }
        try expectEqual(projects, ["WorkBuddy"])
    }
}

func workBuddyQuotaProviderTests(_ t: TestRunner) {
    t.suite("WorkBuddyQuotaProvider")
    typealias F = WorkBuddyFixture

    func quotaLine(percent: Int, resetAt: Date, ts: Date) -> String {
        F.json([
            "type": "function_call", "name": "Read", "callId": UUID().uuidString,
            "sessionId": F.sessionId, "timestamp": Int64(ts.timeIntervalSince1970 * 1000),
            "providerData": ["model": "hy4-free", "rawUsage": [
                "credit": 0,
                "quota": ["model": "hy4", "percent": percent,
                          "reset_at": String(Int(resetAt.timeIntervalSince1970)),
                          "shared_models": []]]],
        ])
    }

    t.test("取每个模型最新的额度；重置时间已过则整块隐藏") {
        let session = try F.makeHome()
        defer { try? FileManager.default.removeItem(at: session.home) }
        let now = Date()
        let reset = now.addingTimeInterval(3600)
        try F.append([
            quotaLine(percent: 1, resetAt: reset, ts: now.addingTimeInterval(-600)),
            F.call("Read", ts: 1, callId: "plain"),
            quotaLine(percent: 3, resetAt: reset, ts: now.addingTimeInterval(-60)),
        ], to: session.file)
        let provider = WorkBuddyQuotaProvider(
            projectsRoot: session.home.appendingPathComponent("projects"))
        let snapshot = provider.snapshot(now: now)
        try expectEqual(snapshot?.source, .workbuddy)
        try expectEqual(snapshot?.scopedWindows.count, 1)
        try expectEqual(snapshot?.scopedWindows.first?.usedPercent, 3)
        try expectEqual(snapshot?.scopedWindows.first?.label, "hy4")
        try expect(provider.snapshot(now: reset.addingTimeInterval(1)) == nil,
                   "重置后旧额度不该再显示")
    }
}

func workBuddyScrubberTests(_ t: TestRunner) {
    t.suite("WorkBuddyTranscriptScrubber")

    func lines(_ data: Data) -> [[String: Any]] {
        String(decoding: data, as: UTF8.self).split(separator: "\n").map {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] ?? [:]
        }
    }

    t.test("带敏感保护的行整行换成占位；其余行逐值脱敏且保持合法 JSON") {
        let protected = #"{"type":"function_call_result","id":"r1","sessionId":"s","timestamp":5,"output":{"text":"pw=hunter2"},"__codebuddyLocal":{"sensitiveProtection":{"items":[{"plaintext":"hunter2","ciphertext":"x"}]}}}"#
        let command = #"{"type":"function_call","id":"f1","arguments":"{\"command\":\"export API_TOKEN=abc123 && curl -H 'Authorization: Bearer sk-abcdefghijklmnopqrstuv' https://x\"}","cwd":"/w"}"#
        let input = Data((protected + "\n" + command + "\n" + "not json\n").utf8)
        let output = WorkBuddyTranscriptScrubber.scrub(input)
        let text = String(decoding: output, as: UTF8.self)
        try expect(!text.contains("hunter2"), "敏感原文不能上传")
        try expect(!text.contains("abc123") && !text.contains("sk-abcdefghijklmnopqrstuv"),
                   "命令里的密钥要脱敏: \(text)")
        let parsed = lines(output)
        try expectEqual(parsed.count, 3, "行数不变")
        try expectEqual(parsed[0]["type"] as? String, "eureka-redacted")
        try expectEqual(parsed[0]["id"] as? String, "r1")
        try expectEqual(parsed[1]["type"] as? String, "function_call")
        try expectEqual(parsed[1]["cwd"] as? String, "/w", "其余字段原样保留")
        try expectEqual(parsed[2]["type"] as? String, "eureka-redacted", "解析不了的行不原样上传")
        try expect(text.hasSuffix("\n"), "保留结尾换行")
    }

    t.test("受保护的明文在其他行（含键名）也被遮掉；只是提到字段名的行不会被整行丢掉") {
        let secret = "ak-9f8e7d6c5b4a3210"
        let prompt = #"{"type":"message","role":"user","id":"u1","content":[{"type":"input_text","text":"<user_query>用这个 key \#(secret) 调一下</user_query>"}]}"#
        let toolOutput = #"{"type":"function_call_result","id":"r0","output":{"\#(secret)":"key as a field name"}}"#
        let protected = #"{"type":"function_call_result","id":"r1","output":{"text":"x"},"__codebuddyLocal":{"sensitiveProtection":{"items":[{"plaintext":"\#(secret)","ciphertext":"c"},{"plaintext":"abc"}]}}}"#
        let mention = #"{"type":"message","role":"assistant","id":"a1","content":[{"type":"output_text","text":"WorkBuddy keeps a sensitiveProtection record"}]}"#
        let shortValue = #"{"type":"message","role":"assistant","id":"a2","content":[{"type":"output_text","text":"abc stays"}]}"#
        let output = WorkBuddyTranscriptScrubber.scrub(
            Data([prompt, toolOutput, protected, mention, shortValue].joined(separator: "\n").utf8))
        let text = String(decoding: output, as: UTF8.self)
        try expect(!text.contains(secret), "受保护的明文不能出现在任何一行: \(text)")
        let parsed = lines(output)
        try expectEqual(parsed.count, 5)
        try expectEqual(parsed[0]["type"] as? String, "message", "提问行保留，只遮明文")
        try expectEqual(parsed[2]["type"] as? String, "eureka-redacted")
        try expectEqual(parsed[3]["type"] as? String, "message", "按键名识别保护记录，正文提到字段名不算")
        try expect(text.contains("abc stays"), "太短的值不做全文遮盖")
        try expect(!text.hasSuffix("\n"), "原文没有结尾换行就不加")
    }
}
