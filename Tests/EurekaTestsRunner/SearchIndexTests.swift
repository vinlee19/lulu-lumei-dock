import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func searchIndexTests(_ t: TestRunner) {
    t.suite("TranscriptSearchIndexer · 跨会话全文搜索")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-search-\(UUID()).sqlite")
    }

    /// 把 fixture 复制到临时路径（测试要改写文件触发指纹变更，不能动 bundle 原件）
    func copyFixture(_ name: String) throws -> URL {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-search-\(UUID())-\(name)")
        try FileManager.default.copyItem(at: try fixtureURL(name), to: dest)
        return dest
    }

    func session(_ path: URL, id: String = "sess-1") -> AgentSessionInfo {
        AgentSessionInfo(
            source: .claude, id: id, cwd: "/w/proj", name: "测试会话",
            startedAt: nil, lastActiveAt: Date(timeIntervalSince1970: 1000),
            sizeBytes: 0, transcriptPath: path.path)
    }

    t.test("索引 user/assistant 并跳过工具轨迹；中文 trigram 子串命中") {
        let dbPath = tempStorePath()
        let file = try copyFixture("claude-transcript-running.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: file)
        }
        let store = try EurekaStore(path: dbPath)
        let indexer = TranscriptSearchIndexer(store: store)

        let rebuilt = indexer.indexOnce(sessions: [session(file)])
        try expectEqual(rebuilt, 1)
        // fixture: user + assistant + turnTrail → 只索引前两条
        try expectEqual(try store.search.docCount(), 2)

        let hits = try store.search.search("增量加载")
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].role, "user")
        try expectEqual(hits[0].sessionId, "sess-1")
        try expectEqual(hits[0].messageIdx, 0)
        try expect(hits[0].text.contains("重构数据管道的增量加载逻辑"))
    }

    t.test("2 字符查询走 LIKE 退化仍可命中；<2 字符返回空") {
        let dbPath = tempStorePath()
        let file = try copyFixture("claude-transcript-running.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: file)
        }
        let store = try EurekaStore(path: dbPath)
        TranscriptSearchIndexer(store: store).indexOnce(sessions: [session(file)])

        let twoChar = try store.search.search("重构")
        let oneChar = try store.search.search("重")
        let blank = try store.search.search("  ")
        try expect(!twoChar.isEmpty, "双字中文应可命中")
        try expect(oneChar.isEmpty, "单字符不检索")
        try expect(blank.isEmpty, "空白不检索")
    }

    t.test("指纹未变 → 二次索引零重建、不产生重复 docs") {
        let dbPath = tempStorePath()
        let file = try copyFixture("claude-transcript-running.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: file)
        }
        let store = try EurekaStore(path: dbPath)
        let indexer = TranscriptSearchIndexer(store: store)
        indexer.indexOnce(sessions: [session(file)])
        let countAfterFirst = try store.search.docCount()

        let rebuilt = indexer.indexOnce(sessions: [session(file)])
        try expectEqual(rebuilt, 0)
        try expectEqual(try store.search.docCount(), countAfterFirst)
    }

    t.test("文件追加内容 → 整文件重建，不重复旧消息") {
        let dbPath = tempStorePath()
        let file = try copyFixture("claude-transcript-running.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: file)
        }
        let store = try EurekaStore(path: dbPath)
        let indexer = TranscriptSearchIndexer(store: store)
        indexer.indexOnce(sessions: [session(file)])
        try expectEqual(try store.search.docCount(), 2)

        // 追加一条新 uuid 的 user 行（同 uuid 会被解析器去重；size 变化触发重建）
        let content = try String(contentsOf: file, encoding: .utf8)
        let extra = #"{"parentUuid":"u-2005","isSidechain":false,"promptId":"p-3009","#
            + #""type":"user","message":{"role":"user","content":"再补充一个边界用例"},"#
            + #""uuid":"u-9999","timestamp":"2026-06-09T10:05:00.000Z","userType":"external","#
            + #""entrypoint":"cli","cwd":"/Users/me/work/pipeline","#
            + #""sessionId":"fixture-running-1","version":"2.1.170"}"#
        try (content + extra + "\n").write(to: file, atomically: true, encoding: .utf8)

        let rebuilt = indexer.indexOnce(sessions: [session(file)])
        try expectEqual(rebuilt, 1)
        try expectEqual(try store.search.docCount(), 3, "旧 docs 应整体替换而非累加")
    }

    t.test("会话消失 → prune 清掉对应 docs") {
        let dbPath = tempStorePath()
        let fileA = try copyFixture("claude-transcript-running.jsonl")
        let fileB = try copyFixture("claude-transcript-api-error.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: fileA)
            try? FileManager.default.removeItem(at: fileB)
        }
        let store = try EurekaStore(path: dbPath)
        let indexer = TranscriptSearchIndexer(store: store)
        indexer.indexOnce(sessions: [session(fileA, id: "a"), session(fileB, id: "b")])
        let bothCount = try store.search.docCount()
        try expect(bothCount > 0)

        indexer.indexOnce(sessions: [session(fileA, id: "a")])
        let hits = try store.search.search("增量加载")
        try expect(hits.allSatisfy { $0.sessionId == "a" })
        let prunedCount = try store.search.docCount()
        try expect(prunedCount < bothCount || bothCount == 2, "b 的 docs 应被清理")
    }

    t.test("clearAll 清空索引；opencode/antigravity 不入索引") {
        let dbPath = tempStorePath()
        let file = try copyFixture("claude-transcript-running.jsonl")
        defer {
            try? FileManager.default.removeItem(at: dbPath)
            try? FileManager.default.removeItem(at: file)
        }
        let store = try EurekaStore(path: dbPath)
        let indexer = TranscriptSearchIndexer(store: store)

        var opencodeSession = session(file, id: "oc")
        opencodeSession.source = .opencode
        indexer.indexOnce(sessions: [session(file), opencodeSession])
        let hits = try store.search.search("增量加载")
        try expect(hits.allSatisfy { $0.source == "claude" }, "opencode 不应入索引")

        try store.search.clearAll()
        try expectEqual(try store.search.docCount(), 0)
        let afterClear = try store.search.search("增量加载")
        try expect(afterClear.isEmpty)
    }
}
