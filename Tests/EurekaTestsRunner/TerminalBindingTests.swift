import EurekaIngest
import EurekaKit
import EurekaStore
import Foundation

func terminalBindingTests(_ t: TestRunner) {
    t.suite("终端归属 · 模型/信封/仓库")

    func tempStorePath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("eureka-terminal-\(UUID()).sqlite")
    }

    // MARK: - 展示名

    t.test("展示名：已收录 bundle id 翻正式名，未收录退到 TERM_PROGRAM") {
        try expectEqual(
            TerminalBinding(app: "iTerm.app", bundleId: "com.googlecode.iterm2",
                            tty: "/dev/ttys004").displayName,
            "iTerm2 · ttys004")
        // Apple_Terminal 这个原值不好看，要翻成 Terminal
        try expectEqual(
            TerminalBinding(app: "Apple_Terminal", bundleId: "com.apple.Terminal",
                            tty: "/dev/ttys012").displayName,
            "Terminal · ttys012")
        // 未收录的 bundle id：有 TERM_PROGRAM 就用它（去掉 .app 后缀）
        try expectEqual(
            TerminalBinding(app: "Foo.app", bundleId: "com.example.foo").terminalName, "Foo")
        // 连 TERM_PROGRAM 都没有 → 取 bundle id 末段，总比整串好看
        try expectEqual(
            TerminalBinding(bundleId: "com.example.weird").terminalName, "weird")
        // tmux 会话额外标出 pane
        try expectEqual(
            TerminalBinding(app: "iTerm.app", bundleId: "com.googlecode.iterm2",
                            tty: "/dev/ttys004", tmuxPane: "%3").displayName,
            "iTerm2 · ttys004 · tmux %3")
    }

    t.test("空绑定可识别（调用方据此不落库）") {
        try expect(TerminalBinding().isEmpty)
        try expect(!TerminalBinding(tty: "/dev/ttys001").isEmpty)
        // 只有 tty 时没有终端名可言，但不该显示成空白
        try expectEqual(TerminalBinding(tty: "/dev/ttys001").displayName, "终端 · ttys001")
    }

    // MARK: - 信封解码

    t.test("信封：terminal 是顶层字段，缺失/全空都解成 nil（向后兼容旧 relay）") {
        func envelope(_ extra: String) -> Data {
            Data("""
            {"v":1,"channel":"claude-hook","receivedAtMs":1700000000000\(extra),
             "payload":{"hook_event_name":"Stop","session_id":"s1"}}
            """.utf8)
        }
        // 旧版 relay 写的文件没有 terminal 键 → nil，且事件本身照常解出
        let old = try require(RawEvent(data: envelope("")))
        try expect(old.terminal == nil, "缺 terminal 键应为 nil")
        try expectEqual(old.channel, "claude-hook")

        let full = try require(RawEvent(data: envelope(
            ",\"terminal\":{\"app\":\"iTerm.app\",\"bundleId\":\"com.googlecode.iterm2\","
                + "\"tty\":\"/dev/ttys004\",\"tmuxPane\":\"%1\"}")))
        let binding = try require(full.terminal)
        try expectEqual(binding.app, "iTerm.app")
        try expectEqual(binding.bundleId, "com.googlecode.iterm2")
        try expectEqual(binding.tty, "/dev/ttys004")
        try expectEqual(binding.tmuxPane, "%1")
        try expectEqual(binding.origin, .hook, "信封来的一律算 hook 精度")

        // 空对象 / 空串值 → 视作没采到，不该产出一个空绑定
        let emptyObject = try require(RawEvent(data: envelope(",\"terminal\":{}")))
        try expect(emptyObject.terminal == nil, "空对象应被当作未采到")
        let emptyValue = try require(RawEvent(data: envelope(",\"terminal\":{\"app\":\"\"}")))
        try expect(emptyValue.terminal == nil, "空串值应被当作未采到")
    }

    t.test("路由：终端绑定贴到解码出的事件上（两个 channel 都覆盖）") {
        let raw = try require(RawEvent(data: Data("""
        {"v":1,"channel":"claude-hook","receivedAtMs":1700000000000,
         "terminal":{"app":"Apple_Terminal","bundleId":"com.apple.Terminal"},
         "payload":{"hook_event_name":"UserPromptSubmit","session_id":"s1","prompt":"做点事"}}
        """.utf8)))
        let events = EventRouter.route(raw)
        try expectEqual(events.count, 1)
        try expectEqual(try require(events[0].terminal).bundleId, "com.apple.Terminal")
    }

    // MARK: - 仓库

    t.test("仓库：同会话换终端 resume → 两条绑定，最近的在前") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let iterm = TerminalBinding(
            app: "iTerm.app", bundleId: "com.googlecode.iterm2", tty: "/dev/ttys004")
        let terminal = TerminalBinding(
            app: "Apple_Terminal", bundleId: "com.apple.Terminal", tty: "/dev/ttys009")

        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1", binding: iterm,
            at: Date(timeIntervalSince1970: 1000))
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1", binding: terminal,
            at: Date(timeIntervalSince1970: 2000))

        let all = try store.sessionTerminals.bindings(source: .claude, sessionId: "s1")
        try expectEqual(all.count, 2, "换终端应各留一条，而不是覆盖")
        try expectEqual(all[0].binding.bundleId, "com.apple.Terminal", "最近活跃在前")
        try expectEqual(try require(store.sessionTerminals.latest(
            source: .claude, sessionId: "s1")).bundleId, "com.apple.Terminal")
    }

    t.test("仓库：同终端重复事件只推进 last_seen，不长表") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let binding = TerminalBinding(
            app: "iTerm.app", bundleId: "com.googlecode.iterm2", tty: "/dev/ttys004")
        for second in [1000.0, 1500.0, 2000.0] {
            try store.sessionTerminals.record(
                source: .claude, sessionId: "s1", binding: binding,
                at: Date(timeIntervalSince1970: second))
        }
        let rows = try store.sessionTerminals.bindings(source: .claude, sessionId: "s1")
        try expectEqual(rows.count, 1, "同键必须 upsert")
        try expectEqual(rows[0].firstSeen.timeIntervalSince1970, 1000, "first_seen 保持首次")
        try expectEqual(rows[0].lastSeen.timeIntervalSince1970, 2000, "last_seen 推进到最新")
    }

    t.test("仓库：只有 bundleId（无 tty / 无 TERM_PROGRAM）时同样 upsert 而非攒重复行") {
        // 实测踩过的真实形态：Claude Code 跑在 IDE 里时既没有 TERM_PROGRAM 也没有控制终端，
        // 只剩 __CFBundleIdentifier。可空列进主键会让 SQLite 的 upsert 永不命中
        // （NULL != NULL），同一会话瞬间攒出十几条重复行。
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let idePseudoTerminal = TerminalBinding(bundleId: "com.jetbrains.intellij-EAP")
        for second in stride(from: 1000.0, through: 1500.0, by: 100.0) {
            try store.sessionTerminals.record(
                source: .claude, sessionId: "s1", binding: idePseudoTerminal,
                at: Date(timeIntervalSince1970: second))
        }
        let rows = try store.sessionTerminals.bindings(source: .claude, sessionId: "s1")
        try expectEqual(rows.count, 1, "缺 tty 时也必须 upsert，不能每个事件插一行")
        try expectEqual(rows[0].lastSeen.timeIntervalSince1970, 1500)
        // 空串不该被当成有值漏出到 UI
        try expect(rows[0].binding.tty == nil, "存盘的空串要还原成 nil")
        try expect(rows[0].binding.app == nil)
        try expectEqual(rows[0].binding.displayName, "IntelliJ IDEA")
    }

    t.test("仓库：完全没有 bundleId 也只有 tty 的形态同样 upsert") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let onlyTTY = TerminalBinding(tty: "/dev/ttys004")
        for second in [1000.0, 2000.0] {
            try store.sessionTerminals.record(
                source: .codex, sessionId: "s2", binding: onlyTTY,
                at: Date(timeIntervalSince1970: second))
        }
        try expectEqual(
            try store.sessionTerminals.bindings(source: .codex, sessionId: "s2").count, 1)
    }

    t.test("仓库：hook 精度不会被后来的 probe 降级") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        let key = (app: "iTerm.app", bundle: "com.googlecode.iterm2", tty: "/dev/ttys004")
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1",
            binding: TerminalBinding(app: key.app, bundleId: key.bundle, tty: key.tty,
                                     origin: .hook),
            at: Date(timeIntervalSince1970: 1000))
        // 之后探测又报了一次同一个终端 —— 不该把 origin 写回 probe
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1",
            binding: TerminalBinding(app: key.app, bundleId: key.bundle, tty: key.tty,
                                     origin: .probe),
            at: Date(timeIntervalSince1970: 2000))
        let rows = try store.sessionTerminals.bindings(source: .claude, sessionId: "s1")
        try expectEqual(rows.count, 1)
        try expectEqual(rows[0].binding.origin, .hook, "已被精确采过就不许降级")
    }

    t.test("仓库：批量取每会话最近绑定（列表页一次查完）") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1",
            binding: TerminalBinding(bundleId: "com.googlecode.iterm2", tty: "/dev/ttys001"),
            at: Date(timeIntervalSince1970: 1000))
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1",
            binding: TerminalBinding(bundleId: "com.apple.Terminal", tty: "/dev/ttys002"),
            at: Date(timeIntervalSince1970: 3000))
        try store.sessionTerminals.record(
            source: .codex, sessionId: "s2",
            binding: TerminalBinding(bundleId: "com.mitchellh.ghostty", tty: "/dev/ttys003"),
            at: Date(timeIntervalSince1970: 2000))

        let map = try store.sessionTerminals.latestBySession()
        try expectEqual(map.count, 2, "两个会话各一条")
        try expectEqual(
            try require(map[AgentTask.key(source: .claude, sessionId: "s1")]).bundleId,
            "com.apple.Terminal", "多绑定会话应取 last_seen 最大的那条")
        try expectEqual(
            try require(map[AgentTask.key(source: .codex, sessionId: "s2")]).bundleId,
            "com.mitchellh.ghostty")
        // 按源过滤
        try expectEqual(try store.sessionTerminals.latestBySession(source: .codex).count, 1)
    }

    t.test("空绑定不落库") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try EurekaStore(path: path)
        try store.sessionTerminals.record(
            source: .claude, sessionId: "s1", binding: TerminalBinding(), at: Date())
        try expectEqual(
            try store.sessionTerminals.bindings(source: .claude, sessionId: "s1").count, 0)
    }

    // MARK: - 状态机透传

    t.test("状态机：终端绑定每次都更新（resume 换终端后跳转要落到当前那个）") {
        let store = TaskStore()
        let iterm = TerminalBinding(bundleId: "com.googlecode.iterm2", tty: "/dev/ttys001")
        let apple = TerminalBinding(bundleId: "com.apple.Terminal", tty: "/dev/ttys002")
        store.apply(TaskEvent(
            source: .claude, sessionId: "s1", kind: .taskStarted(title: "活儿"),
            timestamp: Date(timeIntervalSince1970: 1000), terminal: iterm))
        try expectEqual(
            try require(store.activeTasks["claude:s1"]?.terminal).bundleId,
            "com.googlecode.iterm2")
        store.apply(TaskEvent(
            source: .claude, sessionId: "s1", kind: .activity(tool: "Bash"),
            timestamp: Date(timeIntervalSince1970: 2000), terminal: apple))
        try expectEqual(
            try require(store.activeTasks["claude:s1"]?.terminal).bundleId,
            "com.apple.Terminal", "不能只设一次，否则换了终端还跳老的")
    }

    // MARK: - 迁移安全

    t.test("迁移 v14→v15：task_history 与 session_terminals 都不能被 DROP") {
        let path = tempStorePath()
        defer { try? FileManager.default.removeItem(at: path) }
        // 先建库并写入事实数据
        do {
            let store = try EurekaStore(path: path)
            try store.history.insert(FinishedTask(
                source: .claude, sessionId: "s1", title: "旧任务", cwd: "/tmp",
                startedAt: Date(timeIntervalSince1970: 1000),
                finishedAt: Date(timeIntervalSince1970: 2000), outcome: .success, detail: nil))
            try store.sessionTerminals.record(
                source: .claude, sessionId: "s1",
                binding: TerminalBinding(bundleId: "com.googlecode.iterm2", tty: "/dev/ttys001"),
                at: Date(timeIntervalSince1970: 1500))
        }
        // 把版本号退回 14，模拟"从旧版升级"，再开一次触发迁移
        do {
            let db = try SQLiteDB(path: path.path)
            try db.execute("PRAGMA user_version = 14")
        }
        let reopened = try EurekaStore(path: path)
        try expectEqual(try reopened.history.recent(limit: 10).count, 1, "历史是事实，不许 DROP")
        try expectEqual(
            try reopened.sessionTerminals.bindings(source: .claude, sessionId: "s1").count, 1,
            "终端绑定只能在事件发生时采到，不可重推导 → 同样不许 DROP")
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

/// PreToolUse / PreCompact 的状态机行为（岛上信息密度那一组改动的保障）
func toolPendingTests(_ t: TestRunner) {
    t.suite("岛上信息密度 · 即将执行 / 压缩上下文")

    func event(_ kind: TaskEvent.Kind, at seconds: Double) -> TaskEvent {
        TaskEvent(
            source: .claude, sessionId: "s1", kind: kind,
            timestamp: Date(timeIntervalSince1970: seconds))
    }

    t.test("PreToolUse 带出工具与对象；换工具后旧对象串不残留") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "活儿"), at: 100))
        store.apply(event(.toolPending(tool: "Edit", detail: "/repo/a.swift"), at: 110))
        var task = try require(store.activeTasks["claude:s1"])
        try expectEqual(task.currentActivity, "Edit")
        try expectEqual(task.currentToolDetail, "/repo/a.swift")

        // PostToolUse 只带工具名。同一个工具 → 对象串保留（还是那件事）
        store.apply(event(.activity(tool: "Edit"), at: 120))
        task = try require(store.activeTasks["claude:s1"])
        try expectEqual(task.currentToolDetail, "/repo/a.swift", "同工具不该清掉对象串")

        // 换了工具 → 旧对象串必须清掉，否则会显示成「Bash /repo/a.swift」这种错配
        store.apply(event(.activity(tool: "Bash"), at: 130))
        task = try require(store.activeTasks["claude:s1"])
        try expectEqual(task.currentActivity, "Bash")
        try expect(task.currentToolDetail == nil, "换工具后旧对象串必须清空")
    }

    t.test("PreToolUse 把等待/空闲复位为运行中（它在权限提示之前到）") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "活儿"), at: 100))
        store.apply(event(.waiting(reason: .permission, message: "需要授权"), at: 110))
        store.apply(event(.toolPending(tool: "Bash", detail: "ls"), at: 120))
        let task = try require(store.activeTasks["claude:s1"])
        guard case .running = task.phase else {
            throw ExpectationError(description: "应复位为 running，实际 \(task.phase)")
        }
    }

    t.test("会话未知时 PreToolUse 也能登记（app 在 turn 中途启动）") {
        let store = TaskStore()
        store.apply(event(.toolPending(tool: "Read", detail: "/x.txt"), at: 100))
        let task = try require(store.activeTasks["claude:s1"])
        try expectEqual(task.currentActivity, "Read")
        try expectEqual(task.currentToolDetail, "/x.txt")
    }

    t.test("压缩中：置位后有工具动静即清除，重复事件不重复刷 UI") {
        let store = TaskStore()
        store.apply(event(.taskStarted(title: "活儿"), at: 100))
        try expectEqual(store.apply(event(.compacting, at: 110)), [.activeTasksChanged])
        let compacting = try require(store.activeTasks["claude:s1"])
        try expect(compacting.isCompacting)
        // 重复的 PreCompact 不该再刷一次 UI
        try expectEqual(store.apply(event(.compacting, at: 115)), [])
        // 压缩结束后随便一个工具心跳都该把标记清掉
        store.apply(event(.activity(tool: "Bash"), at: 120))
        let afterTool = try require(store.activeTasks["claude:s1"])
        try expect(!afterTool.isCompacting)
    }

    t.test("压缩事件对未知会话不造幽灵任务") {
        let store = TaskStore()
        try expectEqual(store.apply(event(.compacting, at: 100)), [])
        try expect(store.activeTasks.isEmpty)
    }
}

