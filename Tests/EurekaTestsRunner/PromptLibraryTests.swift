import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func promptLibraryTests(_ t: TestRunner) {
    t.suite("PromptEntry · id 与标题")

    t.test("makeId 确定性：同参同值、跨源不撞") {
        let a = PromptEntry.makeId(source: .claude, sessionId: "s1", messageIdx: 3)
        let b = PromptEntry.makeId(source: .claude, sessionId: "s1", messageIdx: 3)
        let c = PromptEntry.makeId(source: .codex, sessionId: "s1", messageIdx: 3)
        try expectEqual(a, b)
        try expect(a != c, "不同源的 id 必须不同")
        try expectEqual(a, "claude:s1:3")
    }

    t.test("title：首行压平、超长截断") {
        let short = PromptEntry(
            id: "x", source: .claude, sessionId: "s", messageIdx: 0,
            text: "  修一下登录超时\t的 bug  ", timestamp: nil, cwd: nil, firstSeen: Date())
        try expectEqual(short.title, "修一下登录超时 的 bug")

        let multiLine = PromptEntry(
            id: "x", source: .claude, sessionId: "s", messageIdx: 0,
            text: "第一行提问\n第二行补充说明", timestamp: nil, cwd: nil, firstSeen: Date())
        try expectEqual(multiLine.title, "第一行提问")

        let long = String(repeating: "字", count: 100)
        let entry = PromptEntry(
            id: "x", source: .claude, sessionId: "s", messageIdx: 0,
            text: long, timestamp: nil, cwd: nil, firstSeen: Date())
        try expect(entry.title.hasSuffix("…") && entry.title.count == 61, "超长标题应截断到 60 字 + …")
    }

    t.test("projectName：cwd 尾段；nil cwd → nil") {
        let withCwd = PromptEntry(
            id: "x", source: .claude, sessionId: "s", messageIdx: 0,
            text: "hi", timestamp: nil, cwd: "/w/lulu-lumei-dock", firstSeen: Date())
        try expectEqual(withCwd.projectName, "lulu-lumei-dock")
        let noCwd = PromptEntry(
            id: "x", source: .claude, sessionId: "s", messageIdx: 0,
            text: "hi", timestamp: nil, cwd: nil, firstSeen: Date())
        try expect(noCwd.projectName == nil)
    }

    t.suite("PromptExtractor · 提取过滤")

    func tempJSONL(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-prompts-\(UUID()).jsonl")
        try lines.joined(separator: "\n").data(using: .utf8)?.write(to: url)
        return url
    }

    t.test("只提取真实用户提问；tool_result / assistant / 空白文本全部跳过") {
        // 手搓最小 claude transcript：空白提问、真实提问、tool_result 伪 user、assistant
        let file = try tempJSONL([
            #"{"type":"user","message":{"role":"user","content":"   "},"timestamp":"2026-08-23T10:00:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":"修一下分页越界"},"timestamp":"2026-08-23T10:01:00Z"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]},"timestamp":"2026-08-23T10:02:00Z"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"好的"}]},"timestamp":"2026-08-23T10:03:00Z"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let session = AgentSessionInfo(
            source: .claude, id: "sess-p1", cwd: "/w/proj", name: nil,
            lastActiveAt: Date(), sizeBytes: 0, transcriptPath: file.path)
        let now = Date(timeIntervalSince1970: 500)
        let prompts = PromptExtractor.extract(from: session, at: now)

        try expectEqual(prompts.count, 1, "只应留下 1 条真实提问")
        try expectEqual(prompts[0].text, "修一下分页越界")
        try expectEqual(prompts[0].source, .claude)
        try expectEqual(prompts[0].sessionId, "sess-p1")
        try expectEqual(prompts[0].messageIdx, 1, "messageIdx 应与 transcript 内序号一致")
        try expectEqual(prompts[0].id, "claude:sess-p1:1")
        try expect(prompts[0].timestamp != nil)
    }

    t.test("fixture 回归：claude-transcript-running 恰好 1 条用户提问") {
        let path = try fixtureURL("claude-transcript-running.jsonl")
        let session = AgentSessionInfo(
            source: .claude, id: "sess-fx", cwd: "/w/proj", name: nil,
            lastActiveAt: Date(), sizeBytes: 0, transcriptPath: path.path)
        let prompts = PromptExtractor.extract(from: session, at: Date())
        try expectEqual(prompts.count, 1)
        try expect(prompts[0].text.contains("重构数据管道的增量加载逻辑"))
    }

    t.test("排噪：注入块剥净跳过、caveat 后的真实提问保留、裸斜杠命令跳过") {
        let file = try tempJSONL([
            // 纯斜杠命令回显：剥净剩空 → 跳过
            #"{"type":"user","message":{"role":"user","content":"<command-name>/plan</command-name><command-message>plan</command-message>"},"timestamp":"2026-08-23T10:00:00Z"}"#,
            // caveat 注入块后跟真实提问：剥块后保留提问本体
            #"{"type":"user","message":{"role":"user","content":"<local-command-caveat>注入的说明</local-command-caveat>帮我修复分页越界并补测试"},"timestamp":"2026-08-23T10:01:00Z"}"#,
            // 本地命令输出：跳过
            #"{"type":"user","message":{"role":"user","content":"<local-command-stdout>Enabled plan mode</local-command-stdout>"},"timestamp":"2026-08-23T10:02:00Z"}"#,
            // 裸斜杠命令：跳过
            #"{"type":"user","message":{"role":"user","content":"/compact"},"timestamp":"2026-08-23T10:03:00Z"}"#,
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let session = AgentSessionInfo(
            source: .claude, id: "sess-noise", cwd: "/w/proj", name: nil,
            lastActiveAt: Date(), sizeBytes: 0, transcriptPath: file.path)
        let prompts = PromptExtractor.extract(from: session, at: Date())
        try expectEqual(prompts.count, 1, "四条里只有 caveat 后带真实提问的那条该留下")
        try expectEqual(prompts[0].text, "帮我修复分页越界并补测试", "注入块必须剥净")
    }

    t.test("超长粘贴截断入库（64K 上限 + 截断标记）") {
        let huge = String(repeating: "x", count: 70000)
        let file = try tempJSONL([
            "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(huge)\"},\"timestamp\":\"2026-08-23T10:00:00Z\"}"
        ])
        defer { try? FileManager.default.removeItem(at: file) }
        let session = AgentSessionInfo(
            source: .claude, id: "sess-huge", cwd: nil, name: nil,
            lastActiveAt: Date(), sizeBytes: 0, transcriptPath: file.path)
        let prompts = PromptExtractor.extract(from: session, at: Date())
        try expectEqual(prompts.count, 1)
        try expect(prompts[0].text.hasSuffix("…[已截断]"))
        try expect(prompts[0].text.count < 66000)
    }

    t.suite("PromptsRepo · upsert 与用户标注")

    func tempStore() throws -> (EurekaStore, URL) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-prompts-\(UUID()).sqlite")
        return (try EurekaStore(path: path), path)
    }

    func entry(_ id: String, text: String) -> PromptEntry {
        PromptEntry(
            id: id, source: .claude, sessionId: "sess-1", messageIdx: 0,
            text: text, timestamp: Date(timeIntervalSince1970: 100), cwd: "/w/p",
            firstSeen: Date(timeIntervalSince1970: 200))
    }

    t.test("重提取只刷新正文，收藏/标签/使用计数原样保留") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }

        try store.prompts.upsertExtracted([entry("claude:sess-1:0", text: "原文")])
        // 用户标注
        try store.prompts.setFavorite("claude:sess-1:0", favorite: true)
        try store.prompts.setTags("claude:sess-1:0", tags: ["调试", "分页"])
        try store.prompts.recordUse("claude:sess-1:0", at: Date(timeIntervalSince1970: 300))
        // 会话有新消息 → 重新提取（同 id 文本更新 + 新增一条）
        try store.prompts.upsertExtracted([
            entry("claude:sess-1:0", text: "原文（补充了细节）"),
            entry("claude:sess-1:1", text: "第二条提问"),
        ])

        let all = try store.prompts.all()
        try expectEqual(all.count, 2)
        let updated = all.first { $0.id == "claude:sess-1:0" }
        try expect(updated?.text == "原文（补充了细节）", "正文应刷新为新提取值")
        try expect(updated?.favorite == true, "收藏是用户事实，重提取不得覆盖")
        try expectEqual(updated?.tags ?? [], ["调试", "分页"])
        try expectEqual(updated?.useCount ?? 0, 1)
        try expect(updated?.lastUsedAt == Date(timeIntervalSince1970: 300))
        try expectEqual(try store.prompts.favoriteCount(), 1)
    }

    t.test("提取指纹：markExtracted 幂等覆盖；all 按 first_seen 倒序") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }

        let emptyFingerprints = try store.prompts.extractionFingerprints()
        try expect(emptyFingerprints.isEmpty)
        try store.prompts.markExtracted(
            sessionId: "s1", source: .claude, at: Date(timeIntervalSince1970: 100))
        try store.prompts.markExtracted(
            sessionId: "s1", source: .claude, at: Date(timeIntervalSince1970: 200))
        let fingerprints = try store.prompts.extractionFingerprints()
        try expectEqual(fingerprints["s1"], Date(timeIntervalSince1970: 200), "后值覆盖前值")

        // second 的 first_seen 更晚 → 排前（first_seen 倒序 = 最新提问在前）
        let first = PromptEntry(
            id: "claude:a:0", source: .claude, sessionId: "a", messageIdx: 0,
            text: "早", timestamp: nil, cwd: nil,
            firstSeen: Date(timeIntervalSince1970: 500))
        let second = PromptEntry(
            id: "claude:b:0", source: .claude, sessionId: "b", messageIdx: 0,
            text: "晚", timestamp: nil, cwd: nil,
            firstSeen: Date(timeIntervalSince1970: 999))
        try store.prompts.upsertExtracted([first, second])
        let all = try store.prompts.all()
        try expectEqual(all.map(\.id), ["claude:b:0", "claude:a:0"], "first_seen 倒序")
    }

    t.test("单条删除；entry(id:) 精确取回") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }
        try store.prompts.upsertExtracted([
            entry("claude:sess-1:0", text: "a"),
            PromptEntry(
                id: "claude:sess-2:0", source: .codex, sessionId: "sess-2", messageIdx: 0,
                text: "b", timestamp: nil, cwd: nil, firstSeen: Date()),
        ])
        try store.prompts.hide("claude:sess-1:0")
        let removed = try store.prompts.entry(id: "claude:sess-1:0")
        try expect(removed == nil)
        let kept = try store.prompts.entry(id: "claude:sess-2:0")
        try expect(kept?.text == "b")
        try expectEqual(try store.prompts.all().count, 1)
    }

    t.test("移除是用户事实：会话重提取不复活；all / favoriteCount / entry / 周报都不再计入") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }
        let removedId = "claude:sess-1:0"
        try store.prompts.upsertExtracted([
            entry(removedId, text: "被移除的提问"),
            entry("claude:sess-1:1", text: "留下的提问"),
        ])
        try store.prompts.setFavorite(removedId, favorite: true)
        try store.prompts.recordUse(removedId, at: Date(timeIntervalSince1970: 150))
        try store.prompts.hide(removedId)
        // 会话还在活跃：下一次增量提取会把同一批 prompt 再 upsert 一遍
        try store.prompts.upsertExtracted([
            entry(removedId, text: "被移除的提问（会话追加后重提取）"),
            entry("claude:sess-1:1", text: "留下的提问"),
        ])
        try expectEqual(
            try store.prompts.all().map(\.id), ["claude:sess-1:1"],
            "被移除的条目不得随重提取复活")
        let hidden = try store.prompts.entry(id: removedId)
        try expect(hidden == nil, "entry(id:) 不应再取回被移除的条目")
        try expectEqual(try store.prompts.favoriteCount(), 0, "被移除条目的收藏不再计入")
        let stats = try store.prompts.weeklyStats(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 1_000))
        try expectEqual(stats.askedCount, 1, "被移除条目不计入周报提问数")
        try expect(stats.topReused.isEmpty, "被移除条目的复用记录不进周报")
    }

    t.test("tags JSON 编解码：空数组与非 ASCII 往返") {
        try expectEqual(PromptsRepo.encodeTags([]), "[]")
        let tags = ["重构", "auth-service"]
        try expectEqual(PromptsRepo.decodeTags(PromptsRepo.encodeTags(tags)), tags)
        try expectEqual(PromptsRepo.decodeTags(nil), [])
        try expectEqual(PromptsRepo.decodeTags("not-json"), [])
    }

    t.suite("PromptsRepo · 周报统计")

    t.test("窗口内新提问计数（timestamp 优先、缺失退化 first_seen）+ 复用按 last_used_at 落窗") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }

        let inWindow = Date(timeIntervalSince1970: 1500)
        let outWindow = Date(timeIntervalSince1970: 2500)
        // 两条窗口内提问（timestamp 落窗）
        try store.prompts.upsertExtracted([
            PromptEntry(
                id: "claude:s1:0", source: .claude, sessionId: "s1", messageIdx: 0,
                text: "窗口内提问一", timestamp: inWindow, cwd: nil, firstSeen: outWindow),
            PromptEntry(
                id: "codex:s2:0", source: .codex, sessionId: "s2", messageIdx: 0,
                text: "窗口内提问二", timestamp: inWindow, cwd: nil, firstSeen: outWindow),
        ])
        // 一条窗口外提问（timestamp 与 first_seen 都在窗外）
        try store.prompts.upsertExtracted([
            PromptEntry(
                id: "claude:s3:0", source: .claude, sessionId: "s3", messageIdx: 0,
                text: "窗口外提问", timestamp: outWindow, cwd: nil, firstSeen: outWindow),
        ])
        // 一条 timestamp 缺失 → 退化用 first_seen 落窗
        try store.prompts.upsertExtracted([
            PromptEntry(
                id: "claude:s4:0", source: .claude, sessionId: "s4", messageIdx: 0,
                text: "无时间戳提问", timestamp: nil, cwd: nil, firstSeen: inWindow),
        ])
        // 复用：s1 两次都在窗口内；s3 只在窗口外用过
        try store.prompts.recordUse("claude:s1:0", at: inWindow)
        try store.prompts.recordUse("claude:s1:0", at: inWindow)
        try store.prompts.recordUse("claude:s3:0", at: outWindow)

        let stats = try store.prompts.weeklyStats(
            from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 2000))
        try expectEqual(stats.askedCount, 3, "2 条 timestamp 落窗 + 1 条退化 first_seen")
        try expectEqual(stats.bySource[.claude] ?? 0, 2)
        try expectEqual(stats.bySource[.codex] ?? 0, 1)
        try expectEqual(stats.topReused.count, 1, "只有 s1 的 last_used_at 落窗")
        try expectEqual(stats.topReused[0].id, "claude:s1:0")
        try expectEqual(stats.topReused[0].useCount, 2)
    }

    t.test("asked 口径排除存量噪音（`<` 标签前缀与 `/` 斜杠命令），与分类器判据一致") {
        let (store, dbPath) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dbPath) }
        func at(_ id: String, text: String) -> PromptEntry {
            PromptEntry(
                id: id, source: .claude, sessionId: "s", messageIdx: 0,
                text: text, timestamp: Date(timeIntervalSince1970: 1500), cwd: nil,
                firstSeen: Date(timeIntervalSince1970: 1500))
        }
        try store.prompts.upsertExtracted([
            at("claude:s:0", text: "<command-name>/plan</command-name>"),
            at("claude:s:1", text: "/compact"),
            at("claude:s:2", text: "真实提问：修复分页越界"),
        ])
        let stats = try store.prompts.weeklyStats(
            from: Date(timeIntervalSince1970: 1000), to: Date(timeIntervalSince1970: 2000))
        try expectEqual(stats.askedCount, 1, "两条噪音行不计入 asked")
        // SQL 侧近似判据必须与内存分类器一致：这三条里恰好前两条是 noise
        try expectEqual(PromptClassifier.classify("<command-name>/plan</command-name>"), .noise)
        try expectEqual(PromptClassifier.classify("/compact"), .noise)
        try expect(PromptClassifier.classify("真实提问：修复分页越界") != .noise)
    }
}
