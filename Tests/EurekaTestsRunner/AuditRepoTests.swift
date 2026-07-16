import EurekaKit
import EurekaStore
import Foundation

func auditRepoTests(_ t: TestRunner) {
    t.suite("AuditRepo · 审计流水")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-audit-\(UUID()).sqlite")
    }

    func event(
        _ opId: String, source: AgentSource = .codex, session: String = "s1",
        ts: Double = 1000, kind: ToolKind = .command, tool: String = "exec_command",
        detail: String = "ls -la", risk: RiskLevel? = nil, rule: String? = nil
    ) -> AuditEvent {
        AuditEvent(
            opId: opId, source: source, sessionId: session,
            timestamp: Date(timeIntervalSince1970: ts), kind: kind, tool: tool,
            detail: detail, riskLevel: risk, riskRule: rule)
    }

    t.test("幂等插入：同 (source,session,op_id) 只入一条") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        try expectEqual(try store.audit.insert(event("op-1")), true)
        try expectEqual(try store.audit.insert(event("op-1")), false, "重复 op_id 应被忽略")
        try expectEqual(try store.audit.count(), 1)

        // 不同来源同 op_id 视为不同（唯一键含 source）
        try expectEqual(try store.audit.insert(event("op-1", source: .claude)), true)
        try expectEqual(try store.audit.count(), 2)
    }

    t.test("筛选：source / kind / riskOnly / keyword") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.audit.insert(event("a", source: .codex, kind: .command, detail: "sudo reboot", risk: .high, rule: "sudo"))
        try store.audit.insert(event("b", source: .claude, kind: .edit, tool: "Edit", detail: "/x/main.swift"))
        try store.audit.insert(event("c", source: .codex, kind: .read, tool: "Read", detail: "/x/.env", risk: .notice, rule: "read-secret"))

        try expectEqual(try store.audit.count(.init(source: .codex)), 2)
        try expectEqual(try store.audit.count(.init(kind: .edit)), 1)
        try expectEqual(try store.audit.count(.init(riskOnly: true)), 2)
        try expectEqual(try store.audit.count(.init(keyword: "main.swift")), 1)
        try expectEqual(try store.audit.count(.init(keyword: "sudo")), 1)
        // keyword 命中 tool 列
        try expectEqual(try store.audit.count(.init(keyword: "Read")), 1)
        // 组合
        try expectEqual(try store.audit.count(.init(source: .codex, riskOnly: true)), 2)
    }

    t.test("keyword LIKE 特殊字符转义（% 不当通配）") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.audit.insert(event("a", detail: "echo 100%done"))
        try store.audit.insert(event("b", detail: "echo hello"))
        try expectEqual(try store.audit.count(.init(keyword: "100%done")), 1)
        try expectEqual(try store.audit.count(.init(keyword: "%")), 1, "% 应按字面匹配")
    }

    t.test("倒序分页") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        for i in 1...5 {
            try store.audit.insert(event("op-\(i)", ts: Double(i) * 100, detail: "cmd\(i)"))
        }
        let page1 = try store.audit.recent(limit: 2)
        try expectEqual(page1.map(\.detail), ["cmd5", "cmd4"])
        let page2 = try store.audit.recent(limit: 2, offset: 2)
        try expectEqual(page2.map(\.detail), ["cmd3", "cmd2"])
    }

    t.test("markOutcome 回填 exit_code / is_error") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.audit.insert(event("call-1", source: .codex, session: "s1"))
        try store.audit.markOutcome(source: .codex, sessionId: "s1", opId: "call-1", exitCode: 1, isError: true)
        let row = try store.audit.recent(limit: 1)[0]
        try expectEqual(row.exitCode, 1)
        try expect(row.isError)
    }

    t.test("round-trip：risk 字段完整往返") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.audit.insert(event("r", risk: .high, rule: "rm-rf"))
        let row = try store.audit.recent(limit: 1)[0]
        try expectEqual(row.riskLevel, .high)
        try expectEqual(row.riskRule, "rm-rf")
        // 无风险行读回 nil
        try store.audit.insert(event("n", detail: "plain-cmd"))
        let none = try store.audit.recent(.init(keyword: "plain-cmd"), limit: 1)[0]
        try expect(none.riskLevel == nil)
    }

    t.test("prune(olderThan:) / prune(keepingLast:) / deleteAll") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        for i in 1...10 {
            try store.audit.insert(event("op-\(i)", ts: Double(i) * 100))
        }
        try store.audit.prune(olderThan: Date(timeIntervalSince1970: 350))  // 删 ts<350（op1..3）
        try expectEqual(try store.audit.count(), 7)
        try store.audit.prune(keepingLast: 3)
        try expectEqual(try store.audit.count(), 3)
        try expectEqual(try store.audit.recent(limit: 3).map(\.opId), ["op-10", "op-9", "op-8"])
        try store.audit.deleteAll()
        try expectEqual(try store.audit.count(), 0)
    }

    t.test("v10→v11 迁移保留 audit_events（回拨 user_version 重开）") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            let store = try EurekaStore(path: path)
            try store.audit.insert(event("keep-me", detail: "important"))
            try store.db.execute("PRAGMA user_version = 10")
        }
        let reopened = try EurekaStore(path: path)
        try expectEqual(try reopened.audit.count(), 1)
        try expectEqual(try reopened.audit.recent(limit: 1)[0].detail, "important")
    }
}
