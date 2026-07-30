import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// Cursor ingest 测试：fixture 按本机真实库（Cursor 3.13.10 的
/// `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb`）的表结构与
/// JSON 形状现造，路径/会话 id 全部换成假值；全程临时目录，不碰真实 ~/。
func cursorIngestTests(_ t: TestRunner) {
    cursorPathsTests(t)
    cursorToolNamesTests(t)
    cursorWorkspaceIndexTests(t)
    cursorStateTailerTests(t)
    cursorSessionIndexerTests(t)
    cursorUsageScannerTests(t)
    cursorAuditScannerTests(t)
    cursorPlanMaterializerTests(t)
    cursorKnowledgeTests(t)
    cursorTranscriptTests(t)
}

// MARK: - agent-transcripts（第二条实时通道）

/// fixture 按实勘的真实行照抄：
///   `{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>…</timestamp>\n<user_query>\n…\n</user_query>"}]}}`
///   `{"role":"assistant","message":{"content":[{"type":"text",…},{"type":"tool_use","name":"Read",…}]}}`
///   `{"type":"turn_ended","status":"success"}`
private func cursorTranscriptTests(_ t: TestRunner) {
    let cwd = "/Users/me/work/alpha"
    // Cursor 的项目目录名：去掉开头 /，其余 / 与 . 都换成 -
    let slug = "Users-me-work-alpha"

    func makeHome() throws -> (cli: URL, wsRoot: URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cursor-tx-\(UUID().uuidString)", isDirectory: true)
        let wsRoot = base.appendingPathComponent("wsStorage", isDirectory: true)
        let wsDir = wsRoot.appendingPathComponent("ws1", isDirectory: true)
        try FileManager.default.createDirectory(at: wsDir, withIntermediateDirectories: true)
        try Data(#"{"folder":"file://\#(cwd)"}"#.utf8)
            .write(to: wsDir.appendingPathComponent("workspace.json"))
        return (base.appendingPathComponent("cli", isDirectory: true), wsRoot)
    }
    func transcriptURL(cli: URL, composerId: String) -> URL {
        cli.appendingPathComponent(
            "projects/\(slug)/agent-transcripts/\(composerId)/\(composerId).jsonl")
    }
    func append(_ lines: [String], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + "\n"
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } else {
            try Data(text.utf8).write(to: url)
        }
    }
    let userLine = #"{"role":"user","message":{"content":[{"type":"text","text":"<timestamp>Monday, Jul 27, 2026, 3:25 PM (UTC+8)</timestamp>\n<user_query>\n分析一下 semantic-sql 模块\n</user_query>"}]}}"#
    let toolLine = #"{"role":"assistant","message":{"content":[{"type":"text","text":"我先看目录"},{"type":"tool_use","name":"Read","input":{"path":"README.md"}},{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}"#
    let textLine = #"{"role":"assistant","message":{"content":[{"type":"text","text":"分析完了"}]}}"#
    let endLine = #"{"type":"turn_ended","status":"success"}"#

    t.suite("CursorTranscriptDecoder · Claude 式转录行")

    t.test("user 取 <user_query> 内容做标题；tool_use 取最后一个；turn_ended 收尾") {
        func decode(_ line: String) -> TaskEvent? {
            CursorTranscriptDecoder.decode(
                line: Data(line.utf8), sessionId: "c1", cwd: cwd)
        }
        guard case .taskStarted(let title)? = decode(userLine)?.kind else {
            throw ExpectationError(description: "user 行应出 taskStarted")
        }
        try expectEqual(title, "分析一下 semantic-sql 模块", "应剥掉 <timestamp> 包装")

        guard case .activity(let tool)? = decode(toolLine)?.kind else {
            throw ExpectationError(description: "tool_use 行应出 activity")
        }
        try expectEqual(tool, "Grep", "同一行多个 tool_use 取最后一个")

        guard case .activity(let none)? = decode(textLine)?.kind else {
            throw ExpectationError(description: "纯文本行应出心跳")
        }
        try expect(none == nil, "纯文本心跳不带工具名")

        guard case .taskFinished(let outcome, _, _)? = decode(endLine)?.kind else {
            throw ExpectationError(description: "turn_ended 应出 taskFinished")
        }
        try expectEqual(outcome, .success)
        // 工具名是 Claude 词表，不该被库侧的 CursorToolNames 归一化动过
        try expectEqual(CursorTranscriptDecoder.lastToolName(
            (try? JSONSerialization.jsonObject(with: Data(toolLine.utf8))) as? [String: Any] ?? [:]),
            "Grep")
    }

    t.suite("CursorTranscriptIndex · 路径与 cwd")

    t.test("slug 正向编码匹配已知 workspace 得 cwd（不反解有损 slug）") {
        try expectEqual(CursorTranscriptIndex.slug(forPath: cwd), slug)
        try expectEqual(
            CursorTranscriptIndex.slug(forPath: "/Users/me/w/a.b-c"), "Users-me-w-a-b-c")

        let (cli, wsRoot) = try makeHome()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        try append([userLine], to: transcriptURL(cli: cli, composerId: "c1"))
        CursorWorkspaceIndex.resetCacheForTesting()
        CursorTranscriptIndex.resetCacheForTesting()

        let entries = CursorTranscriptIndex.entries(cliHome: cli, workspaceStorageRoot: wsRoot)
        try expectEqual(entries.count, 1)
        try expectEqual(entries.first?.composerId, "c1")
        try expectEqual(entries.first?.cwd, cwd)
        try expectEqual(
            CursorTranscriptIndex.ownedComposerIds(cliHome: cli, workspaceStorageRoot: wsRoot),
            ["c1"])
    }

    t.suite("CursorTranscriptTailer · 实时事件")

    t.test("已收尾的历史回合首见时静默；增量追加走 start→activity→finish") {
        let (cli, wsRoot) = try makeHome()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let done = transcriptURL(cli: cli, composerId: "c-done")
        try append([userLine, toolLine, textLine, endLine], to: done)
        CursorWorkspaceIndex.resetCacheForTesting()
        CursorTranscriptIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = CursorTranscriptTailer(
            cliHome: cli, workspaceStorageRoot: wsRoot, staleThreshold: 3600
        ) { events.append(($0, $1)) }
        tailer.scanOnce()
        try expectEqual(events.count, 0, "已收尾的历史回合不得重放，实得 \(events.map(\.0.kind))")

        // 新回合：逐行追加（模拟边跑边写）
        let live = transcriptURL(cli: cli, composerId: "c-live")
        try append([userLine], to: live)
        CursorTranscriptIndex.resetCacheForTesting()
        tailer.scanOnce()  // 首见 c-live：未收尾 → 补运行卡
        try expect(
            events.contains { if case .taskStarted = $0.0.kind { return true } else { return false } },
            "回合中途首见应补开始卡，实得 \(events.map(\.0.kind))")
        try expectEqual(events.first?.0.sessionId, "c-live")
        try expectEqual(events.first?.0.cwd, cwd)
        try expectEqual(events.first?.0.source, .cursor)

        events.removeAll()
        try append([toolLine], to: live)
        tailer.scanOnce()
        guard case .activity(let tool)? = events.first?.0.kind else {
            throw ExpectationError(description: "应出 activity，实得 \(events.map(\.0.kind))")
        }
        try expectEqual(tool, "Grep")

        events.removeAll()
        try append([endLine], to: live)
        tailer.scanOnce()
        guard case .taskFinished(let outcome, let title, _)? = events.first?.0.kind else {
            throw ExpectationError(description: "应出 taskFinished，实得 \(events.map(\.0.kind))")
        }
        try expectEqual(outcome, .success)
        try expectEqual(title, "分析一下 semantic-sql 模块", "收尾行不带标题，应补本轮提问摘要")
    }

    t.test("empty-window（cwd 为 nil）也能反复尾随——曾在这条路径上崩过") {
        // 回归：`contexts[path]?.cwd = entry.cwd ?? contexts[path]?.cwd` 里左边是独占的
        // 修改访问、右边又读同一个键，重叠访问会让 Swift 直接 abort（Fatal access conflict）。
        // `??` 在 cwd 非 nil 时短路，所以只有无 cwd 的会话会踩到 —— 上一版测试全都带 cwd，
        // 于是漏了，真机一开就崩。这里专门用 empty-window（Cursor 没打开工程时的窗口）。
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cursor-ew-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let cli = base.appendingPathComponent("cli", isDirectory: true)
        let wsRoot = base.appendingPathComponent("wsStorage", isDirectory: true)
        try FileManager.default.createDirectory(at: wsRoot, withIntermediateDirectories: true)
        // 转录落在 empty-window 目录下 → 没有任何 workspace 能匹配上这个 slug
        let url = cli.appendingPathComponent(
            "projects/empty-window/agent-transcripts/c-ew/c-ew.jsonl")
        try append([userLine], to: url)
        CursorWorkspaceIndex.resetCacheForTesting()
        CursorTranscriptIndex.resetCacheForTesting()

        let entries = CursorTranscriptIndex.entries(cliHome: cli, workspaceStorageRoot: wsRoot)
        try expectEqual(entries.count, 1)
        try expect(entries.first?.cwd == nil, "empty-window 不该有 cwd")

        var events: [(TaskEvent, Bool)] = []
        let tailer = CursorTranscriptTailer(
            cliHome: cli, workspaceStorageRoot: wsRoot, staleThreshold: 3600
        ) { events.append(($0, $1)) }
        tailer.scanOnce()                       // 首见
        try append([toolLine], to: url)
        tailer.scanOnce()                       // 增量（崩溃就发生在这一轮）
        try append([endLine], to: url)
        tailer.scanOnce()
        tailer.scanOnce()                       // 再空跑一轮，确认反复进 tail 也不炸
        try expect(
            events.contains { if case .taskFinished = $0.0.kind { return true } else { return false } },
            "无 cwd 也该正常走完整轮，实得 \(events.map(\.0.kind))")
        try expect(events.allSatisfy { $0.0.cwd == nil })
    }

    t.test("半行不消费，等下一轮补齐再发") {
        let (cli, wsRoot) = try makeHome()
        defer { try? FileManager.default.removeItem(at: cli.deletingLastPathComponent()) }
        let url = transcriptURL(cli: cli, composerId: "c1")
        try append([userLine, endLine], to: url)
        CursorWorkspaceIndex.resetCacheForTesting()
        CursorTranscriptIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = CursorTranscriptTailer(
            cliHome: cli, workspaceStorageRoot: wsRoot, staleThreshold: 3600
        ) { events.append(($0, $1)) }
        tailer.scanOnce()  // 建水位（已收尾 → 静默）

        // 写半行（无换行）
        let handle = try expectSome(FileHandle(forWritingAtPath: url.path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"role":"assistant","message":{"content":[{"type"#.utf8))
        try handle.close()
        events.removeAll()
        tailer.scanOnce()
        try expectEqual(events.count, 0, "半行不该被消费")

        // 补齐
        try append([#"":"text","text":"好"}]}}"#], to: url)
        tailer.scanOnce()
        try expect(!events.isEmpty, "补齐后应发出事件")
    }

    t.suite("Cursor 两通道归属 · 不重复出卡")

    t.test("回合开始时已有转录 → 库侧让出生命周期；中途才出现 → 库侧保留收尾") {
        // 让出：owned 从一开始就为真
        let a = try CursorFixture()
        defer { a.cleanUp() }
        try a.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try a.addComposer(id: "c1", workspaceId: "ws1", name: "会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()
        var yielded: [(TaskEvent, Bool)] = []
        let owning = CursorStateTailer(
            dbPath: a.stateDB, workspaceStorageRoot: a.workspaceStorage,
            staleThreshold: 3600, recentWindow: 365 * 86400,
            transcriptOwned: { _ in ["c1"] }
        ) { yielded.append(($0, $1)) }
        owning.scanOnce()
        try a.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "none",
            bubbles: [.user("走"), .tool("read_file", status: "loading")], contextPercent: 20)
        yielded.removeAll()
        owning.scanOnce()
        try expect(
            !yielded.contains { if case .taskStarted = $0.0.kind { return true }
                else { return false } },
            "有转录时库侧不该发 taskStarted，实得 \(yielded.map(\.0.kind))")
        try expect(
            yielded.contains { if case .contextUpdate = $0.0.kind { return true }
                else { return false } },
            "ctx% 只有库里有，必须照发，实得 \(yielded.map(\.0.kind))")
        try a.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.user("走"), .tool("read_file", status: "completed"), .assistant("好")])
        owning.scanOnce(); yielded.removeAll(); owning.scanOnce()
        try expect(
            !yielded.contains { if case .taskFinished = $0.0.kind { return true }
                else { return false } },
            "收尾该由转录侧的 turn_ended 负责，实得 \(yielded.map(\.0.kind))")

        // 保留：回合开始时没有转录，中途才出现（转录只在收尾落盘的情形）
        let b = try CursorFixture()
        defer { b.cleanUp() }
        try b.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try b.addComposer(id: "c2", workspaceId: "ws1", name: "会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()
        var appeared = false
        var kept: [(TaskEvent, Bool)] = []
        let keeping = CursorStateTailer(
            dbPath: b.stateDB, workspaceStorageRoot: b.workspaceStorage,
            staleThreshold: 3600, recentWindow: 365 * 86400,
            transcriptOwned: { _ in appeared ? ["c2"] : [] }
        ) { kept.append(($0, $1)) }
        keeping.scanOnce()
        try b.addComposer(
            id: "c2", workspaceId: "ws1", name: "会话", status: "none",
            bubbles: [.user("走")])
        keeping.scanOnce()  // 开始：此刻还没有转录 → 库侧接管整轮
        appeared = true     // 回合末尾转录文件才出现
        try b.addComposer(
            id: "c2", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.user("走"), .assistant("好")])
        keeping.scanOnce(); kept.removeAll(); keeping.scanOnce()
        try expect(
            kept.contains { if case .taskFinished = $0.0.kind { return true } else { return false } },
            "中途冒出来的转录不能把收尾抢走，否则卡片永远挂着，实得 \(kept.map(\.0.kind))")
    }
}

/// 断言可选值非空并解包（比 `x!` 有可读报错）
func expectSome<T>(_ value: T?, _ message: String = "期望非 nil") throws -> T {
    guard let value else { throw ExpectationError(description: message) }
    return value
}

// MARK: - 技能 / 规则（记忆）/ 子代理定义

/// 这三面的目录约定取自 Cursor 自带的内置技能（`~/.cursor/skills-cursor/create-skill`
/// `create-rule` `create-subagent`），是官方口径：
///   技能   ~/.cursor/skills/<名>/SKILL.md      与 <repo>/.cursor/skills/<名>/SKILL.md
///   内置   ~/.cursor/skills-cursor/            （官方分发，create-skill 明写不许往里写）
///   规则   <repo>/.cursor/rules/*.mdc          （带 YAML frontmatter，Cursor 的本地"记忆"）
///   子代理 ~/.cursor/agents/*.md               与 <repo>/.cursor/agents/*.md
private func cursorKnowledgeTests(_ t: TestRunner) {
    t.suite("Cursor 知识面 · 技能/规则/子代理")

    func makeHome() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cursor-know-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    t.test("用户技能 + 内置 skills-cursor（标 bundled）+ 项目技能都进索引") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("repo", isDirectory: true)
        try write("---\nname: mine\ndescription: 我的\n---\n",
            to: home.appendingPathComponent("skills/mine/SKILL.md"))
        try write("---\nname: review\ndescription: 官方内置\n---\n",
            to: home.appendingPathComponent("skills-cursor/review/SKILL.md"))
        try write("---\nname: proj\ndescription: 项目\n---\n",
            to: repo.appendingPathComponent(".cursor/skills/proj/SKILL.md"))

        let projectRoots = SkillMemoryIndexer.projectSkillRoots(repoRoots: [(repo, "repo")])
            .filter { $0.source == .cursor }
        try expectEqual(projectRoots.count, 1, "项目级技能根应包含 .cursor/skills")

        let skills = SkillMemoryIndexer.indexSkills(
            claudeSkillsRoot: home.appendingPathComponent("nope-claude"),
            codexSkillsRoot: home.appendingPathComponent("nope-codex"),
            cursorSkillsRoot: home.appendingPathComponent("skills"),
            projectSkillRoots: projectRoots,
            bundledRoots: [(home.appendingPathComponent("skills-cursor"), .cursor)]
        ).filter { $0.source == .cursor }

        try expectEqual(Set(skills.map(\.name)), ["mine", "review", "proj"])
        try expectEqual(
            skills.first { $0.name == "review" }?.origin, .bundled,
            "skills-cursor 是官方分发、不可写 → 必须标 bundled")
        try expect(
            skills.first { $0.name == "proj" }?.scope != .system,
            "项目技能不该算系统级")
    }

    t.test("项目级 .cursor/rules/*.mdc 收成 cursor 记忆，带项目名") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("repo", isDirectory: true)
        try write("---\ndescription: 命名规范\nglobs: src/**\n---\n\n# 命名\n",
            to: repo.appendingPathComponent(".cursor/rules/namings-rule.mdc"))
        try write("# 纯 md 也收\n", to: repo.appendingPathComponent(".cursor/rules/extra.md"))

        let memories = SkillMemoryIndexer.indexMemory(
            claudeHome: home.appendingPathComponent("nope"),
            codexHome: home.appendingPathComponent("nope"),
            opencodeHome: home.appendingPathComponent("nope"),
            claudeProjectsRoot: home.appendingPathComponent("nope"),
            projectRoots: [(repo, "repo")]
        ).filter { $0.source == .cursor }

        try expectEqual(Set(memories.map(\.scope)), ["namings-rule", "extra"],
            "实得 \(memories.map(\.scope))")
        try expectEqual(memories.first?.projectName, "repo")
    }

    t.test("子代理定义：~/.cursor/agents 与 <repo>/.cursor/agents 同构 Claude") {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let repo = home.appendingPathComponent("repo", isDirectory: true)
        try write("---\nname: reviewer\ndescription: 审代码\n---\n\n你是审阅者。\n",
            to: home.appendingPathComponent("agents/reviewer.md"))
        try write("---\nname: migrator\ndescription: 迁移\n---\n\n你负责迁移。\n",
            to: repo.appendingPathComponent(".cursor/agents/migrator.md"))

        let agents = AgentDefinitionIndexer.indexCursorAgents(
            systemRoot: home.appendingPathComponent("agents"),
            projectRoots: [ProjectScopedRoot(
                root: repo.appendingPathComponent(".cursor/agents"),
                source: .cursor, projectName: "repo")])
        try expectEqual(Set(agents.map(\.name)), ["reviewer", "migrator"])
        try expect(agents.allSatisfy { $0.source == .cursor })
        try expectEqual(agents.first { $0.name == "reviewer" }?.description, "审代码")
    }
}

// MARK: - PlanMaterializer（cursor：todos → markdown）

private func cursorPlanMaterializerTests(_ t: TestRunner) {
    t.suite("PlanMaterializer · Cursor 计划")

    t.test("composerData.todos 合成清单；四种状态各有框；无 todos 的会话不产文件") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c-plan", workspaceId: "ws1", name: "重构 Git 服务", status: "completed",
            bubbles: [.user("动手")],
            todos: [
                ("建工具类", "completed"),
                ("改调用方", "in_progress"),
                ("补测试", "pending"),
                ("顺带重命名", "cancelled"),
            ])
        try fixture.addComposer(
            id: "c-none", workspaceId: "ws1", name: "闲聊", status: "completed",
            bubbles: [.user("你好")])
        CursorWorkspaceIndex.resetCacheForTesting()

        let staging = fixture.root.appendingPathComponent("staging", isDirectory: true)
        let written = PlanMaterializer.materializeCursor(dbPath: fixture.stateDB, into: staging)
        try expectEqual(written, 1, "只有带 todos 的会话该产出计划")

        let file = staging.appendingPathComponent("cursor/c-plan.md")
        let text = try String(contentsOf: file, encoding: .utf8)
        try expect(text.hasPrefix("# 重构 Git 服务"), "标题应取会话名，实得 \(text.prefix(30))")
        try expect(text.contains("- [x] 建工具类"))
        try expect(text.contains("- [~] 改调用方"))
        try expect(text.contains("- [ ] 补测试"))
        try expect(text.contains("- [-] 顺带重命名"), "cancelled 要有独立的框，不能看着像没做")
        try expect(
            !FileManager.default.fileExists(
                atPath: staging.appendingPathComponent("cursor/c-none.md").path),
            "没有 todos 的会话不该产文件")

        // 内容没变就不重写（备份靠 mtime 判增量）
        try expectEqual(
            PlanMaterializer.materializeCursor(dbPath: fixture.stateDB, into: staging), 0,
            "内容不变时不该重写")
    }

    t.test("物化出来的计划能被 Plans 索引认成 cursor 来源") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c-plan", workspaceId: "ws1", name: "计划会话", status: "completed",
            todos: [("第一步", "completed")])
        CursorWorkspaceIndex.resetCacheForTesting()

        let staging = fixture.root.appendingPathComponent("staging", isDirectory: true)
        PlanMaterializer.materializeCursor(dbPath: fixture.stateDB, into: staging)
        let entries = PlanMaterializer.index(
            claudePlansDir: fixture.root.appendingPathComponent("no-claude"),
            stagingRoot: staging)
        try expectEqual(entries.count, 1)
        try expectEqual(entries.first?.source, .cursor)
    }
}

