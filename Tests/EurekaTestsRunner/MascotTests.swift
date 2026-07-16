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
}
