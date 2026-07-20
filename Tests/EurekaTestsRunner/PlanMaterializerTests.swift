import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func planMaterializerTests(_ t: TestRunner) {
    t.suite("PlanMaterializer")

    func temp(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-plan-\(tag)-\(UUID().uuidString)", isDirectory: true)
    }

    func jsonLine(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    t.test("Codex：取最后一次 update_plan 渲染 checklist；重复运行不改 mtime；无 plan 不产文件") {
        let fm = FileManager.default
        let base = temp("codex")
        defer { try? fm.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions/2025/11/17", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: sessions, withIntermediateDirectories: true)

        // 有两次 update_plan：第二次是最终态；夹杂噪声行
        let rollout = sessions.appendingPathComponent("rollout-2025-11-17T10-18-25-abc.jsonl")
        let lines = [
            #"{"type":"response_item","payload":{"type":"message","role":"user"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"status\":\"pending\",\"step\":\"第一步旧\"}]}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#,
            #"{"type":"response_item","payload":{"type":"function_call","name":"update_plan","arguments":"{\"plan\":[{\"status\":\"completed\",\"step\":\"搞定甲\"},{\"status\":\"in_progress\",\"step\":\"进行乙\"},{\"status\":\"pending\",\"step\":\"待办丙\"}]}"}}"#,
        ]
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        // 一个没有 update_plan 的 rollout → 不应产文件
        let noPlan = sessions.appendingPathComponent("rollout-2025-11-17T11-00-00-def.jsonl")
        try #"{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{}"}}"#
            .write(to: noPlan, atomically: true, encoding: .utf8)

        let written = PlanMaterializer.materializeCodex(
            sessionsRoot: base.appendingPathComponent("sessions", isDirectory: true), into: staging)
        try expectEqual(written, 1)

        let out = staging.appendingPathComponent("codex/rollout-2025-11-17T10-18-25-abc.md")
        try expect(fm.fileExists(atPath: out.path), "应产出 codex 计划文件")
        let content = try String(contentsOf: out, encoding: .utf8)
        try expect(content.contains("- [x] 搞定甲"), "completed → [x]")
        try expect(content.contains("- [~] 进行乙"), "in_progress → [~]")
        try expect(content.contains("- [ ] 待办丙"), "pending → [ ]")
        try expect(!content.contains("第一步旧"), "应取最后一次 update_plan，不含旧步骤")
        try expect(
            !fm.fileExists(atPath: staging.appendingPathComponent(
                "codex/rollout-2025-11-17T11-00-00-def.md").path),
            "无 update_plan 的 rollout 不产文件")

        // 重复运行：内容未变 → 不重写 → mtime 稳定（同步去重不会重传）
        let mtime1 = try out.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let again = PlanMaterializer.materializeCodex(
            sessionsRoot: base.appendingPathComponent("sessions", isDirectory: true), into: staging)
        try expectEqual(again, 0)
        let mtime2 = try out.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        try expectEqual(mtime1, mtime2)
    }

    t.test("Codex：最终 proposed_plan 胜过工作清单，采用正式线程名并清理陈旧副本") {
        let fm = FileManager.default
        let base = temp("codex-final")
        defer { try? fm.removeItem(at: base) }
        let sessionsRoot = base.appendingPathComponent("sessions", isDirectory: true)
        let day = sessionsRoot.appendingPathComponent("2026/07/21", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        let codexStaging = staging.appendingPathComponent("codex", isDirectory: true)
        try fm.createDirectory(at: day, withIntermediateDirectories: true)
        try fm.createDirectory(at: codexStaging, withIntermediateDirectories: true)
        let rollout = day.appendingPathComponent("rollout-final.jsonl")
        let checklistArgs = try jsonLine([
            "plan": [["status": "pending", "step": "不应成为最终方案"]],
        ])
        let lines = [
            try jsonLine(["type": "session_meta", "payload": ["id": "session-final"]]),
            try jsonLine([
                "type": "event_msg",
                "payload": ["type": "user_message", "message": "原始 prompt 标题"],
            ]),
            try jsonLine([
                "type": "response_item",
                "payload": [
                    "type": "function_call", "name": "update_plan", "arguments": checklistArgs,
                ],
            ]),
            try jsonLine([
                "type": "response_item",
                "payload": [
                    "type": "message", "role": "assistant",
                    "content": [[
                        "type": "output_text",
                        "text": "完成分析。\n<proposed_plan>\n# 内部旧标题\n\n## Summary\n\n采用流式 JSONL 与官方线程名。\n</proposed_plan>",
                    ]],
                ],
            ]),
        ]
        // 最后一行故意不加换行，验证完整静态 rollout 也能被物化。
        try lines.joined(separator: "\n").write(to: rollout, atomically: true, encoding: .utf8)
        let indexURL = base.appendingPathComponent("session_index.jsonl")
        try jsonLine(["id": "session-final", "thread_name": "Codex 标题计划修复"])
            .write(to: indexURL, atomically: true, encoding: .utf8)
        let stale = codexStaging.appendingPathComponent("stale.md")
        try "# 陈旧计划".write(to: stale, atomically: true, encoding: .utf8)

        let changed = PlanMaterializer.materializeCodex(
            sessionsRoot: sessionsRoot, into: staging, threadNameIndexURL: indexURL)
        try expectEqual(changed, 2, "应写入最终方案并删除一个陈旧副本")
        try expect(!fm.fileExists(atPath: stale.path), "陈旧物化文件应被清理")
        let out = codexStaging.appendingPathComponent("rollout-final.md")
        let content = try String(contentsOf: out, encoding: .utf8)
        try expect(content.hasPrefix("# Codex 标题计划修复\n"), "标题应取正式 thread_name")
        try expect(content.contains("Codex Plan Mode 最终方案"))
        try expect(content.contains("采用流式 JSONL 与官方线程名"))
        try expect(!content.contains("内部旧标题"), "正文自带 H1 应去重")
        try expect(!content.contains("不应成为最终方案"), "最终方案应胜过 update_plan 清单")

        let indexed = PlanMaterializer.index(
            claudePlansDir: base.appendingPathComponent("none"), stagingRoot: staging)
        try expectEqual(indexed.count, 1)
        try expectEqual(indexed[0].kind, .finalPlan)
        try expectEqual(indexed[0].title, "Codex 标题计划修复")
    }

    t.test("opencode：只收 plan 模式 assistant 文本，按会话成文，用 session.title 作标题") {
        let fm = FileManager.default
        let base = temp("oc")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbURL = base.appendingPathComponent("opencode.db")
        let staging = base.appendingPathComponent("staging", isDirectory: true)

        do {
            let db = try SQLiteDB(path: dbURL.path)
            try db.execute("""
            CREATE TABLE session (id TEXT PRIMARY KEY, parent_id TEXT, directory TEXT,
                title TEXT, time_created INTEGER, time_updated INTEGER);
            CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER,
                time_updated INTEGER, data TEXT NOT NULL);
            CREATE TABLE part (id TEXT PRIMARY KEY, message_id TEXT, session_id TEXT,
                time_created INTEGER, time_updated INTEGER, data TEXT NOT NULL);
            """)
            try db.run("INSERT INTO session VALUES (?,?,?,?,?,?)",
                [.text("s1"), .null, .text("/w"), .text("重构管道"), .int(1000), .int(2000)])
            // plan 模式 assistant 消息（含 text + reasoning）
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                [.text("m1"), .text("s1"), .int(1000), .int(1000),
                 .text(#"{"role":"assistant","mode":"plan"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                [.text("p1"), .text("m1"), .text("s1"), .int(1000), .int(1000),
                 .text(#"{"type":"text","text":"计划正文：\n- 步骤一"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                [.text("p2"), .text("m1"), .text("s1"), .int(1001), .int(1001),
                 .text(#"{"type":"reasoning","text":"思考(不应收)"}"#)])
            // build 模式消息（不应收）
            try db.run("INSERT INTO message VALUES (?,?,?,?,?)",
                [.text("m2"), .text("s1"), .int(3000), .int(3000),
                 .text(#"{"role":"assistant","mode":"build"}"#)])
            try db.run("INSERT INTO part VALUES (?,?,?,?,?,?)",
                [.text("p3"), .text("m2"), .text("s1"), .int(3000), .int(3000),
                 .text(#"{"type":"text","text":"构建期正文(不应收)"}"#)])
            try? db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        }

        let written = PlanMaterializer.materializeOpencode(dbPath: dbURL, into: staging)
        try expectEqual(written, 1)
        let out = staging.appendingPathComponent("opencode/s1.md")
        try expect(fm.fileExists(atPath: out.path), "应产出 opencode 计划文件")
        let content = try String(contentsOf: out, encoding: .utf8)
        try expect(content.contains("# 重构管道"), "标题取 session.title")
        try expect(content.contains("步骤一"), "应含 plan 模式 text")
        try expect(!content.contains("思考(不应收)"), "reasoning 不收")
        try expect(!content.contains("构建期正文"), "build 模式不收")
    }

    t.test("index：Claude 目录 + 暂存 codex/opencode 三源分类，按修改时间倒序") {
        let fm = FileManager.default
        let base = temp("idx")
        defer { try? fm.removeItem(at: base) }
        let claudePlans = base.appendingPathComponent("claude-plans", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        try fm.createDirectory(at: claudePlans, withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("codex"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("opencode"), withIntermediateDirectories: true)
        try "# Claude 计划甲\n正文".write(
            to: claudePlans.appendingPathComponent("plan-a.md"), atomically: true, encoding: .utf8)
        try "# Codex 计划\n- [ ] x".write(
            to: staging.appendingPathComponent("codex/roll.md"), atomically: true, encoding: .utf8)
        try "# 会话标题\n正文".write(
            to: staging.appendingPathComponent("opencode/s1.md"), atomically: true, encoding: .utf8)

        let entries = PlanMaterializer.index(claudePlansDir: claudePlans, stagingRoot: staging)
        try expectEqual(entries.count, 3)
        try expect(entries.contains { $0.source == .claude && $0.title == "Claude 计划甲" }, "缺 Claude 项")
        try expect(entries.contains { $0.source == .codex && $0.title == "Codex 计划" }, "缺 Codex 项")
        try expect(entries.contains { $0.source == .opencode && $0.title == "会话标题" }, "缺 opencode 项")
    }

    t.test("grok：每会话 plan.md 拷进暂存；空文件跳过；index 归类 .grok") {
        let fm = FileManager.default
        let base = temp("grok")
        defer { try? fm.removeItem(at: base) }
        let sessions = base.appendingPathComponent("sessions", isDirectory: true)
        let staging = base.appendingPathComponent("staging", isDirectory: true)
        // 有 plan.md 的会话
        let s1 = sessions.appendingPathComponent("enc-demo/uuid-1", isDirectory: true)
        try fm.createDirectory(at: s1, withIntermediateDirectories: true)
        try "# Plan: 深入调研\n\n## Context\n正文".write(
            to: s1.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)
        // 空白 plan.md 的会话（应跳过）
        let s2 = sessions.appendingPathComponent("enc-demo/uuid-2", isDirectory: true)
        try fm.createDirectory(at: s2, withIntermediateDirectories: true)
        try "   \n".write(to: s2.appendingPathComponent("plan.md"), atomically: true, encoding: .utf8)

        let written = PlanMaterializer.materializeGrok(sessionsRoot: sessions, into: staging)
        try expectEqual(written, 1)
        try expect(fm.fileExists(atPath: staging.appendingPathComponent("grok/uuid-1.md").path),
                   "应产出 grok 计划文件")
        try expect(!fm.fileExists(atPath: staging.appendingPathComponent("grok/uuid-2.md").path),
                   "空 plan.md 应跳过")

        let entries = PlanMaterializer.index(
            claudePlansDir: base.appendingPathComponent("none"), stagingRoot: staging)
        try expect(entries.contains { $0.source == .grok && $0.title == "Plan: 深入调研" },
                   "index 应含 .grok 计划，标题取首个 # 行")

        // 重复运行内容未变 → 不重写（mtime 稳定）
        try expectEqual(PlanMaterializer.materializeGrok(sessionsRoot: sessions, into: staging), 0)
    }
}