// MARK: - CursorPaths

private func cursorPathsTests(_ t: TestRunner) {
    t.suite("CursorPaths")

    t.test("home 优先级：EUREKA_CURSOR_HOME > ~/Library/Application Support/Cursor；派生路径") {
        try expectEqual(
            CursorPaths.configHome(environment: ["EUREKA_CURSOR_HOME": "/tmp/cur"]).path,
            "/tmp/cur")
        try expect(
            CursorPaths.configHome(environment: [:]).path
                .hasSuffix("/Library/Application Support/Cursor"))
        try expectEqual(
            CursorPaths.globalStateDB(environment: ["EUREKA_CURSOR_HOME": "/tmp/cur"]).path,
            "/tmp/cur/User/globalStorage/state.vscdb")
        try expectEqual(
            CursorPaths.workspaceStorageRoot(environment: ["EUREKA_CURSOR_HOME": "/tmp/cur"]).path,
            "/tmp/cur/User/workspaceStorage")
    }

    t.test("skills 走 ~/.cursor 而不是 Application Support（CLI 配置与 IDE 状态两处）") {
        try expectEqual(
            CursorPaths.skillsRoot(environment: ["EUREKA_CURSOR_CLI_HOME": "/tmp/dotcursor"]).path,
            "/tmp/dotcursor/skills")
        try expect(CursorPaths.skillsRoot(environment: [:]).path.hasSuffix("/.cursor/skills"))
        // IDE 状态目录换掉不应影响技能目录
        try expect(
            CursorPaths.skillsRoot(environment: ["EUREKA_CURSOR_HOME": "/tmp/cur"]).path
                .hasSuffix("/.cursor/skills"))
    }
}

