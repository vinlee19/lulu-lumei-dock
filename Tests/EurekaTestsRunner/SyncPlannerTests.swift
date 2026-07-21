import EurekaStore
import EurekaSync
import Foundation

func syncPlannerTests(_ t: TestRunner) {
    t.suite("SyncPlanner / SyncSourceCatalog / OpencodeSnapshot")

    func candidate(
        _ path: String, size: Int64 = 10, mtime: Double = 100, priority: Int = 0
    ) -> SyncCandidate {
        SyncCandidate(localPath: path, remoteKey: "k/\(path)", size: size, mtime: mtime,
                      priority: priority)
    }
    func entry(_ path: String, size: Int64 = 10, mtime: Double = 100) -> SyncStateRepo.Entry {
        SyncStateRepo.Entry(path: path, remoteKey: "k/\(path)", size: size, mtime: mtime,
                            uploadedAt: Date())
    }

    t.test("diff：新文件全选、未变跳过、size/mtime 变化重选") {
        let plan = SyncPlanner.plan(
            candidates: [
                candidate("/new"),
                candidate("/same"),
                candidate("/grown", size: 20),
                candidate("/touched", mtime: 200),
            ],
            state: ["/same": entry("/same"), "/grown": entry("/grown"),
                    "/touched": entry("/touched")],
            maxFiles: 100, maxBytes: 1 << 30)
        try expectEqual(Set(plan.uploads.map(\.localPath)), Set(["/new", "/grown", "/touched"]))
        try expectEqual(plan.deferred, 0)
    }

    t.test("排序与限量：priority 优先、同级 mtime 降序、超量截断计 deferred") {
        let plan = SyncPlanner.plan(
            candidates: [
                candidate("/t-old", mtime: 1, priority: 1),
                candidate("/skill", mtime: 5, priority: 0),
                candidate("/t-new", mtime: 9, priority: 1),
            ],
            state: [:], maxFiles: 2, maxBytes: 1 << 30)
        try expectEqual(plan.uploads.map(\.localPath), ["/skill", "/t-new"])
        try expectEqual(plan.deferred, 1)
    }

    t.test("字节预算截断（首文件即使超预算也放行，避免大文件永久饿死）") {
        let plan = SyncPlanner.plan(
            candidates: [candidate("/big", size: 100, mtime: 9), candidate("/small", size: 10, mtime: 1)],
            state: [:], maxFiles: 100, maxBytes: 50)
        try expectEqual(plan.uploads.map(\.localPath), ["/big"])
        try expectEqual(plan.deferred, 1)
    }

    t.test("vanished：state 有、盘上无 → 待清理") {
        let plan = SyncPlanner.plan(
            candidates: [candidate("/alive")],
            state: ["/alive": entry("/alive"), "/gone": entry("/gone")],
            maxFiles: 10, maxBytes: 1 << 30)
        try expectEqual(plan.vanishedPaths, ["/gone"])
    }

    t.test("Catalog：projects 只收 jsonl（含 subagents 深层）+ memory md；skills 全收含停用区") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-catalog-\(UUID())")
        defer { try? fm.removeItem(at: base) }

        func write(_ rel: String, _ content: String = "x") throws {
            let url = base.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        // Claude home + projects + skills
        try write("claude/CLAUDE.md")
        try write("claude/memories/note.md")
        try write("claude/projects/-proj/sess.jsonl")
        try write("claude/projects/-proj/sess/subagents/agent.jsonl")
        try write("claude/projects/-proj/other.txt")           // 不该收
        try write("claude/projects/-proj/memory/MEMORY.md")     // 项目记忆该收
        try write("claude/skills/foo/SKILL.md")
        try write("claude/skills.eureka-disabled/bar/SKILL.md") // 停用区该收
        // Codex + opencode
        try write("codex/AGENTS.md")
        try write("codex/AGENTS.override.md")
        try write("codex/sessions/2026/07/07/rollout-1.jsonl")
        try write("codex/skills/baz/SKILL.md")
        try write("oc-skills/s/SKILL.md")
        // 计划：Claude 直接目录 + 物化暂存 codex/opencode
        try write("claude/plans/my-plan.md")
        try write("plans-staging/codex/roll.md")
        try write("plans-staging/opencode/s1.md")
        // grok：memory md + session jsonl + skill
        try write("grok/memory/m1.md")
        try write("grok/sessions/-enc/uuid/events.jsonl")
        try write("grok/skills/gk/SKILL.md")
        // kimi：session wire.jsonl + state.json + skill
        try write("kimi/sessions/wd_x/session_1/agents/main/wire.jsonl")
        try write("kimi/sessions/wd_x/session_1/state.json")
        try write("kimi/skills/kk/SKILL.md")
        // 自定义目录：任意文件类型都收
        try write("mydocs/note.txt")

        var roots = SyncRoots(
            claudeHome: base.appendingPathComponent("claude"),
            claudeProjects: base.appendingPathComponent("claude/projects"),
            claudeSkills: base.appendingPathComponent("claude/skills"),
            codexHome: base.appendingPathComponent("codex"),
            codexSessions: base.appendingPathComponent("codex/sessions"),
            codexSkills: base.appendingPathComponent("codex/skills"),
            opencodeSkills: base.appendingPathComponent("oc-skills"),
            opencodeDB: base.appendingPathComponent("none/opencode.db"),
            grokSkills: base.appendingPathComponent("grok/skills"),
            grokMemory: base.appendingPathComponent("grok/memory"),
            grokSessions: base.appendingPathComponent("grok/sessions"),
            kimiSkills: base.appendingPathComponent("kimi/skills"),
            kimiSessions: base.appendingPathComponent("kimi/sessions"),
            geminiHome: base.appendingPathComponent("gemini"),
            geminiSessions: base.appendingPathComponent("gemini/tmp"),
            geminiSkills: base.appendingPathComponent("gemini/skills"),
            claudePlans: base.appendingPathComponent("claude/plans"),
            plansStaging: base.appendingPathComponent("plans-staging"))
        roots.customDirs = [(
            root: base.appendingPathComponent("mydocs"), category: "custom/docs")]
        let result = SyncSourceCatalog.enumerate(
            roots: roots, prefix: "eureka", host: "mac", maxFileSize: 1 << 20)
        let keys = Set(result.candidates.map(\.remoteKey))

        try expect(keys.contains("eureka/mac/claude/CLAUDE.md"))
        try expect(keys.contains("eureka/mac/claude/memories/note.md"))
        try expect(keys.contains("eureka/mac/claude/projects/-proj/sess.jsonl"))
        try expect(keys.contains("eureka/mac/claude/projects/-proj/sess/subagents/agent.jsonl"),
                   "subagents 深层 jsonl 必须收")
        try expect(keys.contains("eureka/mac/claude/projects/-proj/memory/MEMORY.md"),
                   "项目 memory md 必须收")
        try expect(!keys.contains { $0.hasSuffix("other.txt") }, "projects 下非 jsonl/memory 不收")
        try expect(keys.contains("eureka/mac/claude/skills/foo/SKILL.md"))
        try expect(keys.contains("eureka/mac/claude/skills.eureka-disabled/bar/SKILL.md"))
        try expect(keys.contains("eureka/mac/codex/AGENTS.md"))
        try expect(keys.contains("eureka/mac/codex/AGENTS.override.md"))
        try expect(keys.contains("eureka/mac/codex/sessions/2026/07/07/rollout-1.jsonl"))
        try expect(keys.contains("eureka/mac/codex/skills/baz/SKILL.md"))
        try expect(keys.contains("eureka/mac/opencode/skills/s/SKILL.md"))
        try expect(keys.contains("eureka/mac/claude/plans/my-plan.md"), "Claude 计划必须收")
        try expect(keys.contains("eureka/mac/codex/plans/roll.md"), "Codex 计划必须收")
        try expect(keys.contains("eureka/mac/opencode/plans/s1.md"), "opencode 计划必须收")
        try expect(keys.contains("eureka/mac/grok/memories/m1.md"), "grok 记忆必须收")
        try expect(keys.contains("eureka/mac/grok/sessions/-enc/uuid/events.jsonl"), "grok 会话 jsonl 必须收")
        try expect(keys.contains("eureka/mac/grok/skills/gk/SKILL.md"), "grok 技能必须收")
        try expect(keys.contains(
            "eureka/mac/kimi/sessions/wd_x/session_1/agents/main/wire.jsonl"), "kimi 会话 wire 必须收")
        try expect(keys.contains(
            "eureka/mac/kimi/sessions/wd_x/session_1/state.json"), "kimi state.json 必须收（恢复会话要用）")
        try expect(keys.contains("eureka/mac/kimi/skills/kk/SKILL.md"), "kimi 技能必须收")
        try expect(keys.contains("eureka/mac/custom/docs/note.txt"), "自定义目录必须收")
        // category 已随候选携带（历史记录按来源分组用）
        try expect(result.candidates.contains {
            $0.category == "custom/docs" && $0.remoteKey.hasSuffix("note.txt")
        }, "自定义目录候选应带 category")
    }

    t.test("Catalog：超大文件跳过并计数") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-oversize-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        let skills = base.appendingPathComponent("skills/big")
        try fm.createDirectory(at: skills, withIntermediateDirectories: true)
        try Data(count: 2048).write(to: skills.appendingPathComponent("big.bin"))
        try Data(count: 10).write(to: skills.appendingPathComponent("small.bin"))

        let roots = SyncRoots(
            claudeHome: base.appendingPathComponent("nope"),
            claudeProjects: base.appendingPathComponent("nope"),
            claudeSkills: base.appendingPathComponent("skills"),
            codexHome: base.appendingPathComponent("nope"),
            codexSessions: base.appendingPathComponent("nope"),
            codexSkills: base.appendingPathComponent("nope"),
            opencodeSkills: base.appendingPathComponent("nope"),
            opencodeDB: base.appendingPathComponent("nope/db"),
            grokSkills: base.appendingPathComponent("nope"),
            grokMemory: base.appendingPathComponent("nope"),
            grokSessions: base.appendingPathComponent("nope"),
            kimiSkills: base.appendingPathComponent("nope"),
            kimiSessions: base.appendingPathComponent("nope"),
            geminiHome: base.appendingPathComponent("nope"),
            geminiSessions: base.appendingPathComponent("nope"),
            geminiSkills: base.appendingPathComponent("nope"),
            claudePlans: base.appendingPathComponent("nope"),
            plansStaging: base.appendingPathComponent("nope"))
        let result = SyncSourceCatalog.enumerate(
            roots: roots, prefix: "e", host: "m", maxFileSize: 1024)
        try expectEqual(result.skippedOversize, 1)
        try expectEqual(result.candidates.count, 1)
        try expect(result.candidates[0].localPath.hasSuffix("small.bin"))
    }

    t.test("OpencodeSnapshot：VACUUM INTO 快照行数一致；指纹含 wal") {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("eureka-ocsnap-\(UUID())")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let dbPath = base.appendingPathComponent("opencode.db")
        do {
            let db = try SQLiteDB(path: dbPath.path)
            try db.execute("CREATE TABLE session (id TEXT)")
            try db.run("INSERT INTO session VALUES (?)", [.text("a")])
            try db.run("INSERT INTO session VALUES (?)", [.text("b")])
        }
        let fp = OpencodeSnapshot.fingerprint(dbPath: dbPath)
        try expect(fp != nil && fp!.size > 0)

        let snapshot = try OpencodeSnapshot.snapshot(
            dbPath: dbPath, to: base.appendingPathComponent("tmp"))
        defer { try? fm.removeItem(at: snapshot) }
        let snap = try SQLiteDB(path: snapshot.path, readOnly: true)
        let count = try snap.query("SELECT COUNT(*) FROM session") { $0.int(0) }.first ?? 0
        try expectEqual(count, 2)
    }

    t.test("OpencodeSnapshot：库不存在 → 指纹 nil") {
        try expect(OpencodeSnapshot.fingerprint(
            dbPath: URL(fileURLWithPath: "/nonexistent/opencode.db")) == nil)
    }
}
