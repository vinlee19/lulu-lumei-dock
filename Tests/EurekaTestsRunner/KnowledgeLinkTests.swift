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
}
