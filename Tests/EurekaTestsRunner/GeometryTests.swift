import CoreGraphics
import EurekaKit
import Foundation

func geometryTests(_ t: TestRunner) {
    t.suite("IslandGeometry")

    // 本机两块屏的真实参数形状
    let notched = IslandGeometry.ScreenInfo(
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        safeAreaTopInset: 32,
        notchWidth: 196,
        menuBarHeight: 32
    )
    let external4K = IslandGeometry.ScreenInfo(
        frame: CGRect(x: 1512, y: -200, width: 1920, height: 1080),
        safeAreaTopInset: 0,
        notchWidth: nil,
        menuBarHeight: 24
    )

    t.test("panel 顶部居中贴上沿（含负坐标外接屏）") {
        let layout = IslandGeometry.Layout.standard

        let frame1 = IslandGeometry.panelFrame(screen: notched, layout: layout)
        try expectEqual(frame1.midX, 756)
        try expectEqual(frame1.maxY, 982)
        try expectEqual(frame1.size, layout.panelSize)

        let frame2 = IslandGeometry.panelFrame(screen: external4K, layout: layout)
        try expectEqual(frame2.midX, 1512 + 960)
        try expectEqual(frame2.maxY, -200 + 1080)
    }

    t.test("positionUsable：完整可见 true；擦边残留 false；全屏外 false") {
        let panel = CGSize(width: 440, height: 460)
        let builtin = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: -1920, y: -124, width: 1920, height: 1080)

        // 完整落在外接屏内 → 可用
        try expect(IslandGeometry.positionUsable(
            origin: CGPoint(x: -1200, y: 300), panelSize: panel,
            screens: [builtin, external]))
        // 真实事故坐标：外接屏拔掉后 X=-462 残留——与内建屏零相交/仅擦边 → 不可用
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: -462, y: 380.87), panelSize: panel,
            screens: [builtin]))
        // 擦边一像素（面板右缘刚够到屏）→ 胶囊带不完整在屏内 → 不可用
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: -439, y: 300), panelSize: panel,
            screens: [builtin]))
        // 完全在所有屏之外 → 不可用
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: 5000, y: 5000), panelSize: panel,
            screens: [builtin, external]))
    }

    t.test("刘海屏：内容贴顶、胶囊与刘海融合") {
        try expectEqual(IslandGeometry.contentTopInset(screen: notched), 0)
        let pill = IslandGeometry.pillSize(screen: notched)
        try expectEqual(pill.height, 32)  // 与刘海等高
        try expectEqual(pill.width, 196 + 92 * 2)  // 刘海 + 两翼
        try expectEqual(IslandGeometry.pillCenterGap(screen: notched), 196)
    }

    t.test("无刘海屏：避开菜单栏悬浮、小胶囊、无中缝") {
        try expectEqual(IslandGeometry.contentTopInset(screen: external4K), 24 + 5)
        try expectEqual(IslandGeometry.pillSize(screen: external4K), CGSize(width: 232, height: 40))
        try expectEqual(IslandGeometry.pillCenterGap(screen: external4K), 0)
    }

    t.test("interactiveRect：panel 坐标系内顶部居中") {
        let layout = IslandGeometry.Layout.standard
        let rect = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 328, height: 32), screen: notched, layout: layout)
        try expectEqual(rect.midX, layout.panelSize.width / 2)
        try expectEqual(rect.maxY, layout.panelSize.height)  // 刘海屏内容贴 panel 顶
        try expectEqual(rect.height, 32)

        let rect2 = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 184, height: 30), screen: external4K, layout: layout)
        try expectEqual(rect2.maxY, layout.panelSize.height - 29)  // 让开菜单栏 24+5

        try expectEqual(
            IslandGeometry.interactiveRect(contentSize: .zero, screen: notched, layout: layout),
            .zero)
    }

    t.test("flippedRect：左下原点 ↔ 左上原点（NSHostingView 命中判断回归）") {
        let layout = IslandGeometry.Layout.standard
        // 刘海屏 compact 胶囊：左下坐标贴 panel 顶（maxY = panelHeight）
        let bottomLeft = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 328, height: 32), screen: notched, layout: layout)
        let flipped = IslandGeometry.flippedRect(
            bottomLeft, containerHeight: layout.panelSize.height)
        // 翻转后应贴视图顶部（flipped 坐标 minY = 0），即用户实际看到/点击的位置
        try expectEqual(flipped.minY, 0)
        try expectEqual(flipped.height, 32)
        try expectEqual(flipped.midX, layout.panelSize.width / 2)
        // 无刘海：翻转后 minY = 菜单栏让位
        let plain = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 184, height: 30), screen: external4K, layout: layout)
        let plainFlipped = IslandGeometry.flippedRect(
            plain, containerHeight: layout.panelSize.height)
        try expectEqual(plainFlipped.minY, 29)
        try expectEqual(IslandGeometry.flippedRect(.zero, containerHeight: 190), .zero)
    }

    t.test("未知刘海宽度时用默认值兜底") {
        var screen = notched
        screen.notchWidth = nil
        try expectEqual(IslandGeometry.pillSize(screen: screen).width, 196 + 184)
        try expectEqual(IslandGeometry.pillCenterGap(screen: screen), 196)
    }

    t.test("按屏缩放：内建屏 1.0×、大屏放大、钳制上下限") {
        // 内建屏（1512 宽）= 基准
        try expectEqual(IslandGeometry.scaleFactor(for: notched), 1.0)
        // 4K 缩放后逻辑宽 1920 → ~1.27
        let fourK = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let f4k = IslandGeometry.scaleFactor(for: fourK)
        try expect(f4k > 1.2 && f4k < 1.3, "4K 应放大约 1.27×，实际 \(f4k)")
        // 超大屏钳到 1.6
        let huge = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        try expectEqual(IslandGeometry.scaleFactor(for: huge), 1.6)
        // 过小屏钳到 0.9
        let tiny = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        try expectEqual(IslandGeometry.scaleFactor(for: tiny), 0.9)
    }

    t.test("layout(for:)：卡片维持黄金比、随屏等比放大") {
        let base = IslandGeometry.layout(for: notched)  // 1.0×
        let ratio = base.expandedCardSize.width / base.expandedCardSize.height
        try expect(abs(ratio - 1.618) < 0.05, "卡片应近似黄金比 φ，实际 \(ratio)")

        let fourK = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let big = IslandGeometry.layout(for: fourK)
        try expect(big.expandedCardSize.width > base.expandedCardSize.width, "大屏应更大")
        // 等比放大：比例不变
        let bigRatio = big.expandedCardSize.width / big.expandedCardSize.height
        try expect(abs(bigRatio - ratio) < 0.001, "缩放应保持长宽比")
    }

    t.test("子 agent 框高度：空为 0、随数量单增、6 行封顶") {
        try expectEqual(IslandGeometry.subagentBoxHeight(count: 0), 0)
        let h1 = IslandGeometry.subagentBoxHeight(count: 1)
        let h3 = IslandGeometry.subagentBoxHeight(count: 3)
        try expect(h1 > 0 && h3 > h1, "应随数量单调增")
        try expectEqual(h3, 3 * 22 + 2 * 4 + 16)  // 行 + 行距 + 上下内距
        // 超 6 行加一行"…等 N 个"，7 与更多封顶一致
        try expectEqual(
            IslandGeometry.subagentBoxHeight(count: 99),
            IslandGeometry.subagentBoxHeight(count: 7))
    }

    t.test("任务列表高度：标题 + 进行中行 + 分隔线 + 空闲分区") {
        typealias M = IslandGeometry.TaskList
        let headerOnly = M.topPadding + M.headerHeight + M.headerGap + M.bottomPadding
        try expectEqual(IslandGeometry.taskListHeight(activeCount: 0, idleCount: 0), headerOnly)
        try expectEqual(
            IslandGeometry.taskListHeight(activeCount: 2, idleCount: 0),
            headerOnly + 2 * M.activeRowHeight + M.activeRowSpacing)
        // 只有空闲会话：没有进行中行可分隔，不画分隔线
        try expectEqual(
            IslandGeometry.taskListHeight(activeCount: 0, idleCount: 1),
            headerOnly + M.idleHeaderHeight + M.idleRowHeight)
        try expectEqual(
            IslandGeometry.taskListHeight(activeCount: 1, idleCount: 5),
            headerOnly + M.activeRowHeight + M.dividerHeight + M.idleHeaderHeight
                + 3 * M.idleRowHeight, "空闲最多 3 行")
        try expectEqual(
            IslandGeometry.taskListHeight(activeCount: 6, idleCount: 0),
            headerOnly + 4 * M.activeRowHeight + 3 * M.activeRowSpacing + M.overflowLineHeight,
            "进行中最多 4 行，多出的算一行「…等 N 个」")
    }

    t.test("任务列表：展开子 agent 框时收起空闲分区，最高的列表仍放得进 panel") {
        typealias M = IslandGeometry.TaskList
        try expect(IslandGeometry.taskListShowsIdle(idleCount: 3, expandedSubagentCount: 0))
        try expect(!IslandGeometry.taskListShowsIdle(idleCount: 3, expandedSubagentCount: 2))
        try expect(!IslandGeometry.taskListShowsIdle(idleCount: 0, expandedSubagentCount: 0))
        let expanded = IslandGeometry.taskListHeight(
            activeCount: 9, idleCount: 9, expandedSubagentCount: 9)
        try expectEqual(
            expanded,
            IslandGeometry.taskListHeight(activeCount: 9, idleCount: 0)
                + M.subagentBoxGap + IslandGeometry.subagentBoxHeight(count: 9))
        let tallest = max(
            expanded, IslandGeometry.taskListHeight(activeCount: 9, idleCount: 9))
        // 卡片阴影 radius 12、下移 5：底部还要留 17pt
        try expect(
            tallest + 17 <= IslandGeometry.Layout.standard.panelSize.height,
            "最高 \(tallest) 放不进 panel")
    }
}

