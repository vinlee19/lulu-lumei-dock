import EurekaKit
import EurekaStore
import Foundation

func storeHistoryTests(_ t: TestRunner) {
    t.suite("TaskHistoryRepo · session_started_at")

    t.test("sessionStartedAt 落库→读回；重开触发 migrate 幂等、数据仍在") {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("eureka-storetest-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let dbURL = dir.appendingPathComponent("t.sqlite")

        let task = FinishedTask(
            source: .claude, sessionId: "s1", title: "t", cwd: "/w",
            startedAt: Date(timeIntervalSince1970: 100),
            sessionStartedAt: Date(timeIntervalSince1970: 50),
            finishedAt: Date(timeIntervalSince1970: 200), outcome: .success)

        do {
            let store = try EurekaStore(path: dbURL)
            try store.history.insert(task)
            let rows = try store.history.recent(limit: 10)
            try expectEqual(rows.count, 1)
            try expectEqual(rows[0].sessionStartedAt, Date(timeIntervalSince1970: 50))
        }

        // 再次打开：Schema.migrate 会再跑，ALTER 幂等（列已存在则跳过），历史不丢
        let store2 = try EurekaStore(path: dbURL)
        let rows2 = try store2.history.recent(limit: 10)
        try expectEqual(rows2.count, 1)
        try expectEqual(rows2[0].sessionStartedAt, Date(timeIntervalSince1970: 50))
    }
}
