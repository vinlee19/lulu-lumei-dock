import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func knowledgeLinkTests(_ t: TestRunner) {
    t.suite("KnowledgeLink · tool_calls 会话维度")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-klink-\(UUID()).sqlite")
    }

    t.test("bump 带 session：recentSkillSessions 按最近时间排序且聚合次数") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 100, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 200, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-02", source: .claude, kind: "skill", name: "tdd",
            ts: 300, session: "sess-b")
        let rows = try store.toolCalls.recentSkillSessions(source: .claude, name: "tdd")
        try expectEqual(rows.count, 2)
        try expectEqual(rows[0].sessionId, "sess-b", "最近调用的会话排最前")
        try expectEqual(rows[1].sessionId, "sess-a")
        try expectEqual(rows[1].count, 2, "同会话两次 bump 应聚合")
    }

    t.test("session 维度不影响既有聚合口径") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 100, session: "sess-a")
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd",
            ts: 200, session: "sess-b")
        let stats = try store.toolCalls.skillStats(source: .claude)
        try expectEqual(stats.count, 1, "跨会话仍聚合为同一技能")
        try expectEqual(stats[0].count, 2)
    }

    t.test("空 session 的历史行不进 recentSkillSessions") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.toolCalls.bump(
            day: "2026-08-01", source: .claude, kind: "skill", name: "tdd", ts: 100)
        try expectEqual(
            try store.toolCalls.recentSkillSessions(source: .claude, name: "tdd").count, 0)
    }

    t.test("knowledge：upsert / 搜索 / prune 全链路") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.knowledge.replaceDoc(
            path: "/tmp/a/SKILL.md", kind: "skill", source: "claude",
            title: "tdd", project: nil, size: 10, mtime: 1,
            body: "红绿重构循环，测试先行")
        try store.knowledge.replaceDoc(
            path: "/tmp/b/mem.md", kind: "memory", source: "claude",
            title: "worktree 约定", project: "eureka", size: 10, mtime: 1,
            body: "main 直改不建 worktree")
        let hits = try store.knowledge.search("worktree")
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].kind, "memory")
        try expectEqual(hits[0].title, "worktree 约定")
        // 同 path 重写覆盖旧文
        try store.knowledge.replaceDoc(
            path: "/tmp/b/mem.md", kind: "memory", source: "claude",
            title: "worktree 约定", project: "eureka", size: 12, mtime: 2,
            body: "改为别的内容")
        try expectEqual(try store.knowledge.search("worktree").count, 0, "旧正文应被覆盖")
        // prune 清掉消失的文件
        try store.knowledge.prune(keeping: ["/tmp/b/mem.md"])
        try expectEqual(try store.knowledge.search("测试先行").count, 0, "被 prune 的技能不该再命中")
    }

    t.test("knowledge：中文双字查询走 LIKE 兜底") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.knowledge.replaceDoc(
            path: "/tmp/c/plan.md", kind: "plan", source: "codex",
            title: "对比度修复", project: nil, size: 10, mtime: 1, body: "修复对比度问题")
        try expectEqual(try store.knowledge.search("修复").count, 1)
    }

    t.test("indexer：条目映射成 doc（kind / title / project 各归各位）") {
        let skill = SkillEntry(
            source: .claude, name: "tdd", description: nil,
            path: "/tmp/s/SKILL.md", directory: "/tmp/s", enabled: true,
            sizeBytes: 10, modifiedAt: Date(timeIntervalSince1970: 1))
        let memory = MemoryEntry(
            source: .claude, scope: "eureka", path: "/tmp/m.md",
            projectName: "eureka", kind: .userManaged,
            sizeBytes: 20, modifiedAt: Date(timeIntervalSince1970: 2),
            title: "worktree 约定", summary: nil, memoryType: .other,
            originSessionId: nil, originSessionPath: nil,
            relatedSessions: [], links: [], indexedTargets: [], isIndex: false, libraryKey: nil)
        let instruction = MemoryEntry(
            source: .claude, scope: "全局", path: "/tmp/CLAUDE.md",
            projectName: nil, kind: .instructions,
            sizeBytes: 5, modifiedAt: Date(timeIntervalSince1970: 3),
            title: "CLAUDE", summary: nil, memoryType: .other,
            originSessionId: nil, originSessionPath: nil,
            relatedSessions: [], links: [], indexedTargets: [], isIndex: false, libraryKey: nil)
        let plan = PlanMaterializer.PlanEntry(
            source: .codex, title: "对比度修复", path: "/tmp/p.md",
            sizeBytes: 30, modifiedAt: Date(timeIntervalSince1970: 4), sessionId: "sess-1")
        let docs = KnowledgeSearchIndexer.docs(
            skills: [skill], memories: [memory, instruction], plans: [plan])
        try expectEqual(docs.count, 4)
        try expectEqual(docs.first { $0.path == "/tmp/s/SKILL.md" }?.kind, "skill")
        try expectEqual(docs.first { $0.path == "/tmp/m.md" }?.kind, "memory")
        try expectEqual(docs.first { $0.path == "/tmp/m.md" }?.project, "eureka")
        try expectEqual(docs.first { $0.path == "/tmp/CLAUDE.md" }?.kind, "instruction")
        try expectEqual(docs.first { $0.path == "/tmp/p.md" }?.kind, "plan")
    }

    // CommandPaletteService（Sources/EurekaApp）的 Kind/Hit/merge/snippet 实际转发自
    // EurekaKit.CommandPalette——eureka-tests 链不到 app 壳目标码（同 KnowledgeSearchIndexer
    // 挪层的教训），纯逻辑测这层即可，服务只是薄壳转发。
    t.test("palette：合并去重（同目标取先出现者）并按组截断") {
        let a = CommandPalette.Hit(
            kind: .skill, key: "/tmp/s.md", title: "tdd", subtitle: "claude", snippet: nil,
            sessionId: nil, messageIdx: nil)
        let dup = CommandPalette.Hit(
            kind: .skill, key: "/tmp/s.md", title: "tdd", subtitle: "claude", snippet: "正文命中",
            sessionId: nil, messageIdx: nil)
        let b = CommandPalette.Hit(
            kind: .session, key: "sess-1", title: "会话一", subtitle: nil, snippet: nil,
            sessionId: "sess-1", messageIdx: nil)
        let merged = CommandPalette.merge([a, b, dup], perKindCap: 5)
        try expectEqual(merged.count, 2)
        try expectEqual(merged.filter { $0.kind == .skill }.count, 1)
    }

    t.test("palette：snippet 就近裁剪，命中词在窗口内") {
        let text = String(repeating: "前", count: 200) + "关键词" + String(repeating: "后", count: 200)
        let snippet = CommandPalette.snippet(text, query: "关键词", radius: 30)
        try expect(snippet.contains("关键词"))
        try expect(snippet.count <= 70)
    }
}