func cardQueueTests(_ t: TestRunner) {
    t.suite("IslandCardQueue")

    func finished(_ session: String) -> IslandState.Card {
        .finished(FinishedTask(
            source: .claude, sessionId: session,
            finishedAt: Date(timeIntervalSince1970: 1000), outcome: .success))
    }
    func waiting(_ session: String) -> IslandState.Card {
        .waiting(AgentTask(
            source: .claude, sessionId: session,
            startedAt: Date(timeIntervalSince1970: 900),
            phase: .waiting(.permission, since: Date(timeIntervalSince1970: 950))))
    }
    func notice(_ id: String) -> IslandState.Card {
        .notice(IslandNotice(id: id, emoji: "🧘", headline: "歇一歇", body: "站起来走两步"))
    }

    t.test("完成卡按序排队逐显") {
        var queue = IslandCardQueue()
        queue.enqueue(finished("a"))
        queue.enqueue(finished("b"))
        try expectEqual(queue.current, finished("a"))
        try expectEqual(queue.pendingCount, 1)
        queue.advance()
        try expectEqual(queue.current, finished("b"))
        queue.advance()
        try expect(queue.isEmpty)
    }

    t.test("完成/提示卡待显数封顶：超出丢最旧；等待/告警卡不受限也不被挤掉") {
        // 一次爆发几百个完成事件（实测：opencode 事件表被整表重放）不能把岛按住几分钟：
        // 每张卡都占满一个收起窗口，队列不封顶 = 岛永远收不回去。历史页有全部记录。
        let cap = IslandCardQueue.maxPendingPassive
        var queue = IslandCardQueue()
        for i in 0..<(cap + 4) { queue.enqueue(finished("f\(i)")) }
        try expectEqual(queue.current, finished("f0"), "正在展示的卡不受影响")
        try expectEqual(queue.pendingCount, cap, "待显完成卡封顶")
        try expectEqual(queue.pending.last, finished("f\(cap + 3)"), "留下的是最新的")
        try expectEqual(queue.pending.first, finished("f4"), "丢掉的是最旧的")

        queue.enqueue(waiting("w"))
        try expectEqual(queue.pendingCount, cap + 1, "等待卡不算在封顶内")
        queue.enqueue(notice("n"))
        try expectEqual(queue.pendingCount, cap + 1, "提示卡与完成卡共用封顶：挤掉最旧的完成卡")
        try expect(queue.pending.contains(waiting("w")), "被挤掉的绝不能是等待卡")
        try expectEqual(queue.pending.last, notice("n"))
    }

    t.test("等待卡插队且同任务去重") {
        var queue = IslandCardQueue()
        queue.enqueue(finished("a"))
        queue.enqueue(finished("b"))
        queue.enqueue(waiting("w"))
        queue.enqueue(waiting("w"))  // 重复等待事件
        try expectEqual(queue.current, finished("a"))  // 当前卡不被打断
        try expectEqual(queue.pending.first, waiting("w"))
        try expectEqual(queue.pendingCount, 2)  // w 只一张 + b
    }

    t.test("removeWaiting 撤当前卡时自动推进") {
        var queue = IslandCardQueue()
        queue.enqueue(waiting("w"))
        queue.enqueue(finished("a"))
        try expectEqual(queue.current, waiting("w"))
        queue.removeWaiting(taskId: "claude:w")
        try expectEqual(queue.current, finished("a"))
        try expectEqual(queue.waitingTaskIds, [])
    }

    t.test("waitingTaskIds 汇总当前与排队中的等待卡") {
        var queue = IslandCardQueue()
        queue.enqueue(waiting("w1"))
        queue.enqueue(waiting("w2"))
        try expectEqual(Set(queue.waitingTaskIds), Set(["claude:w1", "claude:w2"]))
    }

    func alert(_ opId: String, rule: String = "rm-rf") -> IslandState.Card {
        .alert(RiskAlert(
            opId: opId, source: .claude, sessionId: "s1", ruleId: rule,
            ruleTitle: "高危", tool: "Bash", detail: "sudo rm -rf /",
            timestamp: Date(timeIntervalSince1970: 1000)))
    }

    t.test("告警卡插队置顶且按 id 去重") {
        var queue = IslandCardQueue()
        queue.enqueue(finished("a"))
        queue.enqueue(finished("b"))
        queue.enqueue(alert("op-1"))
        queue.enqueue(alert("op-1"))  // 同一告警重复
        try expectEqual(queue.current, finished("a"))   // 当前卡不被打断
        try expectEqual(queue.pending.first, alert("op-1"))  // 告警插到待显队首
        try expectEqual(queue.pendingCount, 2)  // alert 只一张 + b
    }

    t.test("空队列告警直接成为当前卡") {
        var queue = IslandCardQueue()
        queue.enqueue(alert("op-9"))
        try expectEqual(queue.current, alert("op-9"))
        queue.advance()
        try expect(queue.isEmpty)
    }

    // MARK: - 自动收起时长（IslandViewModel 的两处计时共用这一份判据）

    t.test("四类卡的自动收起偏移：完成 +0 / 等待 +4 / 提示 +5 / 告警 +6") {
        try expectEqual(finished("a").autoDismissExtraSeconds, 0)
        try expectEqual(waiting("a").autoDismissExtraSeconds, 4)
        try expectEqual(notice("n").autoDismissExtraSeconds, 5)
        try expectEqual(alert("op-1").autoDismissExtraSeconds, 6)
    }

    t.test("等待卡不再常驻 —— 四类卡全都自动收起") {
        // 曾经 .waiting 返回 nil（常驻到手动点掉）。改成自动收之后，
        // IslandViewModel.setHovering 那处原本硬列 case 的 switch 会漏掉它，
        // 表现为「悬停过一次就退回常驻」；判据收进 Card 后两处不可能再漂移。
        for card in [finished("a"), waiting("a"), notice("n"), alert("op-1")] {
            try expect(card.autoDismisses, "\(card) 应自动收起")
        }
    }

    t.test("偏移叠加在用户设置的基准秒数上，而不是写死绝对值") {
        // 设置页滑块 3–15s 才是用户意图的载体：基准 6 时等待卡 10s，基准调到 12 就是 16s。
        // 若写死 10s，滑块拉到 15 会出现「等待卡比完成卡收得还快」。
        guard let waitingExtra = waiting("a").autoDismissExtraSeconds,
              let finishedExtra = finished("a").autoDismissExtraSeconds
        else { throw ExpectationError(description: "完成卡与等待卡都应有偏移值") }
        try expectEqual(6 + waitingExtra, 10)
        try expect(
            waitingExtra > finishedExtra,
            "等待卡该比完成卡多停一会（授权请求要看清）")
    }
}

