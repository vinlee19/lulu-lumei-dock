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
        try expectEqual(pill.width, 196 + 66 * 2)  // 刘海 + 两翼
        try expectEqual(IslandGeometry.pillCenterGap(screen: notched), 196)
    }

    t.test("无刘海屏：避开菜单栏悬浮、小胶囊、无中缝") {
        try expectEqual(IslandGeometry.contentTopInset(screen: external4K), 24 + 5)
        try expectEqual(IslandGeometry.pillSize(screen: external4K), CGSize(width: 184, height: 30))
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

    t.test("未知刘海宽度时用默认值兜底") {
        var screen = notched
        screen.notchWidth = nil
        try expectEqual(IslandGeometry.pillSize(screen: screen).width, 196 + 132)
        try expectEqual(IslandGeometry.pillCenterGap(screen: screen), 196)
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
}