// MARK: - CursorToolNames

private func cursorToolNamesTests(_ t: TestRunner) {
    t.suite("CursorToolNames · 工具名归一化")

    t.test("_v2 版本后缀剥掉；rg 归到 ripgrep_raw_search") {
        try expectEqual(CursorToolNames.canonical("read_file_v2"), "read_file")
        try expectEqual(CursorToolNames.canonical("run_terminal_command_v2"), "run_terminal_command")
        try expectEqual(CursorToolNames.canonical("edit_file_v2"), "edit_file")
        try expectEqual(CursorToolNames.canonical("read_file"), "read_file")
        try expectEqual(CursorToolNames.canonical("rg"), "ripgrep_raw_search")
        // 名字里本来就有 v 数字但不是后缀的别误伤
        try expectEqual(CursorToolNames.canonical("codebase_search"), "codebase_search")
    }

    t.test("MCP 是单下划线 mcp_<server>_<tool>（不是 Claude 的 mcp__）") {
        try expect(CursorToolNames.isMCP("mcp_dataworks-log-mcp_get_dag_instances_list"))
        try expect(!CursorToolNames.isMCP("read_file"))
        try expect(!CursorToolNames.isMCP("mcp_"))
        try expectEqual(
            CursorToolNames.mcpDisplayName("mcp_dataworks-log-mcp_get_dag_instances_list"),
            "dataworks-log-mcp.get_dag_instances_list")
        // 只有服务名没有工具名时退回服务名
        try expectEqual(CursorToolNames.mcpDisplayName("mcp_server"), "server")
        try expectEqual(CursorToolNames.usageKind("mcp_server_tool"), "mcp")
        try expectEqual(CursorToolNames.usageKind("read_file_v2"), "tool")
    }
}

