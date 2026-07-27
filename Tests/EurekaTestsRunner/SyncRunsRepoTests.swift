import EurekaStore
import Foundation

func syncRunsRepoTests(_ t: TestRunner) {
    t.suite("SyncRunsRepo · 同步历史")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-syncruns-\(UUID()).sqlite")
    }

    t.test("insert / 倒序分页 / count / 文件明细往返") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        for i in 1...5 {
            try store.syncRuns.insert(
                date: Date(timeIntervalSince1970: Double(i) * 1000),
                uploaded: i, uploadedBytes: Int64(i * 100),
                failed: 0, deferred: 0, error: nil,
                files: [SyncRunsRepo.RunFile(name: "f\(i).jsonl", size: Int64(i * 100))])
        }
        try expectEqual(try store.syncRuns.count(), 5)

        // 倒序：最新（ts=5000）在前
        let page1 = try store.syncRuns.recent(limit: 2)
        try expectEqual(page1.map(\.uploaded), [5, 4])
        let page2 = try store.syncRuns.recent(limit: 2, offset: 2)
        try expectEqual(page2.map(\.uploaded), [3, 2])

        // 文件明细 JSON 往返
        try expectEqual(page1[0].files, [SyncRunsRepo.RunFile(name: "f5.jsonl", size: 500)])
        try expectEqual(page1[0].uploadedBytes, 500)
    }

    t.test("文件明细带来源类目（c 键）+ 老 JSON（无 c）兼容") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.syncRuns.insert(
            date: Date(timeIntervalSince1970: 1), uploaded: 2, uploadedBytes: 30,
            failed: 0, deferred: 0, error: nil,
            files: [
                SyncRunsRepo.RunFile(name: "SKILL.md", size: 10, category: "claude/skills"),
                SyncRunsRepo.RunFile(name: "note.txt", size: 20, category: "custom/docs"),
            ])
        let run = try store.syncRuns.recent(limit: 1)[0]
        try expectEqual(run.files[0].category, "claude/skills")
        try expectEqual(run.files[1].category, "custom/docs")

        // 老记录 JSON 无 "c" → category nil，不炸
        let legacy = SyncRunsRepo.decodeFiles(#"[{"n":"old.jsonl","s":7}]"#)
        try expectEqual(legacy.count, 1)
        try expectEqual(legacy[0].name, "old.jsonl")
        try expect(legacy[0].category == nil)
    }

    t.test("error 与空文件明细") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.syncRuns.insert(
            date: Date(timeIntervalSince1970: 1), uploaded: 0, uploadedBytes: 0,
            failed: 2, deferred: 3, error: "网络错误", files: [])
        let run = try store.syncRuns.recent(limit: 1)[0]
        try expectEqual(run.failed, 2)
        try expectEqual(run.deferred, 3)
        try expectEqual(run.error, "网络错误")
        try expect(run.files.isEmpty)
    }

    t.test("prune 只保留最近 N 轮") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        for i in 1...10 {
            try store.syncRuns.insert(
                date: Date(timeIntervalSince1970: Double(i)), uploaded: i, uploadedBytes: 0,
                failed: 0, deferred: 0, error: nil, files: [])
        }
        try store.syncRuns.prune(keepingLast: 3)
        try expectEqual(try store.syncRuns.count(), 3)
        try expectEqual(try store.syncRuns.recent(limit: 10).map(\.uploaded), [10, 9, 8])
    }

    t.test("v8→v9 迁移保留 sync_runs（回拨 user_version 重开）") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            let store = try EurekaStore(path: path)
            try store.syncRuns.insert(
                date: Date(timeIntervalSince1970: 1), uploaded: 7, uploadedBytes: 70,
                failed: 0, deferred: 0, error: nil, files: [])
            try store.db.execute("PRAGMA user_version = 8")
        }
        let reopened = try EurekaStore(path: path)
        try expectEqual(try reopened.syncRuns.count(), 1)
        try expectEqual(try reopened.syncRuns.recent(limit: 1)[0].uploaded, 7)
    }
}

/// 备份构成（两级）：新行走 category 列，老行回退 remote_key。
func syncCompositionTests(_ t: TestRunner) {
    t.suite("SyncStateRepo · 备份构成两级拆分")

    t.test("新行按 category 列；老行按 remote_key 段数区分类目与根文件") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("comp-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = try EurekaStore(path: tmp)

        // 新行：category 精确
        try store.syncState.upsert(.init(
            path: "/a/1.md", remoteKey: "eureka/host/claude/skills/x/SKILL.md",
            size: 100, mtime: 1, uploadedAt: Date(), category: "claude/skills"))
        // 项目级技能：category 是 claude/skills/project/<名> → 类目应归到 skills
        try store.syncState.upsert(.init(
            path: "/a/2.md", remoteKey: "eureka/host/claude/skills/project/p/SKILL.md",
            size: 200, mtime: 1, uploadedAt: Date(), category: "claude/skills/project/p"))
        // 老行（category 为 nil）：段数 6 → 第 4 段 sessions 是类目
        try store.syncState.upsert(.init(
            path: "/a/3.jsonl", remoteKey: "eureka/host/codex/sessions/2026/r.jsonl",
            size: 400, mtime: 1, uploadedAt: Date()))
        // 老行且段数 4 → 第 4 段是文件名，属根文件（kind = nil）
        try store.syncState.upsert(.init(
            path: "/a/SOUL.md", remoteKey: "eureka/host/hermes/SOUL.md",
            size: 50, mtime: 1, uploadedAt: Date()))

        let buckets = try store.syncState.composition()
        func bucket(_ source: String, _ kind: String?) -> SyncStateRepo.CompositionBucket? {
            buckets.first { $0.source == source && $0.kind == kind }
        }
        try expectEqual(bucket("claude", "skills")?.count, 2, "项目级技能应并进 skills")
        try expectEqual(bucket("claude", "skills")?.bytes, 300)
        try expectEqual(bucket("codex", "sessions")?.count, 1, "老行段数≥5 时第 4 段即类目")
        try expectEqual(
            bucket("hermes", nil)?.count, 1,
            "老行段数=4 时第 4 段是文件名 → 根文件（kind 为 nil），不能造出假类目")
        // 字节降序
        try expectEqual(buckets.first?.source, "codex")

        // 兼容旧调用点
        let bySource = try store.syncState.sourceComposition()
        try expectEqual(bySource["claude"]?.count, 2)
        try expectEqual(bySource["hermes"]?.bytes, 50)
    }
}
