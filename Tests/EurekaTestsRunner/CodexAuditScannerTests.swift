import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func codexAuditScannerTests(_ t: TestRunner) {
    t.suite("CodexAuditScanner · Codex 审计采集")

    func makeStore() throws -> EurekaStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-auditscan-\(UUID().uuidString)/test.sqlite")
        return try EurekaStore(path: url)
    }

    /// 今天日期目录（rolloutFiles 按 Date() 回看）
    func makeDayDir() throws -> (root: URL, dayDir: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-auditscan-\(UUID().uuidString)", isDirectory: true)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        let dayDir = root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: dayDir, withIntermediateDirectories: true)
        return (root, dayDir)
    }

    t.test("解析 trail fixture：function_call/mcp/web 成行，_ 前缀跳过，exit_code 回填") {
        let store = try makeStore()
        let (root, dayDir) = try makeDayDir()
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-trail.jsonl"),
            to: dayDir.appendingPathComponent("rollout-2026-07-01T12-00-00-trail.jsonl"))

        let scanner = CodexAuditScanner(
            sessionsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        let inserted = try scanner.scanOnce()
        // exec_command + mcp + web_search + shell = 4（_query-docs 跳过）
        try expectEqual(inserted, 4)

        let rows = try store.audit.recent(limit: 100)
        try expectEqual(rows.count, 4)

        func row(tool: String) -> AuditEvent? { rows.first { $0.tool == tool } }
        let exec = row(tool: "exec_command")
        try expectEqual(exec?.kind, .command)
        try expectEqual(exec?.detail, "ls -la")
        try expectEqual(exec?.exitCode, 1, "function_call_output exit_code=1 应回填")
        try expect(exec?.isError == true)

        try expectEqual(row(tool: "context7.query-docs")?.kind, .mcp)
        try expect(row(tool: "context7.query-docs")?.isError == true, "mcp result.Err 应置失败")
        try expectEqual(row(tool: "context7.query-docs")?.detail, "swiftpm resources")

        let web = row(tool: "web_search")
        try expectEqual(web?.kind, .web)
        try expectEqual(web?.detail, "SwiftPM resources copy")

        let shell = row(tool: "shell")
        try expectEqual(shell?.kind, .command)
        try expectEqual(shell?.detail, "swift test")

        try expect(rows.first { $0.tool == "_query-docs" } == nil, "_ 前缀 MCP 代理应跳过")
    }

    t.test("幂等重扫：offset 已过，+0") {
        let store = try makeStore()
        let (root, dayDir) = try makeDayDir()
        try FileManager.default.copyItem(
            at: fixtureURL("codex-rollout-trail.jsonl"),
            to: dayDir.appendingPathComponent("rollout-2026-07-01T12-00-00-trail.jsonl"))
        let scanner = CodexAuditScanner(
            sessionsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 4)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应重复插入")
        try expectEqual(try store.audit.count(), 4)
    }

    t.test("陈旧事件（fixture 旧时间戳）只入库不告警") {
        let store = try makeStore()
        let (root, dayDir) = try makeDayDir()
        // 写一条高危命令，但用很旧的时间戳 → stale
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s-old","cwd":"/w"}}"#,
            #"{"type":"response_item","timestamp":"2020-01-01T00:00:00.000Z","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"bash\",\"-lc\",\"sudo rm -rf /\"]}","call_id":"c1"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(
            to: dayDir.appendingPathComponent("rollout-stale.jsonl"),
            atomically: true, encoding: .utf8)

        var alerts: [RiskAlert] = []
        let scanner = CodexAuditScanner(
            sessionsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce { alerts.append($0) }, 1)
        try expect(alerts.isEmpty, "陈旧高危事件不应告警")
        // 但入库并标了风险
        try expectEqual(try store.audit.count(.init(riskOnly: true)), 1)
        try expectEqual(try store.audit.recent(limit: 1)[0].riskRule, "rm-rf")
    }

    t.test("新鲜高危事件触发告警") {
        let store = try makeStore()
        let (root, dayDir) = try makeDayDir()
        let nowISO = ISO8601DateFormatter().string(from: Date())
        let lines = [
            #"{"type":"session_meta","payload":{"id":"s-fresh","cwd":"/w"}}"#,
            #"{"type":"response_item","timestamp":"\#(nowISO)","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"sudo rm -rf /tmp/x\"}","call_id":"c9"}}"#,
        ].joined(separator: "\n") + "\n"
        try lines.write(
            to: dayDir.appendingPathComponent("rollout-fresh.jsonl"),
            atomically: true, encoding: .utf8)

        var alerts: [RiskAlert] = []
        let scanner = CodexAuditScanner(
            sessionsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        _ = try scanner.scanOnce { alerts.append($0) }
        try expectEqual(alerts.count, 1)
        try expectEqual(alerts.first?.ruleId, "rm-rf")
        try expectEqual(alerts.first?.source, .codex)
    }
}