// MARK: - CursorWorkspaceIndex

private func cursorWorkspaceIndexTests(_ t: TestRunner) {
    t.suite("CursorWorkspaceIndex · workspace 反查")

    t.test("workspace.json 的 folder URI 解析成 cwd；没有 folder 的窗口跳过") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addWorkspace(id: "empty-window", folder: nil)
        CursorWorkspaceIndex.resetCacheForTesting()

        let folders = CursorWorkspaceIndex.folders(root: fixture.workspaceStorage)
        try expectEqual(folders["ws1"], "/Users/me/work/alpha")
        try expect(folders["empty-window"] == nil, "无 folder 的窗口不应进反查表")
    }

    t.test("各 workspace 库的 allComposers 汇总成历史会话头，草稿剔除") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addWorkspaceComposers(id: "ws1", composers: [
            (composerId: "c-old", name: "历史会话", isDraft: false),
            (composerId: "c-draft", name: "草稿", isDraft: true),
        ])
        CursorWorkspaceIndex.resetCacheForTesting()

        let entries = CursorWorkspaceIndex.historicalComposers(root: fixture.workspaceStorage)
        try expectEqual(entries.count, 1, "草稿不应计入")
        try expectEqual(entries.first?.composerId, "c-old")
        try expectEqual(entries.first?.cwd, "/Users/me/work/alpha")
        try expectEqual(entries.first?.name, "历史会话")
    }
}

