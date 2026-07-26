import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// CodeBuddy 审计扫描测试：fixture 按本机真实会话（~/.codebuddy，2026-07 实勘）的
/// function_call 行格式伪造（Claude 式工具名 + arguments JSON 字符串 + epoch 毫秒时间戳），
/// 路径/会话 id 全部换成假值；全程临时目录，不碰真实 ~/。
func codeBuddyAuditScannerTests(_ t: TestRunner) {
    t.suite("CodeBuddyAuditScanner · CodeBuddy 审计采集")

    func makeStore() throws -> EurekaStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cbaudit-\(UUID().uuidString)/test.sqlite")
        return try EurekaStore(path: url)
    }

    /// 临时 projects 树：<root>/<slug>/<sessionId>.jsonl
    func makeProjects(
        slug: String = "Users-me-work-demo", sessionId: String = "cb-parent-0001"
    ) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cbaudit-\(UUID().uuidString)", isDirectory: true)
        let projectDir = root.appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        return (root, projectDir.appendingPathComponent("\(sessionId).jsonl"))
    }

    func appendLines(_ lines: [String], to url: URL) throws {
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: url)
        }
    }

    t.test("解析混合行：function_call 成行 + kind/name/detail 映射，其余行跳过") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines([
            #"{"type":"message","role":"user","timestamp":1784975900000,"sessionId":"cb-parent-0001","cwd":"/w","content":[{"type":"input_text","text":"看一下代码"}]}"#,
            #"{"type":"function_call","timestamp":1784975901000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_1","name":"Bash","arguments":"{\"command\":\"ls -la\"}"}"#,
            #"{"type":"function_call","timestamp":1784975902000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_2","name":"Read","arguments":"{\"file_path\":\"/tmp/a.swift\"}"}"#,
            #"{"type":"function_call","timestamp":1784975903000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_3","name":"Grep","arguments":"{\"pattern\":\"foo\",\"path\":\"/tmp\"}"}"#,
            #"{"type":"function_call_result","timestamp":1784975904000,"callId":"call_1","output":"ok"}"#,
            #"{"type":"reasoning","timestamp":1784975905000}"#,
            #"{"type":"ai-title","aiTitle":"标题"}"#,
            "not json at all",
        ], to: file)

        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 3, "只有 3 行 function_call 应成行")

        let rows = try store.audit.recent(limit: 100)
        try expectEqual(rows.count, 3)
        try expect(rows.allSatisfy { $0.source == .codebuddy }, "来源应为 codebuddy")
        try expect(rows.allSatisfy { $0.sessionId == "cb-parent-0001" })
        try expect(rows.allSatisfy { $0.cwd == "/w" }, "cwd 应取行字段")

        func row(tool: String) -> AuditEvent? { rows.first { $0.tool == tool } }
        try expectEqual(row(tool: "Bash")?.kind, .command)
        try expectEqual(row(tool: "Bash")?.detail, "ls -la")
        try expectEqual(row(tool: "Bash")?.opId, "call_1")
        try expectEqual(row(tool: "Read")?.kind, .read)
        try expectEqual(row(tool: "Read")?.detail, "/tmp/a.swift")
        try expectEqual(row(tool: "Grep")?.kind, .search)
        try expectEqual(row(tool: "Grep")?.detail, "foo in /tmp")
    }

    t.test("幂等重扫 +0；水位跨 scanner 实例保留；追加只插新行") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines([
            #"{"type":"function_call","timestamp":1784975901000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_1","name":"Bash","arguments":"{\"command\":\"ls\"}"}"#,
        ], to: file)

        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 1)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应重复插入")

        // 新实例复用 scan_state 里的 "audit://" 水位
        let scanner2 = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner2.scanOnce(), 0, "水位应跨实例保留")

        try appendLines([
            #"{"type":"function_call","timestamp":1784975902000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_2","name":"Write","arguments":"{\"file_path\":\"/tmp/b.swift\"}"}"#,
        ], to: file)
        try expectEqual(try scanner2.scanOnce(), 1, "追加应只插新行")
        try expectEqual(try store.audit.count(), 2)
        try expectEqual(try store.audit.recent(limit: 1)[0].kind, .edit)
    }

    t.test("新鲜高危命令（Bash rm -rf）触发告警并标风险") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        try appendLines([
            #"{"type":"function_call","timestamp":\#(nowMs),"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_9","name":"Bash","arguments":"{\"command\":\"sudo rm -rf /tmp/x\"}"}"#,
        ], to: file)

        var alerts: [RiskAlert] = []
        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce { alerts.append($0) }, 1)
        try expectEqual(alerts.count, 1, "rm -rf 绝对路径应高危告警")
        try expectEqual(alerts.first?.ruleId, "rm-rf")
        try expectEqual(alerts.first?.source, .codebuddy)
        try expectEqual(try store.audit.recent(limit: 1)[0].riskRule, "rm-rf")
    }

    t.test("陈旧高危事件（旧时间戳）只入库标风险不告警") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines([
            #"{"type":"function_call","timestamp":1577836800000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_old","name":"Bash","arguments":"{\"command\":\"rm -rf /tmp/y\"}"}"#,
        ], to: file)

        var alerts: [RiskAlert] = []
        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce { alerts.append($0) }, 1)
        try expect(alerts.isEmpty, "陈旧高危事件不应告警")
        try expectEqual(try store.audit.count(.init(riskOnly: true)), 1)
    }

    t.test("子代理文件归属父会话 id（行内 sessionId 是子代理自己的，不采用）") {
        let store = try makeStore()
        let (root, _) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let subagentsDir = root.appendingPathComponent(
            "Users-me-work-demo/cb-parent-0001/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try appendLines([
            #"{"type":"function_call","timestamp":1784975901000,"sessionId":"cb-child-9999","cwd":"/w","callId":"call_s1","name":"Glob","arguments":"{\"pattern\":\"**/*.swift\"}"}"#,
        ], to: subagentsDir.appendingPathComponent("agent-ab12.jsonl"))

        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 1)
        let row = try store.audit.recent(limit: 1)[0]
        try expectEqual(row.sessionId, "cb-parent-0001", "子代理调用应归父会话（路径推导）")
        try expectEqual(row.kind, .search)
        try expectEqual(row.detail, "**/*.swift")
    }

    t.test("半行不消费，补全后插入") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let line =
            #"{"type":"function_call","timestamp":1784975901000,"sessionId":"cb-parent-0001","cwd":"/w","callId":"call_1","name":"Bash","arguments":"{\"command\":\"ls\"}"}"#
        let half = String(line.prefix(line.count / 2))
        try Data(half.utf8).write(to: file)

        let scanner = CodeBuddyAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 0, "半行不应消费")

        let handle = try FileHandle(forWritingTo: file)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data((String(line.suffix(line.count - line.count / 2)) + "\n").utf8))
        try handle.close()
        try expectEqual(try scanner.scanOnce(), 1, "补全后应插入")
        try expectEqual(try store.audit.count(), 1)
    }
}
