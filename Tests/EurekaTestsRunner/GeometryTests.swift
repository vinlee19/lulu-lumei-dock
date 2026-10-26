import CoreGraphics
import EurekaKit
import Foundation

func geometryTests(_ t: TestRunner) {
    t.suite("IslandGeometry")

    // Real parameter shapes of this machine's two screens
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

        // Fully inside the external screen -> usable
        try expect(IslandGeometry.positionUsable(
            origin: CGPoint(x: -1200, y: 300), panelSize: panel,
            screens: [builtin, external]))
        // Real incident coordinates: X=-462 left over after unplugging the external screen -- zero
        // or edge-only overlap with the built-in screen -> unusable
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: -462, y: 380.87), panelSize: panel,
            screens: [builtin]))
        // Overlapping by one pixel (the panel's right edge just reaches the screen) -> the pill
        // band is not fully on screen -> unusable
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: -439, y: 300), panelSize: panel,
            screens: [builtin]))
        // Entirely outside every screen -> unusable
        try expect(!IslandGeometry.positionUsable(
            origin: CGPoint(x: 5000, y: 5000), panelSize: panel,
            screens: [builtin, external]))
    }

    t.test("刘海屏：内容贴顶、胶囊与刘海融合") {
        try expectEqual(IslandGeometry.contentTopInset(screen: notched), 0)
        let pill = IslandGeometry.pillSize(screen: notched)
        try expectEqual(pill.height, 32)  // same height as the notch
        try expectEqual(pill.width, 196 + 92 * 2)  // notch + two wings
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
        try expectEqual(rect.maxY, layout.panelSize.height)  // on a notched screen the content hugs the panel top
        try expectEqual(rect.height, 32)

        let rect2 = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 184, height: 30), screen: external4K, layout: layout)
        try expectEqual(rect2.maxY, layout.panelSize.height - 29)  // clears the menu bar, 24+5

        try expectEqual(
            IslandGeometry.interactiveRect(contentSize: .zero, screen: notched, layout: layout),
            .zero)
    }

    t.test("flippedRect：左下原点 ↔ 左上原点（NSHostingView 命中判断回归）") {
        let layout = IslandGeometry.Layout.standard
        // Notched-screen compact pill: bottom-left coordinates hug the panel top (maxY =
        // panelHeight)
        let bottomLeft = IslandGeometry.interactiveRect(
            contentSize: CGSize(width: 328, height: 32), screen: notched, layout: layout)
        let flipped = IslandGeometry.flippedRect(
            bottomLeft, containerHeight: layout.panelSize.height)
        // After flipping it should hug the view top (flipped minY = 0), i.e. where the user
        // actually sees/clicks
        try expectEqual(flipped.minY, 0)
        try expectEqual(flipped.height, 32)
        try expectEqual(flipped.midX, layout.panelSize.width / 2)
        // No notch: after flipping, minY = the menu-bar clearance
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
        // Built-in screen (1512 wide) = baseline
        try expectEqual(IslandGeometry.scaleFactor(for: notched), 1.0)
        // 4K scaled to a logical width of 1920 -> ~1.27
        let fourK = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let f4k = IslandGeometry.scaleFactor(for: fourK)
        try expect(f4k > 1.2 && f4k < 1.3, "4K 应放大约 1.27×，实际 \(f4k)")
        // Very large screens clamp to 1.6
        let huge = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 3840, height: 2160))
        try expectEqual(IslandGeometry.scaleFactor(for: huge), 1.6)
        // Too-small screens clamp to 0.9
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
        // Proportional scale-up: the ratio is unchanged
        let bigRatio = big.expandedCardSize.width / big.expandedCardSize.height
        try expect(abs(bigRatio - ratio) < 0.001, "缩放应保持长宽比")
    }

    t.test("子 agent 框高度：空为 0、随数量单增、6 行封顶") {
        try expectEqual(IslandGeometry.subagentBoxHeight(count: 0), 0)
        let h1 = IslandGeometry.subagentBoxHeight(count: 1)
        let h3 = IslandGeometry.subagentBoxHeight(count: 3)
        try expect(h1 > 0 && h3 > h1, "应随数量单调增")
        try expectEqual(h3, 3 * 22 + 2 * 4 + 16)  // rows + row spacing + top/bottom padding
        // Beyond 6 rows one "...and N more" row is added; 7 and above cap identically
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
        // Only idle sessions: no running rows to separate, so no divider is drawn
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

    t.test("完成卡 / 等待卡：带「打开会话」按钮时加高一个按钮区，大屏放大后仍放得进 panel") {
        typealias M = IslandGeometry.ExpandedCard
        let base = IslandGeometry.Layout.standard.expandedCardSize.height
        try expectEqual(IslandGeometry.expandedCardHeight(hasAction: false), base, "不带按钮保持原尺寸")
        try expectEqual(
            IslandGeometry.expandedCardHeight(hasAction: true), base + M.actionGap + M.actionHeight)
        // Card and panel scale together, so comparing the 1.0x baseline is enough; the top still
        // has to leave room for the notch / menu bar
        let tallest = IslandGeometry.expandedCardHeight(hasAction: true)
        try expect(tallest + 44 <= IslandGeometry.Layout.standard.panelSize.height,
                   "带按钮的卡 \(tallest) 放不进 panel")
    }

    t.test("提问卡：选项封顶 4 行，问题区按 1–2 行定高，让开刘海后最高的卡仍放得进 panel") {
        typealias M = IslandGeometry.QuestionCard
        let four = IslandGeometry.questionCardHeight(optionCount: 4, questionLines: 2, topInset: 0)
        try expectEqual(
            IslandGeometry.questionCardHeight(optionCount: 9, questionLines: 2, topInset: 0), four)
        try expectEqual(
            IslandGeometry.questionCardHeight(optionCount: 4, questionLines: 1, topInset: 0),
            four - M.questionLineHeight, "一行的问题不留第二行的空白")
        try expectEqual(
            IslandGeometry.questionCardHeight(optionCount: 4, questionLines: 5, topInset: 0), four,
            "问题最多排两行")
        try expectEqual(
            IslandGeometry.questionCardHeight(optionCount: 4, questionLines: 2, topInset: 38),
            four - M.plainTopPadding + 38 + 6, "刘海下沿再空 6")
        let tallest = IslandGeometry.questionCardHeight(
            optionCount: 4, questionLines: 2, topInset: 44)
        try expect(tallest + 17 <= IslandGeometry.Layout.standard.panelSize.height,
                   "最高 \(tallest) 放不进 panel")
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
        // Card shadow radius 12, offset down 5: 17pt must still be left at the bottom
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
        // A burst of hundreds of finished events (seen in practice: the opencode event table was
        // replayed wholesale) must not pin the island open for minutes: every card fills a whole
        // dismiss window, so an uncapped queue = an island that never collapses. The history page
        // has every record.
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
        queue.enqueue(waiting("w"))  // duplicate waiting event
        try expectEqual(queue.current, finished("a"))  // the current card is not interrupted
        try expectEqual(queue.pending.first, waiting("w"))
        try expectEqual(queue.pendingCount, 2)  // w only once + b
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
        queue.enqueue(alert("op-1"))  // same alert repeated
        try expectEqual(queue.current, finished("a"))   // the current card is not interrupted
        try expectEqual(queue.pending.first, alert("op-1"))  // the alert jumps to the front of the pending queue
        try expectEqual(queue.pendingCount, 2)  // alert only once + b
    }

    t.test("空队列告警直接成为当前卡") {
        var queue = IslandCardQueue()
        queue.enqueue(alert("op-9"))
        try expectEqual(queue.current, alert("op-9"))
        queue.advance()
        try expect(queue.isEmpty)
    }

    // MARK: - Auto-dismiss duration (both timers in IslandViewModel share this one rule)

    t.test("四类卡的自动收起偏移：完成 +0 / 等待 +4 / 提示 +5 / 告警 +6") {
        try expectEqual(finished("a").autoDismissExtraSeconds, 0)
        try expectEqual(waiting("a").autoDismissExtraSeconds, 4)
        try expectEqual(notice("n").autoDismissExtraSeconds, 5)
        try expectEqual(alert("op-1").autoDismissExtraSeconds, 6)
    }

    t.test("等待卡不再常驻 —— 四类卡全都自动收起") {
        // .waiting used to return nil (stayed until clicked away). After switching it to
        // auto-dismiss, the switch in IslandViewModel.setHovering that hard-listed cases would have
        // missed it, showing up as "hovering once makes it sticky again"; with the rule moved into
        // Card the two places can no longer drift.
        for card in [finished("a"), waiting("a"), notice("n"), alert("op-1")] {
            try expect(card.autoDismisses, "\(card) 应自动收起")
        }
    }

    t.test("偏移叠加在用户设置的基准秒数上，而不是写死绝对值") {
        // The Settings slider (3-15s) is what carries the user's intent: with a base of 6 the
        // waiting card gets 10s, with a base of 12 it gets 16s. Hardcoding 10s would make "the
        // waiting card dismisses faster than the finished card" once the slider is at 15.
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
        // Same sessionId from a different source is a different session
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

    t.test("胶囊保留：运行中、空闲会话、未读完成任一存在就保留，三者都空才隐藏") {
        let none = IslandUnreadFinished()
        var unread = IslandUnreadFinished()
        unread.add(FinishedTask(
            source: .claude, sessionId: "f",
            finishedAt: Date(timeIntervalSince1970: 1000), outcome: .success))

        try expect(IslandPill.isShown(active: [task("r")], idle: [], unread: none))
        try expect(
            IslandPill.isShown(active: [], idle: [task("i", .idle)], unread: none),
            "只剩空闲会话也保留胶囊")
        try expect(IslandPill.isShown(active: [], idle: [], unread: unread))
        try expect(!IslandPill.isShown(active: [], idle: [], unread: none))
    }
}