// MARK: - CursorStateTailer

private func cursorStateTailerTests(_ t: TestRunner) {
    t.suite("CursorStateTailer · 实时事件")

    t.test("首扫只建水位，不把历史会话重放成卡片") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "c1", workspaceId: "ws1", name: "旧会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()
        try expectEqual(events.count, 0, "首扫不得产出任何事件")
    }

    t.test("水位前进 → taskStarted，再进 → activity 带工具名，completed → taskFinished") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "c1", workspaceId: "ws1", name: "旧会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()  // 建水位

        // 一轮开始：新增用户气泡 + 生成中
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "在跑的会话", status: "none",
            bubbles: [.user("改一下 README")], generating: true, contextPercent: 12.5)
        events.removeAll()
        tailer.scanOnce()
        try expect(
            events.contains { if case .taskStarted(let title) = $0.0.kind {
                return title == "在跑的会话"
            } else { return false } },
            "水位前进应出 taskStarted，实得 \(events.map(\.0.kind))")
        try expect(
            events.contains { if case .contextUpdate(let percent) = $0.0.kind {
                return abs(percent - 12.5) < 0.01
            } else { return false } },
            "应带 contextUsagePercent")
        try expectEqual(events.first?.0.cwd, "/Users/me/work/alpha")
        try expectEqual(events.first?.0.source, .cursor)
        try expectEqual(events.first?.0.sessionId, "c1")

        // 跑工具：再进一格
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "在跑的会话", status: "none",
            bubbles: [.user("改一下 README"), .tool("read_file_v2", status: "loading")],
            generating: true, contextPercent: 12.5)
        events.removeAll()
        tailer.scanOnce()
        try expect(
            events.contains { if case .activity(let tool) = $0.0.kind {
                return tool == "read_file"   // _v2 后缀应已归一化
            } else { return false } },
            "应出 activity(read_file)，实得 \(events.map(\.0.kind))")

        // 收尾
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "在跑的会话", status: "completed",
            bubbles: [.user("改一下 README"), .tool("read_file_v2", status: "completed"),
                      .assistant("改好了")],
            generating: false, contextPercent: 13.0)
        events.removeAll()
        tailer.scanOnce()
        try expect(
            events.isEmpty,
            "收口要等一轮确认，这一轮不该出收尾卡，实得 \(events.map(\.0.kind))")
        tailer.scanOnce()  // 状态仍是 completed 且水位不再推进 → 落定
        try expect(
            events.contains { if case .taskFinished(let outcome, let title, _) = $0.0.kind {
                return outcome == .success && title == "在跑的会话"
            } else { return false } },
            "应出 taskFinished(.success)，实得 \(events.map(\.0.kind))")
    }

    t.test("一轮里 aborted 先落、completed 后落 → 收尾按最终状态记成功（实勘行为）") {
        // 实勘：同一个 composer 在 2s 内先写 status=aborted 再写 completed。
        // 当场收尾会把成功的一轮记成中断，故收口要等一轮确认。
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "c1", workspaceId: "ws1", name: "会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()

        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "none",
            bubbles: [.user("跑一下")], generating: false)
        tailer.scanOnce()  // 进入 live

        // 中途瞬时写成 aborted（水位同时又进了一格）
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "aborted",
            bubbles: [.user("跑一下"), .tool("read_file", status: "completed")])
        events.removeAll()
        tailer.scanOnce()
        try expect(
            !events.contains { if case .taskFinished = $0.0.kind { return true }
                else { return false } },
            "瞬时 aborted 不该当场收尾，实得 \(events.map(\.0.kind))")

        // 最终写成 completed
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.user("跑一下"), .tool("read_file", status: "completed"), .assistant("好了")])
        tailer.scanOnce()  // 看到 completed，记为待定
        events.removeAll()
        tailer.scanOnce()  // 状态不变且水位不动 → 落定
        try expect(
            events.contains { if case .taskFinished(let outcome, _, _) = $0.0.kind {
                return outcome == .success
            } else { return false } },
            "应按最终状态记成 success，实得 \(events.map(\.0.kind))")
    }

    t.test("整轮跑完都没被轮询逮到 → 补一张开始卡，历史不丢这一轮") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "c1", workspaceId: "ws1", name: "会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()

        // 一次轮询之间：从无到有跑完整轮（水位前进 + 直接 completed）
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.user("快问快答"), .assistant("答完了")])
        tailer.scanOnce()  // 待定
        events.removeAll()
        tailer.scanOnce()  // 落定
        try expect(
            events.contains { if case .taskStarted = $0.0.kind { return true }
                else { return false } },
            "应补一张开始卡，实得 \(events.map(\.0.kind))")
        try expect(
            events.contains { if case .taskFinished = $0.0.kind { return true }
                else { return false } },
            "应出收尾卡，实得 \(events.map(\.0.kind))")
    }

    t.test("aborted 收成 interrupted；hasBlockingPendingActions 出等待授权卡") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "c1", workspaceId: "ws1", name: "会话", status: "completed")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()

        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "none",
            bubbles: [.user("跑个命令"), .tool("run_terminal_cmd", status: "loading")],
            generating: true, blocking: true)
        events.removeAll()
        tailer.scanOnce()
        try expect(
            events.contains { if case .waiting(let reason, _) = $0.0.kind {
                return reason == .permission
            } else { return false } },
            "hasBlockingPendingActions 应出 waiting(.permission)，实得 \(events.map(\.0.kind))")

        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "aborted",
            bubbles: [.user("跑个命令"), .tool("run_terminal_cmd", status: "cancelled")],
            generating: false)
        tailer.scanOnce()  // 待定
        events.removeAll()
        tailer.scanOnce()  // 状态仍是 aborted 且水位不动 → 落定
        try expect(
            events.contains { if case .taskFinished(let outcome, _, _) = $0.0.kind {
                return outcome == .interrupted
            } else { return false } },
            "aborted 应收成 interrupted，实得 \(events.map(\.0.kind))")
    }

    t.test("草稿与子会话不占岛上的位置（子会话靠 subagentInfo 判定，不是 isSubagent 列）") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "keep", workspaceId: "ws1", name: "正经会话", status: "completed")
        try fixture.addComposer(id: "draft", workspaceId: "ws1", name: "草稿", status: "none",
            isDraft: true)
        try fixture.addComposer(id: "child", workspaceId: "ws1", name: "子会话", status: "none",
            parentComposerId: "keep")
        CursorWorkspaceIndex.resetCacheForTesting()

        var events: [(TaskEvent, Bool)] = []
        let tailer = fixture.makeTailer { events.append(($0, $1)) }
        tailer.scanOnce()

        // 三个会话都推进一格，只有正经会话该出卡
        try fixture.addComposer(
            id: "keep", workspaceId: "ws1", name: "正经会话", status: "none",
            bubbles: [.user("一")], generating: true)
        try fixture.addComposer(
            id: "draft", workspaceId: "ws1", name: "草稿", status: "none",
            bubbles: [.user("二")], generating: true, isDraft: true)
        try fixture.addComposer(
            id: "child", workspaceId: "ws1", name: "子会话", status: "none",
            bubbles: [.user("三")], generating: true, parentComposerId: "keep")
        events.removeAll()
        tailer.scanOnce()
        let ids = Set(events.map(\.0.sessionId))
        try expectEqual(ids, ["keep"], "只有顶层非草稿会话该出事件，实得 \(ids)")
    }
}