func unreadFinishedTests(_ t: TestRunner) {
    t.suite("IslandUnreadFinished")

    func finished(
        _ session: String, at time: TimeInterval, _ outcome: TaskOutcome = .success,
        source: AgentSource = .claude
    ) -> FinishedTask {
        FinishedTask(
            source: source, sessionId: session,
            finishedAt: Date(timeIntervalSince1970: time), outcome: outcome)
    }
    func running(_ session: String, source: AgentSource = .claude) -> AgentTask {
        AgentTask(
            source: source, sessionId: session,
            startedAt: Date(timeIntervalSince1970: 900), phase: .running)
    }

    t.test("同会话多次完成只记最近一次") {
        var unread = IslandUnreadFinished()
        unread.add(finished("a", at: 100))
        unread.add(finished("b", at: 200))
        unread.add(finished("a", at: 300))
        try expectEqual(unread.count, 2)
        try expectEqual(unread.latest, finished("a", at: 300))
    }

    t.test("会话开始新一轮 turn 即清掉它的未读，其他会话不受影响") {
        var unread = IslandUnreadFinished()
        unread.add(finished("a", at: 100))
        unread.add(finished("b", at: 200))
        unread.reconcile(activeTaskIds: [running("a").id])
        try expectEqual(unread.tasks, [finished("b", at: 200)])
        // 同 sessionId、不同来源是另一个会话
        unread.reconcile(activeTaskIds: [running("b", source: .codex).id])
        try expectEqual(unread.count, 1)
    }

    t.test("点卡片清单个，点开列表全清") {
        var unread = IslandUnreadFinished()
        unread.add(finished("a", at: 100))
        unread.add(finished("b", at: 200))
        unread.markRead(finished("a", at: 100))
        try expectEqual(unread.tasks, [finished("b", at: 200)])
        unread.markAllRead()
        try expect(unread.isEmpty)
        try expectEqual(unread.worstOutcome, nil)
    }

    t.test("标记取最严重的结果：出错 > 中断 > 成功") {
        var unread = IslandUnreadFinished()
        unread.add(finished("a", at: 100))
        try expectEqual(unread.worstOutcome, .success)
        unread.add(finished("b", at: 200, .interrupted))
        try expectEqual(unread.worstOutcome, .interrupted)
        unread.add(finished("c", at: 300, .error))
        try expectEqual(unread.worstOutcome, .error)
    }
}

