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
}
