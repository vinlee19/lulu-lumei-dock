import EurekaKit
import Foundation

func soundCueTests(_ t: TestRunner) {
    t.suite("SoundCue / SoundThrottle")

    let t0 = Date(timeIntervalSince1970: 1_000)

    t.test("任务结果与等待原因各对应一类提示音") {
        try expectEqual(SoundCue.forFinished(.success), .completed)
        try expectEqual(SoundCue.forFinished(.error), .failed)
        try expectEqual(SoundCue.forFinished(.interrupted), .interrupted)
        try expectEqual(SoundCue.forWaiting(.permission), .permission)
        try expectEqual(SoundCue.forWaiting(.idle), .input)
    }

    t.test("每类默认声音互不相同，且都是 macOS 自带的提示音") {
        let builtIn: Set<String> = [
            "Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero",
            "Morse", "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink",
        ]
        let defaults = SoundCue.allCases.map(\.defaultSound)
        try expectEqual(Set(defaults).count, defaults.count)
        for name in defaults {
            try expect(builtIn.contains(name), "\(name) 不在 /System/Library/Sounds 里")
        }
    }

    t.test("优先级：等待授权最高，正常完成最低，没有并列") {
        let priorities = SoundCue.allCases.map(\.priority)
        try expectEqual(Set(priorities).count, priorities.count)
        try expectEqual(SoundCue.allCases.max { $0.priority < $1.priority }, .permission)
        try expectEqual(SoundCue.allCases.min { $0.priority < $1.priority }, .completed)
        try expect(SoundCue.failed.priority > SoundCue.completed.priority)
    }

    t.test("第一声直接响") {
        var throttle = SoundThrottle()
        try expectEqual(throttle.decide(.completed, at: t0), .play)
    }

    t.test("时间窗内同级或更低的事件被覆盖：三个会话同时完成只响一声") {
        var throttle = SoundThrottle()
        try expectEqual(throttle.decide(.completed, at: t0), .play)
        try expectEqual(throttle.decide(.completed, at: t0.addingTimeInterval(0.2)), .covered)
        try expectEqual(throttle.decide(.completed, at: t0.addingTimeInterval(0.4)), .covered)

        var failedFirst = SoundThrottle()
        try expectEqual(failedFirst.decide(.failed, at: t0), .play)
        try expectEqual(failedFirst.decide(.completed, at: t0.addingTimeInterval(0.5)), .covered)
    }

    t.test("时间窗内更紧急的事件照样响：完成后马上等待授权") {
        var throttle = SoundThrottle()
        try expectEqual(throttle.decide(.completed, at: t0), .play)
        try expectEqual(throttle.decide(.permission, at: t0.addingTimeInterval(0.3)), .play)
        // The window restarts at the permission sound, so the question right after is covered
        try expectEqual(throttle.decide(.question, at: t0.addingTimeInterval(1.6)), .covered)
    }

    t.test("时间窗过后同类事件重新响") {
        var throttle = SoundThrottle()
        try expectEqual(throttle.decide(.completed, at: t0), .play)
        try expectEqual(
            throttle.decide(.completed, at: t0.addingTimeInterval(SoundThrottle.window)), .play)
    }

    t.test("被覆盖的事件不顺延时间窗：持续的完成事件隔一个时间窗响一声") {
        var throttle = SoundThrottle()
        var played = 0
        // One finished event every 0.5s for 6s
        for step in 0..<12 {
            if throttle.decide(.completed, at: t0.addingTimeInterval(Double(step) * 0.5)) == .play {
                played += 1
            }
        }
        try expectEqual(played, 4)
    }

    t.test("时钟回拨不会把后续事件一直判成被覆盖") {
        var throttle = SoundThrottle()
        try expectEqual(throttle.decide(.completed, at: t0), .play)
        try expectEqual(throttle.decide(.completed, at: t0.addingTimeInterval(-60)), .play)
    }
}
