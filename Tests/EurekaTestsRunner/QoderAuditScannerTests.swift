import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

/// Qoder 审计扫描测试：fixture 按本机真实会话（~/.qoder-cn，v1.1.5 实勘）的行格式伪造
/// （Claude 式信封，assistant message.content[] 里的 tool_use 块，ISO-8601 时间戳），
/// 路径/会话 id 全部换成假值；全程临时目录，不碰真实 ~/。
func qoderAuditScannerTests(_ t: TestRunner) {
    t.suite("QoderAuditScanner · Qoder 审计采集")

    func makeStore() throws -> EurekaStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-qdaudit-\(UUID().uuidString)/test.sqlite")
        return try EurekaStore(path: url)
    }

    /// 临时 projects 树：<root>/<slug>/<sessionId>.jsonl
    func makeProjects(
        slug: String = "-Users-me-work-demo", sessionId: String = "qd-parent-0001"
    ) throws -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-qdaudit-\(UUID().uuidString)", isDirectory: true)
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

    t.test("解析混合行：tool_use 成行（一行多块各成一行）+ kind/name/detail 映射，其余行跳过") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines([
            #"{"type":"workspace-directories","sessionId":"qd-parent-0001","directories":["/w"]}"#,
            #"{"type":"runtime-config","sessionId":"qd-parent-0001","model":"qmodel_preview","timestamp":1784958130939}"#,
            #"{"type":"user","uuid":"u1","timestamp":"2026-07-25T05:47:30.143Z","message":{"role":"user","content":"分析项目"},"origin":{"kind":"human"},"cwd":"/w","sessionId":"qd-parent-0001"}"#,
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:46.643Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"..."},{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls -la"}},{"type":"tool_use","id":"call_2","name":"Read","input":{"file_path":"/tmp/a.swift"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-07-25T05:47:50.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_3","name":"Grep","input":{"pattern":"foo","path":"/tmp"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
            #"{"type":"assistant","uuid":"a3","timestamp":"2026-07-25T05:48:10.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"完成"}]},"sessionId":"qd-parent-0001"}"#,
            #"{"type":"system","uuid":"s1","timestamp":"2026-07-25T05:45:19.309Z","subtype":"informational","content":"x","sessionId":"qd-parent-0001"}"#,
            "not json at all",
        ], to: file)

        let scanner = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 3, "2 行 assistant 共 3 个 tool_use 块应成行")

        let rows = try store.audit.recent(limit: 100)
        try expectEqual(rows.count, 3)
        try expect(rows.allSatisfy { $0.source == .qoder }, "来源应为 qoder")
        try expect(rows.allSatisfy { $0.sessionId == "qd-parent-0001" })
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
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:46.643Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
        ], to: file)

        let scanner = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 1)
        try expectEqual(try scanner.scanOnce(), 0, "重扫不应重复插入")

        // 新实例复用 scan_state 里的 "audit://" 水位
        let scanner2 = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner2.scanOnce(), 0, "水位应跨实例保留")

        try appendLines([
            #"{"type":"assistant","uuid":"a2","timestamp":"2026-07-25T05:47:50.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_2","name":"Write","input":{"file_path":"/tmp/b.swift"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
        ], to: file)
        try expectEqual(try scanner2.scanOnce(), 1, "追加应只插新行")
        try expectEqual(try store.audit.count(), 2)
        try expectEqual(try store.audit.recent(limit: 1)[0].kind, .edit)
    }

    t.test("新鲜高危命令（Bash rm -rf）触发告警并标风险") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let nowISO = formatter.string(from: Date())
        try appendLines([
            #"{"type":"assistant","uuid":"a9","timestamp":"\#(nowISO)","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_9","name":"Bash","input":{"command":"sudo rm -rf /tmp/x"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
        ], to: file)

        var alerts: [RiskAlert] = []
        let scanner = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce { alerts.append($0) }, 1)
        try expectEqual(alerts.count, 1, "rm -rf 绝对路径应高危告警")
        try expectEqual(alerts.first?.ruleId, "rm-rf")
        try expectEqual(alerts.first?.source, .qoder)
        try expectEqual(try store.audit.recent(limit: 1)[0].riskRule, "rm-rf")
    }

    t.test("陈旧高危事件（旧时间戳）只入库标风险不告警") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        try appendLines([
            #"{"type":"assistant","uuid":"a8","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_8","name":"Bash","input":{"command":"rm -rf /tmp/y"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
        ], to: file)

        var alerts: [RiskAlert] = []
        let scanner = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce { alerts.append($0) }, 1)
        try expect(alerts.isEmpty, "陈旧高危事件不应告警")
        try expectEqual(try store.audit.count(.init(riskOnly: true)), 1)
    }

    t.test("子代理文件归属父会话 id（路径推导）") {
        let store = try makeStore()
        let (root, _) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let subagentsDir = root.appendingPathComponent(
            "-Users-me-work-demo/qd-parent-0001/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: subagentsDir, withIntermediateDirectories: true)
        try appendLines([
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:52.240Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_s1","name":"Glob","input":{"pattern":"**/*.swift"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#,
        ], to: subagentsDir.appendingPathComponent("agent-aExplore-ab12.jsonl"))

        let scanner = QoderAuditScanner(
            projectsRoot: root, store: store, pipeline: AuditPipeline(store: store))
        try expectEqual(try scanner.scanOnce(), 1)
        let row = try store.audit.recent(limit: 1)[0]
        try expectEqual(row.sessionId, "qd-parent-0001", "子代理调用应归父会话（路径推导）")
        try expectEqual(row.kind, .search)
        try expectEqual(row.detail, "**/*.swift")
    }

    t.test("半行不消费，补全后插入") {
        let store = try makeStore()
        let (root, file) = try makeProjects()
        defer { try? FileManager.default.removeItem(at: root) }
        let line =
            #"{"type":"assistant","uuid":"a1","timestamp":"2026-07-25T05:47:46.643Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"call_1","name":"Bash","input":{"command":"ls"}}]},"sessionId":"qd-parent-0001","cwd":"/w"}"#
        let half = String(line.prefix(line.count / 2))
        try Data(half.utf8).write(to: file)

        let scanner = QoderAuditScanner(
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