/// 岛上「在做什么」标签的压缩规则（路径取末段 / 命令截头部 / 预算兜底）
func compactToolLabelTests(_ t: TestRunner) {
    t.suite("岛上工具标签 · 压缩规则")

    t.test("路径取末段 —— 那才是有辨识力的部分") {
        try expectEqual(
            compactToolLabel(tool: "Edit", detail: "/repo/src/main.swift"), "Edit main.swift")
        try expectEqual(
            compactToolLabel(tool: "Read", detail: "~/notes/todo.md"), "Read todo.md")
        // 结尾斜杠不该产出空末段
        try expectEqual(
            compactToolLabel(tool: "Read", detail: "/a/b/logs/"), "Read logs")
    }

    t.test("命令从头部截 —— rm -rf 这种关键前缀必须留住") {
        // 命令里带斜杠不代表它是路径（曾按路径处理，结果把整条命令当末段）
        try expectEqual(
            compactToolLabel(tool: "Bash", detail: "rm -rf node_modules/", budget: 12),
            "Bash rm -rf node_…")
        try expectEqual(
            compactToolLabel(tool: "Bash", detail: "ls", budget: 12), "Bash ls")
    }

    t.test("无对象串 / 空串 → 只显示工具名，不留多余空格") {
        try expectEqual(compactToolLabel(tool: "TodoWrite", detail: nil), "TodoWrite")
        try expectEqual(compactToolLabel(tool: "TodoWrite", detail: ""), "TodoWrite")
    }

    t.test("正好等于预算不截，超一个字才截") {
        try expectEqual(
            compactToolLabel(tool: "T", detail: "123456789012", budget: 12), "T 123456789012")
        try expectEqual(
            compactToolLabel(tool: "T", detail: "1234567890123", budget: 12),
            "T 123456789012…")
    }
}

