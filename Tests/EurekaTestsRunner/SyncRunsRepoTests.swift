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
