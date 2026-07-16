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
}