func islandPillTests(_ t: TestRunner) {
    t.suite("IslandPill")

    func task(
        _ session: String, _ phase: AgentTask.Phase = .running,
        source: AgentSource = .claude, context: Double? = nil
    ) -> AgentTask {
        var task = AgentTask(
            source: source, sessionId: session,
            startedAt: Date(timeIntervalSince1970: 900), phase: phase)
        task.contextUsedPercent = context
        return task
    }
    let since = Date(timeIntervalSince1970: 950)

    t.test("来源图标：运行中与空闲来源取并集，按固定顺序，只有空闲的标为变暗") {
        let marks = IslandPill.sourceMarks(
            active: [task("a", source: .opencode), task("b")],
            idle: [task("c", .idle, source: .codex), task("d", .idle, source: .opencode)])
        try expectEqual(marks, [
            IslandPill.SourceMark(source: .claude, isActive: true),
            IslandPill.SourceMark(source: .codex, isActive: false),
            IslandPill.SourceMark(source: .opencode, isActive: true),
        ])
    }

    t.test("告警优先级：等待授权 > 等待输入 > ctx ≥ 90% > 未读完成 > 无") {
        var unread = IslandUnreadFinished()
        unread.add(FinishedTask(
            source: .claude, sessionId: "f",
            finishedAt: Date(timeIntervalSince1970: 1000), outcome: .error))
        let hot = task("hot", .idle, context: 93.4)
        let input = task("w1", .waiting(.idle, since: since))
        let permission = task("w2", .waiting(.permission, since: since))

        try expectEqual(
            IslandPill.alert(active: [input, permission], idle: [hot], unread: unread),
            .waiting(.permission))
        try expectEqual(
            IslandPill.alert(active: [input], idle: [hot], unread: unread), .waiting(.idle))
        try expectEqual(
            IslandPill.alert(active: [task("r", context: 70)], idle: [hot], unread: unread),
            .context(percent: 93.4), "空闲会话的 ctx 也算")
        try expectEqual(
            IslandPill.alert(active: [task("r", context: 89.9)], idle: [], unread: unread),
            .unread(count: 1, worstOutcome: .error), "90% 以下不亮")
        try expectEqual(
            IslandPill.alert(active: [task("r")], idle: [], unread: IslandUnreadFinished()), nil)
    }
}