/// 进程探测兜底（无 hook 的源）：只测可确定的纯逻辑与安全性质，
/// 不断言"当前机器上有哪些进程"——那不可复现。
func terminalProberTests(_ t: TestRunner) {
    t.suite("终端归属 · 进程探测兜底")

    t.test("空输入立即返回（无事可做时一次 syscall 都不做）") {
        try expectEqual(TerminalProber.probe(wanted: []).count, 0)
    }

    t.test("不存在的 cwd 不产出任何绑定（宁可没有也不给错的）") {
        let probes = TerminalProber.probe(wanted: [
            (source: .claude, cwd: "/definitely/not/a/real/path-\(UUID())"),
        ])
        try expectEqual(probes.count, 0)
    }

    t.test(".app 根解析：从可执行路径反推 bundle 目录") {
        try expectEqual(
            TerminalProber.appBundleRoot(of: "/Applications/iTerm.app/Contents/MacOS/iTerm2"),
            "/Applications/iTerm.app")
        // 名字带空格的应用（本机的 IntelliJ IDEA 就是）
        try expectEqual(
            TerminalProber.appBundleRoot(
                of: "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea"),
            "/Applications/IntelliJ IDEA.app")
        // 不是 .app 里的可执行文件 → nil（普通 CLI 不该被当成宿主）
        try expect(TerminalProber.appBundleRoot(of: "/bin/zsh") == nil)
        try expect(TerminalProber.appBundleRoot(of: "/opt/homebrew/bin/tmux") == nil)
    }

    t.test("控制终端设备号 → 路径；无控制终端返回 nil") {
        // -1 / 0 都表示没有控制终端（GUI 应用派生的进程）
        try expect(TerminalProber.ttyPath(of: -1) == nil)
        try expect(TerminalProber.ttyPath(of: 0) == nil)
    }

    t.test("进程原语对本进程可用（cwd / 可执行路径 / 进程表非空）") {
        let me = getpid()
        let cwd = try require(TerminalProber.processCWD(me))
        try expect(!cwd.isEmpty)
        let path = try require(TerminalProber.processPath(me))
        try expect(path.contains("/"))
        try expect(!TerminalProber.processTable().isEmpty)
        // 本进程必定在表里
        try expect(TerminalProber.processTable().contains { $0.pid == me })
    }

    t.test("状态机：hook 精度的绑定不会被 probe 覆盖") {
        let store = TaskStore()
        store.apply(TaskEvent(
            source: .claude, sessionId: "s1", kind: .taskStarted(title: "活儿"),
            timestamp: Date(timeIntervalSince1970: 100),
            terminal: TerminalBinding(bundleId: "com.googlecode.iterm2", origin: .hook)))
        // 探测报了个不一样的终端 —— 不该覆盖已有的精确结果
        let changed = store.attachTerminal(
            TerminalBinding(bundleId: "com.apple.Terminal", origin: .probe),
            source: .claude, sessionId: "s1")
        try expect(!changed, "probe 不许覆盖 hook")
        try expectEqual(
            try require(store.activeTasks["claude:s1"]?.terminal).bundleId,
            "com.googlecode.iterm2")
    }

    t.test("状态机：没有绑定时 probe 可以补上；hook 随后可以升级它") {
        let store = TaskStore()
        store.apply(TaskEvent(
            source: .claude, sessionId: "s1", kind: .taskStarted(title: "活儿"),
            timestamp: Date(timeIntervalSince1970: 100)))
        try expect(store.attachTerminal(
            TerminalBinding(bundleId: "com.apple.Terminal", origin: .probe),
            source: .claude, sessionId: "s1"))
        // hook 后到 → 允许升级精度
        try expect(store.attachTerminal(
            TerminalBinding(bundleId: "com.googlecode.iterm2", origin: .hook),
            source: .claude, sessionId: "s1"))
        let task = try require(store.activeTasks["claude:s1"])
        try expectEqual(task.terminal?.origin, .hook)
        // 重复同一个绑定不算改动（免得白刷 UI）
        try expect(!store.attachTerminal(
            TerminalBinding(bundleId: "com.googlecode.iterm2", origin: .hook),
            source: .claude, sessionId: "s1"))
    }

    t.test("状态机：未知会话的补齐请求被忽略（不造幽灵任务）") {
        let store = TaskStore()
        try expect(!store.attachTerminal(
            TerminalBinding(bundleId: "com.apple.Terminal", origin: .probe),
            source: .claude, sessionId: "nope"))
        try expect(store.activeTasks.isEmpty)
    }
}
