import EurekaKit
import EurekaStore
import Foundation

func storeMigrationRaceTests(_ t: TestRunner) {
    t.suite("Schema.migrate 并发")

    t.test("全新库上 9 个连接同时打开：都成功，先写入的数据不会被后来者 DROP 掉") {
        // Repeat: the race only shows when two connections read version 0 at the same moment
        for round in 0..<20 {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("eureka-race-\(UUID().uuidString)/test.sqlite")
            let lock = NSLock()
            var failures: [String] = []
            var writer: EurekaStore?
            DispatchQueue.concurrentPerform(iterations: 9) { index in
                do {
                    let store = try EurekaStore(path: url)
                    if index == 0 {
                        // Like UsageService: start writing as soon as the connection is open
                        try store.usage.insert([UsageRecord(
                            source: .claude, model: "claude-opus-4", sessionId: "s",
                            timestamp: Date(), inputTokens: 1, outputTokens: 1)])
                        lock.lock(); writer = store; lock.unlock()
                    }
                } catch {
                    lock.lock(); failures.append("\(error)"); lock.unlock()
                }
            }
            try expect(failures.isEmpty, "round \(round): \(failures)")
            let count = try writer?.usage.recordCount(
                from: .distantPast, to: .distantFuture, source: nil)
            try expect(count == 1, "round \(round): \(String(describing: count)) rows survived")
        }
    }
}