// MARK: - CursorSessionIndexer

private func cursorSessionIndexerTests(_ t: TestRunner) {
    t.suite("CursorSessionIndexer · 会话索引")

    t.test("composerData 前缀扫描出会话；cwd 经 workspace 反查；共享库 → sizeBytes 0") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "带标题的会话", status: "completed",
            bubbles: [.user("你好")])
        CursorWorkspaceIndex.resetCacheForTesting()

        let sessions = fixture.index()
        try expectEqual(sessions.count, 1)
        let session = try expectFirst(sessions)
        try expectEqual(session.source, .cursor)
        try expectEqual(session.id, "c1")
        try expectEqual(session.name, "带标题的会话")
        try expectEqual(session.cwd, "/Users/me/work/alpha")
        try expectEqual(session.sizeBytes, 0)
        try expectEqual(session.transcriptPath, fixture.stateDB.path)
    }

    t.test("草稿与 Best-of-N 子会话不入列；掉出时间窗的会话不入列") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(id: "keep", workspaceId: "ws1", name: "留", status: "completed")
        try fixture.addComposer(id: "draft", workspaceId: "ws1", name: "草稿", status: "none",
            isDraft: true)
        try fixture.addComposer(id: "bon", workspaceId: "ws1", name: "变体", status: "none",
            isBestOfNSubcomposer: true)
        try fixture.addComposer(
            id: "ancient", workspaceId: "ws1", name: "太老", status: "completed",
            updatedAt: Date().addingTimeInterval(-400 * 86400))
        CursorWorkspaceIndex.resetCacheForTesting()

        let ids = Set(fixture.index().map(\.id))
        try expectEqual(ids, ["keep"], "实得 \(ids)")
    }

    t.test("会话详情从库里拼消息：user/assistant 正文 + 🔧 工具小注") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.user("读一下 README"), .tool("read_file_v2", status: "completed"),
                      .assistant("读完了")])
        CursorWorkspaceIndex.resetCacheForTesting()

        let session = try expectFirst(fixture.index())
        let result = TranscriptReader.load(session: session)
        try expectEqual(result.messages.count, 3)
        try expectEqual(result.messages[0].role, .user)
        try expectEqual(result.messages[0].text, "读一下 README")
        try expectEqual(result.messages[1].role, .toolNote)
        try expectEqual(result.messages[1].text, "🔧 read_file")
        try expectEqual(result.messages[2].role, .assistant)
        try expectEqual(result.messages[2].text, "读完了")
    }
}

// MARK: - CursorUsageScanner

private func cursorUsageScannerTests(_ t: TestRunner) {
    t.suite("CursorUsageScanner · 用量")

    t.test("相邻差分归缓存：新鲜输入之和 = 最终上下文；重扫幂等") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        // 实勘形态：inputTokens 逐轮单调递增（整个上下文重发）
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [
                .user("一"),
                .assistant("答一", input: 50_000, output: 800, model: "claude-4.5-opus-high"),
                .user("二"),
                .assistant("答二", input: 59_000, output: 500, model: "claude-4.5-opus-high"),
            ])
        CursorWorkspaceIndex.resetCacheForTesting()

        let store = try EurekaStore(path: fixture.root.appendingPathComponent("eureka.sqlite"))
        let scanner = fixture.makeUsageScanner(store: store)
        try expectEqual(try scanner.scanOnce(), 2)

        let rows = (try store.usage.totalsForSessions(["c1"]))["c1"] ?? []
        let input = rows.reduce(0) { $0 + $1.inputTokens }
        let cacheRead = rows.reduce(0) { $0 + $1.cacheReadTokens }
        let output = rows.reduce(0) { $0 + $1.outputTokens }
        try expectEqual(input, 59_000, "新鲜输入之和应等于最终上下文，而不是 109000")
        try expectEqual(cacheRead, 50_000, "第二轮的 50000 应归到缓存读")
        try expectEqual(output, 1_300)

        try expectEqual(try scanner.scanOnce(), 0, "重扫应幂等")
    }

    t.test("上下文变小 = 压缩重置，整份算新鲜输入；模型名带 cursor/ 前缀") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [
                .assistant("答一", input: 80_000, output: 100, model: "gpt-5.1-codex"),
                .assistant("答二", input: 9_000, output: 100, model: nil),  // 压缩后
            ])
        CursorWorkspaceIndex.resetCacheForTesting()

        let store = try EurekaStore(path: fixture.root.appendingPathComponent("eureka.sqlite"))
        try expectEqual(try fixture.makeUsageScanner(store: store).scanOnce(), 2)
        let rows = (try store.usage.totalsForSessions(["c1"]))["c1"] ?? []
        try expectEqual(rows.reduce(0) { $0 + $1.inputTokens }, 89_000)
        try expectEqual(rows.reduce(0) { $0 + $1.cacheReadTokens }, 0)
        try expect(
            rows.allSatisfy { $0.model.hasPrefix("cursor/") },
            "模型名应统一带 cursor/ 前缀（pricing 里按该前缀标 unknown），实得 \(rows.map(\.model))")
        // 没有 modelInfo 的那轮退回 composerData.modelConfig.modelName
        try expect(rows.contains { $0.model == "cursor/gpt-5.1-codex" })
        try expect(rows.contains { $0.model == "cursor/default" })
    }
}

// MARK: - CursorAuditScanner

