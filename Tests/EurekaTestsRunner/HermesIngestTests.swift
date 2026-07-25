import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

func hermesIngestTests(_ t: TestRunner) {
    t.suite("Hermes · 会话/对话/用量/技能/配置")

    /// 造一个最小 state.db（表结构取真实 schema v23 的相关列），并塞入一个会话 + 消息 + 用量行
    func makeStateDB(
        endedAt: Double? = nil,
        input: Int = 1000, output: Int = 200, cacheRead: Int = 5000, cacheWrite: Int = 0,
        reasoning: Int = 50,
        auxiliary: Bool = false
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-hermes-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("state.db")
        let db = try SQLiteDB(path: path.path)
        try db.run("""
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, source TEXT NOT NULL, model TEXT,
            parent_session_id TEXT, started_at REAL NOT NULL, ended_at REAL, end_reason TEXT,
            message_count INTEGER DEFAULT 0, tool_call_count INTEGER DEFAULT 0,
            input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
            cache_read_tokens INTEGER DEFAULT 0, cache_write_tokens INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            cwd TEXT, title TEXT, api_call_count INTEGER DEFAULT 0,
            estimated_cost_usd REAL, actual_cost_usd REAL, cost_status TEXT,
            archived INTEGER NOT NULL DEFAULT 0)
        """)
        try db.run("""
        CREATE TABLE messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL, role TEXT NOT NULL,
            content TEXT, tool_name TEXT, timestamp REAL NOT NULL)
        """)
        try db.run("""
        CREATE TABLE session_model_usage (
            session_id TEXT NOT NULL, model TEXT NOT NULL,
            billing_provider TEXT NOT NULL DEFAULT '', billing_base_url TEXT NOT NULL DEFAULT '',
            billing_mode TEXT NOT NULL DEFAULT '', task TEXT NOT NULL DEFAULT '',
            api_call_count INTEGER NOT NULL DEFAULT 0,
            input_tokens INTEGER NOT NULL DEFAULT 0, output_tokens INTEGER NOT NULL DEFAULT 0,
            cache_read_tokens INTEGER NOT NULL DEFAULT 0,
            cache_write_tokens INTEGER NOT NULL DEFAULT 0,
            reasoning_tokens INTEGER NOT NULL DEFAULT 0,
            estimated_cost_usd REAL NOT NULL DEFAULT 0, actual_cost_usd REAL NOT NULL DEFAULT 0,
            cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL,
            PRIMARY KEY (session_id, model, billing_provider, billing_base_url,
                         billing_mode, task))
        """)
        let start: Double = 1_700_000_000
        try db.run("""
        INSERT INTO sessions (id, source, model, started_at, ended_at, end_reason,
            message_count, tool_call_count, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, reasoning_tokens, cwd, title,
            cost_status, estimated_cost_usd)
        VALUES ('20260101_120000_abc123','cli','gpt-5.6-sol',?,?,NULL,3,1,?,?,?,?,?,
                '/tmp/demo-project','演示会话','included',0)
        """, [
            .real(start), endedAt.map { SQLiteValue.real($0) } ?? .null,
            .int(Int64(input)), .int(Int64(output)),
            .int(Int64(cacheRead)), .int(Int64(cacheWrite)), .int(Int64(reasoning)),
        ])
        for (offset, row) in [("user", "你好", ""), ("assistant", "在", ""),
                              ("tool", "", "read_file")].enumerated() {
            try db.run("""
            INSERT INTO messages (session_id, role, content, tool_name, timestamp)
            VALUES ('20260101_120000_abc123',?,?,?,?)
            """, [
                .text(row.0), .text(row.1),
                row.2.isEmpty ? .null : .text(row.2), .real(start + Double(offset)),
            ])
        }
        try db.run("""
        INSERT INTO session_model_usage (session_id, model, task, input_tokens, output_tokens,
            cache_read_tokens, cache_write_tokens, reasoning_tokens, cost_status, last_seen)
        VALUES ('20260101_120000_abc123','gpt-5.6-sol','',?,?,?,?,?, 'included', ?)
        """, [
            .int(Int64(input)), .int(Int64(output)), .int(Int64(cacheRead)),
            .int(Int64(cacheWrite)), .int(Int64(reasoning)), .real(start + 10),
        ])
        if auxiliary {
            try db.run("""
            INSERT INTO session_model_usage (session_id, model, task, input_tokens,
                output_tokens, cache_read_tokens, cache_write_tokens, last_seen)
            VALUES ('20260101_120000_abc123','gpt-5-mini','title_generation',100,17,0,0,?)
            """, [.real(start + 11)])
        }
        return path
    }

    t.test("会话索引：读 sessions 表，未收尾会话用最后一条消息当最近活跃") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let sessions = HermesSessionIndexer.index(
            dbPath: db, window: .infinity, now: Date(timeIntervalSince1970: 1_700_001_000))
        try expectEqual(sessions.count, 1)
        let session = try require(sessions.first)
        try expectEqual(session.source, .hermes)
        try expectEqual(session.id, "20260101_120000_abc123")
        try expectEqual(session.name, "演示会话")
        try expectEqual(session.cwd, "/tmp/demo-project")
        // ended_at 为空 → 取最后一条消息的时间（start + 2），不是 started_at
        try expectEqual(session.lastActiveAt.timeIntervalSince1970, 1_700_000_002)
        try expectEqual(session.transcriptPath, db.path)
    }

    t.test("会话索引：归档与子会话不进列表") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let handle = try SQLiteDB(path: db.path)
        try handle.run("""
        INSERT INTO sessions (id, source, started_at, archived) VALUES ('arch','cli',1,1)
        """)
        try handle.run("""
        INSERT INTO sessions (id, source, started_at, parent_session_id)
        VALUES ('child','cli',1,'20260101_120000_abc123')
        """)
        let ids = HermesSessionIndexer.index(dbPath: db, window: .infinity).map(\.id)
        try expect(!ids.contains("arch"), "归档会话不应出现")
        try expect(!ids.contains("child"), "子会话（delegate/压缩分裂）不应出现")
    }

    t.test("对话读取：user/assistant 正文 + tool 转工具注记，时间是 epoch 秒") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let session = try require(HermesSessionIndexer.index(dbPath: db, window: .infinity).first)
        let result = TranscriptReader.load(session: session)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "你好")
        try expectEqual(result.messages[1].role, .assistant)
        try expectEqual(result.messages[2].role, .toolNote)
        try expect(result.messages[2].text.contains("read_file"), "工具注记应带工具名")
        try expectEqual(
            try require(result.messages[0].timestamp).timeIntervalSince1970, 1_700_000_000)
    }

    t.test("用量：input 已扣缓存不重复加，reasoning 不另计（口径核验）") {
        let db = try makeStateDB(input: 1000, output: 200, cacheRead: 5000, cacheWrite: 30,
                                 reasoning: 50)
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let storeURL = db.deletingLastPathComponent().appendingPathComponent("eureka.sqlite")
        let store = try EurekaStore(path: storeURL)
        let scanner = HermesUsageScanner(stateDBs: [db], store: store)
        try expectEqual(try scanner.scanOnce(), 1)
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
        let row = try require(totals.first)
        try expectEqual(row.model, "gpt-5.6-sol")
        try expectEqual(row.inputTokens, 1000)
        try expectEqual(row.outputTokens, 200, "output 里已含 reasoning，不能再加 50")
        try expectEqual(row.cacheReadTokens, 5000)
        try expectEqual(row.cacheCreationTokens, 30)
    }

    t.test("用量：重复扫描不重复计（原地累加的行只记增量）") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let storeURL = db.deletingLastPathComponent().appendingPathComponent("eureka.sqlite")
        let store = try EurekaStore(path: storeURL)
        let scanner = HermesUsageScanner(stateDBs: [db], store: store)
        try expectEqual(try scanner.scanOnce(), 1)
        try expectEqual(try scanner.scanOnce(), 0, "第二轮不应再记")

        // 会话继续增长：只应记录增量部分
        let handle = try SQLiteDB(path: db.path)
        try handle.run("""
        UPDATE session_model_usage SET output_tokens = output_tokens + 70, last_seen = last_seen + 60
        """)
        let grown = try scanner.scanOnce()
        try expect(grown > 0, "有新增量时应产生记录")
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
        try expectEqual(totals.reduce(0) { $0 + $1.outputTokens }, 270, "累计 output 应为 200+70")
    }

    t.test("用量：辅助模型单独成行，且不被残差重复计一遍") {
        let db = try makeStateDB(auxiliary: true)
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        let storeURL = db.deletingLastPathComponent().appendingPathComponent("eureka.sqlite")
        let store = try EurekaStore(path: storeURL)
        let scanner = HermesUsageScanner(stateDBs: [db], store: store)
        _ = try scanner.scanOnce()
        let totals = try store.usage.totalsByModel(
            from: Date(timeIntervalSince1970: 0), to: Date(timeIntervalSince1970: 4_000_000_000))
        let models = Set(totals.map(\.model))
        try expect(models.contains("gpt-5-mini"), "title_generation 的辅助模型应单独入账")
        // sessions 聚合只含主循环 → 残差为 0，总量 = 主循环 + 辅助，不多不少
        let total = totals.reduce(0) {
            $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheCreationTokens
        }
        try expectEqual(total, 1000 + 200 + 5000 + 100 + 17)
    }

    t.test("实时监视：首扫只记水位不回放历史") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [db] }) { event, _ in events.append(event) }
        tailer.scanOnce(now: Date(timeIntervalSince1970: 1_700_000_100))
        try expectEqual(events.count, 0, "首扫必须静默，否则每次启动都回放历史会话")
    }

    t.test("实时监视：水位建立后新开的会话走「开始 → 完成」两步") {
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [db] }) { event, _ in events.append(event) }
        let base: Double = 1_700_000_100
        tailer.scanOnce(now: Date(timeIntervalSince1970: base))  // 建水位
        try expectEqual(events.count, 0)

        // 水位之后新出现的会话（started_at 就在当下）才算真·新任务
        let handle = try SQLiteDB(path: db.path)
        try handle.run("""
        INSERT INTO sessions (id, source, model, started_at, message_count, cwd, title)
        VALUES ('20260101_130000_def456','cli','gpt-5.6-sol',?,1,'/tmp/demo-project','新任务')
        """, [.real(base + 1)])
        tailer.scanOnce(now: Date(timeIntervalSince1970: base + 2))
        try expectEqual(events.count, 1, "新会话应产出开始事件")
        try expectEqual(events[0].sessionId, "20260101_130000_def456")

        try handle.run(
            "UPDATE sessions SET ended_at = ? WHERE id = '20260101_130000_def456'",
            [.real(base + 3)])
        tailer.scanOnce(now: Date(timeIntervalSince1970: base + 4))
        try expectEqual(events.count, 2, "ended_at 落地后应再产出完成事件")
    }

    t.test("实时监视：启动前就在跑的会话首扫只记水位，随后收尾也不补卡") {
        // Hermes 只在干净退出时写 ended_at → 时间窗内每个被 kill 的会话都永远是 ended_at IS NULL。
        // 若首扫把它们当活跃，启动瞬间就会因空闲收尾刷出一堆完成卡，故首扫一律记为已收尾。
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [db] }) { event, _ in events.append(event) }
        let base: Double = 1_700_000_100
        tailer.scanOnce(now: Date(timeIntervalSince1970: base))
        let handle = try SQLiteDB(path: db.path)
        try handle.run("UPDATE sessions SET ended_at = ?", [.real(base + 1)])
        tailer.scanOnce(now: Date(timeIntervalSince1970: base + 2))
        try expectEqual(events.count, 0, "首扫已见过的会话即便随后收尾，也不该补出卡片")
    }

    t.test("实时监视：启动前就在跑的会话一旦有推进就出卡（真在干活的不能被水位埋掉）") {
        // 上一条测的是「不推进则静默」。这条钉住反面：水位记为已收尾的行若计数器往前走，
        // 说明它真在跑，必须补出开始卡 —— 否则启动前开的会话在 app 里永远是隐身的。
        let db = try makeStateDB()
        defer { try? FileManager.default.removeItem(at: db.deletingLastPathComponent()) }
        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [db] }) { event, _ in events.append(event) }
        let base: Double = 1_700_000_100
        tailer.scanOnce(now: Date(timeIntervalSince1970: base))
        try expectEqual(events.count, 0, "首扫只记水位")

        let handle = try SQLiteDB(path: db.path)
        try handle.run("UPDATE sessions SET message_count = message_count + 3")
        tailer.scanOnce(now: Date(timeIntervalSince1970: base + 2))
        try expectEqual(events.count, 1, "计数器推进 → 补出开始卡")
        guard case .taskStarted = events[0].kind else {
            throw ExpectationError(description: "水位态推进应出 taskStarted，实际 \(events[0].kind)")
        }
        // 第二次推进是心跳而非重复开始卡
        try handle.run("UPDATE sessions SET tool_call_count = tool_call_count + 1")
        tailer.scanOnce(now: Date(timeIntervalSince1970: base + 4))
        try expectEqual(events.count, 2)
        guard case .activity = events[1].kind else {
            throw ExpectationError(description: "已活跃会话再推进应出 activity，实际 \(events[1].kind)")
        }
    }

    t.test("未装 Hermes：四条读取路径全部安静返回空，不抛不炸") {
        // 绝大多数用户没有 ~/.hermes。这几条断言把「静默降级」钉死，
        // 免得后续重构掉一个 try? 就变成启动报错 / 红灯。
        let nowhere = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-no-hermes-\(UUID())", isDirectory: true)
        let env = ["EUREKA_HERMES_HOME": nowhere.path]
        try expectEqual(HermesPaths.allStateDBs(environment: env).count, 0, "库不存在应被过滤掉")
        try expectEqual(HermesSessionIndexer.indexAll(environment: env).count, 0)
        try expectEqual(HermesSessionIndexer.recentDirectories(environment: env).count, 0)

        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [] }) { event, _ in events.append(event) }
        tailer.scanOnce(now: Date(timeIntervalSince1970: 1_700_000_100))
        try expectEqual(events.count, 0, "无库时轮询不该产出任何事件")

        try FileManager.default.createDirectory(at: nowhere, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: nowhere) }
        let store = try EurekaStore(path: nowhere.appendingPathComponent("eureka.sqlite"))
        try expectEqual(try HermesUsageScanner(stateDBs: [], store: store).scanOnce(), 0)
        try expectEqual(
            SkillMemoryIndexer.indexSkills(
                claudeSkillsRoot: nowhere.appendingPathComponent("nx"),
                codexSkillsRoot: nowhere.appendingPathComponent("nx"),
                hermesSkillsRoot: nowhere.appendingPathComponent("skills")).count,
            0, "技能根不存在应返回空")
        // config.yaml 不存在 → 读成空串，禁用名单为空，且不该凭空建块
        try expectEqual(HermesConfigEditor.disabledSkills(from: ""), Set<String>())
        try expectEqual(HermesConfigEditor.setSkillDisabled("plan", disabled: false, in: ""), "")
    }

    t.test("state.db 存在但 schema 不认识：查询失败也只是空结果") {
        // 用户可能装了老版 / 新版 Hermes，表名或列不一样；此时必须静默跳过而不是崩。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-hermes-badschema-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.db")
        let db = try SQLiteDB(path: path.path)
        try db.run("CREATE TABLE unrelated (id TEXT)")

        try expectEqual(
            HermesSessionIndexer.index(dbPath: path, maxSessions: 10).count, 0,
            "没有 sessions 表应返回空而不是抛错")
        var events: [TaskEvent] = []
        let tailer = HermesStateTailer(stateDBs: { [path] }) { event, _ in events.append(event) }
        tailer.scanOnce(now: Date(timeIntervalSince1970: 1_700_000_100))
        try expectEqual(events.count, 0)
        let store = try EurekaStore(path: dir.appendingPathComponent("eureka.sqlite"))
        try expectEqual(try HermesUsageScanner(stateDBs: [path], store: store).scanOnce(), 0)
    }

    t.test("技能树：递归扫分类/子分类/顶层三种深度，跳过 references 等支持目录") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("eureka-hermes-skills-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        func writeSkill(_ relative: String, name: String) throws {
            let dir = root.appendingPathComponent(relative, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try "---\nname: \(name)\ndescription: 演示\n---\n正文\n".write(
                to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        }
        try writeSkill("creative/ascii-art", name: "ascii-art")           // 分类
        try writeSkill("mlops/inference/vllm", name: "vllm")              // 子分类
        try writeSkill("computer-use", name: "computer-use")              // 顶层
        // 支持目录里的 SKILL.md 不算技能
        try writeSkill("creative/ascii-art/references", name: "should-be-ignored")
        try writeSkill("creative/ascii-art/templates", name: "also-ignored")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: root.appendingPathComponent("nx"),
            codexSkillsRoot: root.appendingPathComponent("nx"),
            hermesSkillsRoot: root,
            hermesDisabledSkills: ["vllm"])
        try expectEqual(Set(skills.map(\.name)), Set(["ascii-art", "vllm", "computer-use"]))
        try expect(skills.allSatisfy { $0.source == .hermes })
        try expectEqual(skills.first { $0.name == "ascii-art" }?.description, "演示")
        // 启停由 config.yaml 名单决定，与目录位置无关
        try expectEqual(skills.first { $0.name == "vllm" }?.enabled, false)
        try expectEqual(skills.first { $0.name == "ascii-art" }?.enabled, true)
    }

    t.test("记忆：MEMORY.md / USER.md / SOUL.md 三份，全局无项目级") {
        let fm = FileManager.default
        let home = fm.temporaryDirectory
            .appendingPathComponent("eureka-hermes-home-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: home) }
        try fm.createDirectory(
            at: home.appendingPathComponent("memories"), withIntermediateDirectories: true)
        try "记忆一\n§\n记忆二\n".write(
            to: home.appendingPathComponent("memories/MEMORY.md"),
            atomically: true, encoding: .utf8)
        try "用户偏好\n".write(
            to: home.appendingPathComponent("memories/USER.md"), atomically: true, encoding: .utf8)
        try "你是 Hermes\n".write(
            to: home.appendingPathComponent("SOUL.md"), atomically: true, encoding: .utf8)

        let nx = home.appendingPathComponent("nx")
        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: nx, codexHome: nx, opencodeHome: nx, claudeProjectsRoot: nx,
            hermesHome: home)
        try expectEqual(Set(memories.map(\.scope)), Set(["MEMORY", "USER", "SOUL"]))
        try expect(memories.allSatisfy { $0.source == .hermes })
        try expect(memories.allSatisfy { $0.projectName == nil }, "Hermes 没有项目级记忆")
    }

    t.test("计划：项目内 .hermes/plans 直接索引，无需物化") {
        let fm = FileManager.default
        let repo = fm.temporaryDirectory
            .appendingPathComponent("eureka-hermes-repo-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: repo) }
        let plans = HermesPaths.projectPlansDir(repoRoot: repo)
        try fm.createDirectory(at: plans, withIntermediateDirectories: true)
        try "# 演示计划\n\n目标说明\n\n- [x] 一\n- [ ] 二\n".write(
            to: plans.appendingPathComponent("2026-01-01_120000-demo.md"),
            atomically: true, encoding: .utf8)

        let nx = repo.appendingPathComponent("nx")
        let indexed = PlanMaterializer.index(
            claudePlansDir: nx, stagingRoot: nx, hermesPlansDirs: [plans])
        try expectEqual(indexed.count, 1)
        let plan = try require(indexed.first)
        try expectEqual(plan.source, .hermes)
        try expectEqual(plan.title, "演示计划")
        try expectEqual(plan.stepsDone, 1)
        try expectEqual(plan.stepsTotal, 2)
        try expectEqual(plan.status, .inProgress)
    }

    t.suite("Hermes · config.yaml skills.disabled 编辑")

    t.test("流式与块式列表都能解析，platform_disabled 不误判") {
        let flow = "skills:\n  disabled: [a, \"b c\"]\n  platform_disabled:\n    telegram: [x]\n"
        try expectEqual(HermesConfigEditor.disabledSkills(from: flow), Set(["a", "b c"]))
        let block = "skills:\n  disabled:\n    - one   # 注释\n    - two\n"
        try expectEqual(HermesConfigEditor.disabledSkills(from: block), Set(["one", "two"]))
        // 只有 platform_disabled，没有 disabled → 空集（不能把 telegram 名单当成全局名单）
        let onlyPlatform = "skills:\n  platform_disabled:\n    telegram: [x]\n"
        try expectEqual(HermesConfigEditor.disabledSkills(from: onlyPlatform), [])
    }

    t.test("增删保留原列表风格与注释，且幂等") {
        let block = "skills:\n  disabled:\n    - one   # 保留我\n"
        let added = HermesConfigEditor.setSkillDisabled("two", disabled: true, in: block)
        try expect(added.contains("# 保留我"), "行尾注释必须原样保留")
        try expect(added.contains("    - two"), "块式风格应延续，不能改写成流式")
        try expectEqual(HermesConfigEditor.disabledSkills(from: added), Set(["one", "two"]))
        try expectEqual(
            HermesConfigEditor.setSkillDisabled("two", disabled: true, in: added), added,
            "重复禁用应为空操作")
        let removed = HermesConfigEditor.setSkillDisabled("two", disabled: false, in: added)
        try expectEqual(HermesConfigEditor.disabledSkills(from: removed), Set(["one"]))
        try expectEqual(
            HermesConfigEditor.setSkillDisabled("zzz", disabled: false, in: block), block,
            "启用一个本就没禁用的技能应为空操作")
    }

    t.test("缺 skills: 块时补建；platform_disabled 之外的块不受影响") {
        let doc = "model:\n  default: gpt-5\n"
        let added = HermesConfigEditor.setSkillDisabled("plan", disabled: true, in: doc)
        try expect(added.hasPrefix("model:\n  default: gpt-5"), "既有块必须原样保留")
        try expectEqual(HermesConfigEditor.disabledSkills(from: added), Set(["plan"]))
        // 启用态下缺块 → 什么都不做（不该为了删而先建一个块）
        try expectEqual(
            HermesConfigEditor.setSkillDisabled("plan", disabled: false, in: doc), doc)
    }
}

/// 小工具：Optional 解包失败即报错（避免测试里散落 force unwrap）
private func require<T>(
    _ value: T?, file: StaticString = #filePath, line: UInt = #line
) throws -> T {
    guard let value else {
        throw ExpectationError(description: "期望非 nil，实际为 nil at \(file):\(line)")
    }
    return value
}
