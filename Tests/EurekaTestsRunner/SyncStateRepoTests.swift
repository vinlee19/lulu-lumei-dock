import EurekaStore
import Foundation

func syncStateRepoTests(_ t: TestRunner) {
    t.suite("SyncStateRepo")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-syncstate-\(UUID()).sqlite")
    }

    t.test("upsert / entry / allEntries / deletePaths 基础往返") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        let entry = SyncStateRepo.Entry(
            path: "/a/b.jsonl", remoteKey: "e/m/claude/projects/b.jsonl",
            size: 42, mtime: 1234.5, etag: "\"abc\"",
            uploadedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try store.syncState.upsert(entry)
        try expectEqual(try store.syncState.entry(path: "/a/b.jsonl"), entry)

        // upsert 覆盖
        var updated = entry
        updated.size = 100
        try store.syncState.upsert(updated)
        try expectEqual(try store.syncState.entry(path: "/a/b.jsonl")?.size, 100)

        try store.syncState.upsert(SyncStateRepo.Entry(
            path: "/c", remoteKey: "k/c", size: 1, mtime: 1, uploadedAt: Date()))
        try expectEqual(try store.syncState.allEntries().count, 2)

        try store.syncState.deletePaths(["/a/b.jsonl", "/nonexistent"])
        try expectEqual(try store.syncState.allEntries().count, 1)
        let deleted = try store.syncState.entry(path: "/a/b.jsonl")
        try expect(deleted == nil)
    }

    t.test("stats：空库 0/0/nil；有数据后计数/求和/最大时间") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)

        let empty = try store.syncState.stats()
        try expectEqual(empty, SyncStateRepo.Stats(fileCount: 0, totalBytes: 0, lastUploadAt: nil))

        try store.syncState.upsert(SyncStateRepo.Entry(
            path: "/a", remoteKey: "k/a", size: 100, mtime: 1,
            uploadedAt: Date(timeIntervalSince1970: 1000)))
        try store.syncState.upsert(SyncStateRepo.Entry(
            path: "/b", remoteKey: "k/b", size: 250, mtime: 2,
            uploadedAt: Date(timeIntervalSince1970: 2000)))
        let stats = try store.syncState.stats()
        try expectEqual(stats.fileCount, 2)
        try expectEqual(stats.totalBytes, 350)
        try expectEqual(stats.lastUploadAt, Date(timeIntervalSince1970: 2000))
    }

    t.test("版本升级迁移不丢 sync_state（模拟未来 bump：回拨 user_version 重开）") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        do {
            let store = try EurekaStore(path: path)
            try store.syncState.upsert(SyncStateRepo.Entry(
                path: "/keep", remoteKey: "k/keep", size: 7, mtime: 7, uploadedAt: Date()))
            // 回拨版本号，模拟"旧库升级到新版"场景
            try store.db.execute("PRAGMA user_version = 7")
        }
        // 重开触发 migrate（7 < 8）：派生表 DROP 重建，sync_state 必须保留
        let reopened = try EurekaStore(path: path)
        try expectEqual(try reopened.syncState.entry(path: "/keep")?.size, 7)
    }
}
