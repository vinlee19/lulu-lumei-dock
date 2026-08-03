import EurekaKit
import Foundation

func mascotStateTests(_ t: TestRunner) {
    t.suite("MascotBaseResolver")

    func at(hour: Int) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 12; c.hour = hour; c.minute = 0
        return Calendar.current.date(from: c)!
    }

    t.test("等待任务最高优先级 → waiting") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: true, hasRunningTask: true, idleSeconds: 0, now: at(hour: 14)))
        try expectEqual(state, .waiting)
    }

    t.test("运行中·白天 → working") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: true, idleSeconds: 0, now: at(hour: 14)))
        try expectEqual(state, .working)
    }

    t.test("运行中·深夜 → night") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: true, idleSeconds: 0, now: at(hour: 2)))
        try expectEqual(state, .night)
    }

    t.test("无任务·短空闲·白天 → idle") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 10,
            sleepThreshold: 60, now: at(hour: 14)))
        try expectEqual(state, .idle)
    }

    t.test("无任务·空闲超阈值 → sleeping") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 120,
            sleepThreshold: 60, now: at(hour: 14)))
        try expectEqual(state, .sleeping)
    }

    t.test("无任务·深夜(未超空闲阈值)也 → sleeping") {
        let state = MascotBaseResolver.base(.init(
            hasWaitingTask: false, hasRunningTask: false, idleSeconds: 5,
            sleepThreshold: 60, now: at(hour: 1)))
        try expectEqual(state, .sleeping)
    }

    t.test("缺图回退链:night→sleeping→idle、idle 到底") {
        try expectEqual(MascotState.night.fallback, .sleeping)
        try expectEqual(MascotState.sleeping.fallback, .idle)
        try expectEqual(MascotState.success.fallback, .working)
        try expectEqual(MascotState.idle.fallback, .idle)
    }

    t.test("精灵网格同时支持 v2 8×11 与 v3 4×12") {
        let v2 = MascotSpriteGrid(columns: 8, rows: 11)
        let v3 = MascotSpriteGrid(columns: 4, rows: 12)
        try expect(v2.contains(row: 10, column: 7), "v2 最后一格应有效")
        try expect(!v2.contains(row: 11, column: 0), "v2 越界行应拒绝")
        try expect(v3.contains(row: 11, column: 3), "v3 最后一格应有效")
        try expect(!v3.contains(row: 0, column: 4), "v3 越界列应拒绝")
    }

    t.test("播放模式:循环取模、单次停在末帧") {
        try expectEqual(MascotPlaybackMode.loop.frameIndex(
            elapsed: 1.25, fps: 4, frameCount: 4), 1)
        try expectEqual(MascotPlaybackMode.onceHoldLast.frameIndex(
            elapsed: 1.25, fps: 4, frameCount: 4), 3)
        try expectEqual(MascotPlaybackMode.onceHoldLast.frameIndex(
            elapsed: -1, fps: 4, frameCount: 4), 0)
    }

    t.test("动画门控:仅可见且清醒时刷新") {
        try expect(MascotAnimationPolicy.shouldAnimate(isVisible: true, isAwake: true),
                   "可见且清醒时应播放")
        try expect(!MascotAnimationPolicy.shouldAnimate(isVisible: false, isAwake: true),
                   "隐藏时应暂停")
        try expect(!MascotAnimationPolicy.shouldAnimate(isVisible: true, isAwake: false),
                   "系统休眠时应暂停")
    }
}