private func cursorAuditScannerTests(_ t: TestRunner) {
    t.suite("CursorAuditScanner · 工具轨迹")

    t.test("库指纹门控：没变化就跳过，主库或 WAL 一动就必须重扫") {
        // 这条门控是应用 CPU 的关键：审计是 2 秒节奏，而每轮要打开一个 250 MB 的库
        // 再全量索引会话（sample 抓到它是头号热点）。但它一旦失效就是**静默丢审计**，
        // 所以「变化后必须重扫」这半边比「没变就跳过」更要钉住。
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [.tool("run_terminal_cmd", status: "completed",
                            rawArgs: #"{"command":"echo one"}"#)])
        CursorWorkspaceIndex.resetCacheForTesting()

        let store = try EurekaStore(path: fixture.root.appendingPathComponent("eureka.sqlite"))
        let scanner = fixture.makeAuditScanner(store: store)
        try expectEqual(try scanner.scanOnce(), 1)
        // 库没动 → 门控生效，直接 0（这一轮连库都不该打开）
        try expectEqual(try scanner.scanOnce(), 0)

        // 主库变了（新增一个会话）→ 必须重扫并采到新行
        try fixture.addComposer(
            id: "c2", workspaceId: "ws1", name: "会话二", status: "completed",
            bubbles: [.tool("read_file_v2", status: "completed",
                            rawArgs: #"{"target_file":"README.md"}"#)])
        CursorWorkspaceIndex.resetCacheForTesting()
        try expectEqual(try scanner.scanOnce(), 1, "主库变化后必须重扫，否则静默丢审计")
        try expectEqual(try scanner.scanOnce(), 0)

        // WAL 那半边（新写入落在 `-wal`、主库 size/mtime 都不动）在单测里造不出来 ——
        // 普通 SQLite 写入会直接改主库，而"跳过"与"扫了但无新数据"都返回 0，无法区分。
        // 那一半靠 `fingerprint` 把 `-wal` 纳入判据来保证，别在这里写假断言。
    }

    t.test("toolFormerData 落成审计流水，参数按 Cursor 词表提取；重扫幂等") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [
                .tool("run_terminal_cmd", status: "completed",
                      rawArgs: #"{"command":"ls -la /tmp"}"#),
                .tool("read_file_v2", status: "completed",
                      rawArgs: #"{"target_file":"README.md"}"#),
                .tool("mcp_demo-server_do_thing", status: "completed",
                      rawArgs: #"{"query":"hi"}"#),
            ])
        CursorWorkspaceIndex.resetCacheForTesting()

        let store = try EurekaStore(path: fixture.root.appendingPathComponent("eureka.sqlite"))
        let scanner = fixture.makeAuditScanner(store: store)
        try expectEqual(try scanner.scanOnce(), 3)

        let rows = try store.audit.recent(limit: 50)
            .filter { $0.source == .cursor }
        try expectEqual(rows.count, 3)
        let byTool = Dictionary(uniqueKeysWithValues: rows.map { ($0.tool, $0) })
        try expectEqual(byTool["run_terminal_cmd"]?.kind, .command)
        try expectEqual(byTool["run_terminal_cmd"]?.detail, "ls -la /tmp")
        try expectEqual(byTool["read_file"]?.kind, .read)
        try expectEqual(byTool["read_file"]?.detail, "README.md")
        try expectEqual(byTool["demo-server.do_thing"]?.kind, .mcp)
        try expectEqual(rows.first?.cwd, "/Users/me/work/alpha")

        try expectEqual(try scanner.scanOnce(), 0, "重扫应幂等")
    }

    t.test("apply_patch 的 rawArgs 是裸补丁文本（非 JSON）→ 走 params 取路径") {
        let fixture = try CursorFixture()
        defer { fixture.cleanUp() }
        try fixture.addWorkspace(id: "ws1", folder: "/Users/me/work/alpha")
        try fixture.addComposer(
            id: "c1", workspaceId: "ws1", name: "会话", status: "completed",
            bubbles: [
                .tool("apply_patch", status: "completed",
                      rawArgs: "*** Begin Patch\n*** Update File: src/main.swift\n",
                      params: #"{"relativeWorkspacePath":"src/main.swift"}"#),
            ])
        CursorWorkspaceIndex.resetCacheForTesting()

        let store = try EurekaStore(path: fixture.root.appendingPathComponent("eureka.sqlite"))
        try expectEqual(try fixture.makeAuditScanner(store: store).scanOnce(), 1)
        let row = try expectFirst(try store.audit.recent(limit: 10).filter { $0.source == .cursor })
        try expectEqual(row.tool, "apply_patch")
        try expectEqual(row.kind, .edit)
        try expectEqual(row.detail, "src/main.swift")
    }
}

// MARK: - fixture：现造一个 Cursor 形状的 state.vscdb

/// 按真实库结构建表：`cursorDiskKV(key,value)` + `composerHeaders(...)`，
/// 外加 `workspaceStorage/<id>/{workspace.json,state.vscdb}`。
final class CursorFixture {
    /// 一条气泡的最小描述（真实库里字段几十个，测试只造用得上的那几个）
    struct Bubble {
        var role: Int  // 1 = user，2 = assistant（工具气泡也在 assistant 侧）
        var text: String = ""
        var input: Int = 0
        var output: Int = 0
        var model: String?
        var toolName: String?
        var toolStatus: String?
        var rawArgs: String?
        var params: String?

        static func user(_ text: String) -> Bubble { Bubble(role: 1, text: text) }

        static func assistant(
            _ text: String, input: Int = 0, output: Int = 0, model: String? = nil
        ) -> Bubble {
            Bubble(role: 2, text: text, input: input, output: output, model: model)
        }

        static func tool(
            _ name: String, status: String, rawArgs: String? = nil, params: String? = nil
        ) -> Bubble {
            Bubble(role: 2, toolName: name, toolStatus: status, rawArgs: rawArgs, params: params)
        }

        /// 拼成真实库里那一行的 JSON。用 JSONSerialization 而不是手写字符串：
        /// rawArgs 里带引号和换行（apply_patch 是裸补丁文本），手写转义必踩坑。
        func json(createdAt: String) -> String {
            var root: [String: Any] = [
                "type": role, "createdAt": createdAt, "text": text,
                "tokenCount": ["inputTokens": input, "outputTokens": output],
            ]
            if let model { root["modelInfo"] = ["modelName": model] }
            if let toolName {
                var tool: [String: Any] = ["name": toolName, "toolIndex": 0]
                if let toolStatus { tool["status"] = toolStatus }
                if let rawArgs { tool["rawArgs"] = rawArgs }
                if let params,
                    let parsed = try? JSONSerialization.jsonObject(with: Data(params.utf8)) {
                    tool["params"] = parsed
                }
                root["toolFormerData"] = tool
            }
            let data = (try? JSONSerialization.data(withJSONObject: root)) ?? Data("{}".utf8)
            return String(data: data, encoding: .utf8) ?? "{}"
        }
    }

    let root: URL
    let stateDB: URL
    let workspaceStorage: URL

    /// `root` 传 nil 则自建临时目录（本文件用）；ProjectRootsTests 复用时传它自己的 base
    init(root: URL? = nil) throws {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-cursor-\(UUID().uuidString)", isDirectory: true)
        let root = self.root
        stateDB = root.appendingPathComponent("User/globalStorage/state.vscdb")
        workspaceStorage = root.appendingPathComponent("User/workspaceStorage", isDirectory: true)
        try FileManager.default.createDirectory(
            at: stateDB.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: workspaceStorage, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: stateDB.path)
        try db.execute("CREATE TABLE cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)")
        try db.execute("""
            CREATE TABLE composerHeaders (
                composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER,
                lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER,
                recency INTEGER, checkpointAt INTEGER, value TEXT)
            """)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
        CursorWorkspaceIndex.resetCacheForTesting()
    }

    func addWorkspace(id: String, folder: String?) throws {
        let dir = workspaceStorage.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = folder.map { #"{"folder":"file://\#($0)"}"# } ?? "{}"
        try Data(json.utf8).write(to: dir.appendingPathComponent("workspace.json"))
    }

    func addWorkspaceComposers(
        id: String, composers: [(composerId: String, name: String, isDraft: Bool)]
    ) throws {
        let dir = workspaceStorage.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: dir.appendingPathComponent("state.vscdb").path)
        try db.execute("CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE, value BLOB)")
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let all = composers.map {
            #"{"composerId":"\#($0.composerId)","name":"\#($0.name)","isDraft":\#($0.isDraft),"#
                + #""createdAt":\#(now - 1000),"lastUpdatedAt":\#(now)}"#
        }.joined(separator: ",")
        try db.run(
            "INSERT OR REPLACE INTO ItemTable (key, value) VALUES ('composer.composerData', ?)",
            [.text(#"{"allComposers":[\#(all)]}"#)])
    }

    /// 写 / 覆写一个 composer（header + composerData + 各 bubble 行）
    func addComposer(
        id: String,
        workspaceId: String,
        name: String,
        status: String,
        bubbles: [Bubble] = [],
        generating: Bool = false,
        contextPercent: Double? = nil,
        blocking: Bool = false,
        isDraft: Bool = false,
        isBestOfNSubcomposer: Bool = false,
        parentComposerId: String? = nil,
        todos: [(String, String)] = [],
        updatedAt: Date = Date()
    ) throws {
        let db = try SQLiteDB(path: stateDB.path)
        let updatedMs = Int64(updatedAt.timeIntervalSince1970 * 1000)
        let createdMs = updatedMs - 60_000
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var bubbleHeaders: [String] = []
        for (index, bubble) in bubbles.enumerated() {
            let bubbleId = "b\(index)"
            bubbleHeaders.append(#"{"bubbleId":"\#(bubbleId)","type":\#(bubble.role)}"#)
            let created = iso.string(from: updatedAt.addingTimeInterval(Double(index) - 30))
            try db.run(
                "INSERT OR REPLACE INTO cursorDiskKV (key, value) VALUES (?, ?)",
                [.text("bubbleId:\(id):\(bubbleId)"), .text(bubble.json(createdAt: created))])
        }

        let todosJSON = todos.isEmpty ? "[]" : "[" + todos.enumerated().map { index, todo in
            #"{"id":"\#(index)","content":"\#(todo.0)","status":"\#(todo.1)","dependencies":[]}"#
        }.joined(separator: ",") + "]"
        let generatingIds = generating ? #"["gen-1"]"# : "[]"
        let contextField = contextPercent.map { #""contextUsagePercent":\#($0),"# } ?? ""
        let composerData = """
            {"composerId":"\(id)","name":"\(name)","status":"\(status)",\
            \(contextField)"contextTokensUsed":\(bubbles.count * 100),\
            "generatingBubbleIds":\(generatingIds),\
            "fullConversationHeadersOnly":[\(bubbleHeaders.joined(separator: ","))],\
            "modelConfig":{"modelName":"default","maxMode":false},"todos":\(todosJSON),\
            "isDraft":\(isDraft),"isBestOfNSubcomposer":\(isBestOfNSubcomposer),\
            "createdAt":\(createdMs),"lastUpdatedAt":\(updatedMs)}
            """
        try db.run(
            "INSERT OR REPLACE INTO cursorDiskKV (key, value) VALUES (?, ?)",
            [.text("composerData:\(id)"), .text(composerData)])

        let subagentField = parentComposerId
            .map { #""subagentInfo":{"parentComposerId":"\#($0)","conversationLengthAtSpawn":0},"# }
            ?? ""
        let header = """
            {"composerId":"\(id)","name":"\(name)",\(subagentField)\
            \(contextField)"hasBlockingPendingActions":\(blocking),\
            "isDraft":\(isDraft),"isArchived":false,\
            "createdAt":\(createdMs),"lastUpdatedAt":\(updatedMs)}
            """
        try db.run("""
            INSERT OR REPLACE INTO composerHeaders
            (composerId, workspaceId, createdAt, lastUpdatedAt, isArchived, isSubagent,
             recency, checkpointAt, value)
            VALUES (?,?,?,?,0,0,?,NULL,?)
            """, [
                .text(id), .text(workspaceId), .int(createdMs), .int(updatedMs),
                .int(updatedMs), .text(header),
            ])
    }

    func makeTailer(handler: @escaping (TaskEvent, Bool) -> Void) -> CursorStateTailer {
        CursorStateTailer(
            dbPath: stateDB, workspaceStorageRoot: workspaceStorage,
            // 时间窗放宽：fixture 的 recency 就是"现在"，但测试机可能跑得慢
            staleThreshold: 3600, recentWindow: 365 * 86400, handler: handler)
    }

    func index(now: Date = Date()) -> [AgentSessionInfo] {
        CursorSessionIndexer.index(
            dbPath: stateDB, workspaceStorageRoot: workspaceStorage, now: now)
    }

    func makeUsageScanner(store: EurekaStore) -> CursorUsageScanner {
        CursorUsageScanner(
            dbPath: stateDB, store: store, workspaceStorageRoot: workspaceStorage,
            sessions: { [self] now in index(now: now).map { ($0.id, $0.cwd, $0.lastActiveAt) } })
    }

    func makeAuditScanner(store: EurekaStore) -> CursorAuditScanner {
        CursorAuditScanner(
            dbPath: stateDB, workspaceStorageRoot: workspaceStorage,
            store: store, pipeline: AuditPipeline(store: store))
    }
}

/// 取首个元素，空数组直接失败（比 `xs.first!` 有可读的报错）
func expectFirst<T>(_ values: [T], _ message: String = "期望非空数组") throws -> T {
    try expect(!values.isEmpty, message)
    return values[0]
}
