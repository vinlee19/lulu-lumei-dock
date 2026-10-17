import Foundation

/// Dynamic Island wellness card content
public struct IslandNotice: Equatable, Sendable, Identifiable {
    public var id: String
    public var emoji: String
    public var headline: String
    public var body: String

    public init(id: String, emoji: String, headline: String, body: String) {
        self.id = id
        self.emoji = emoji
        self.headline = headline
        self.body = body
    }
}

/// Wellness tip rule engine: pure logic (input snapshot → tip + new state), easy to unit-test.
/// Rules: continuous activity over a threshold (then at most once per hour), too many concurrent
/// sessions (4h cooldown), tasks still running late at night (once per night). Copy is picked
/// randomly from a pool (injected index keeps it testable).
public enum WellnessAdvisor {
    public struct State: Equatable, Sendable {
        public var lastDurationRemindAt: Date?
        public var lastSessionsRemindAt: Date?
        /// "Night key" of the last late-night reminder (day ordinal counted from 18:00 that
        /// evening)
        public var lastNightKey: Int?

        public init(
            lastDurationRemindAt: Date? = nil,
            lastSessionsRemindAt: Date? = nil,
            lastNightKey: Int? = nil
        ) {
            self.lastDurationRemindAt = lastDurationRemindAt
            self.lastSessionsRemindAt = lastSessionsRemindAt
            self.lastNightKey = lastNightKey
        }
    }

    public struct Input {
        public var now: Date
        /// Start of the current continuous-activity stretch (nil when no task is active)
        public var streakStartAt: Date?
        /// Number of running/waiting tasks
        public var activeSessionCount: Int
        /// Total live sessions, including idle ones
        public var aliveSessionCount: Int
        public var thresholdSeconds: TimeInterval
        public var enabled: Bool

        public init(
            now: Date, streakStartAt: Date?,
            activeSessionCount: Int, aliveSessionCount: Int,
            thresholdSeconds: TimeInterval = 2 * 3600,
            enabled: Bool = true
        ) {
            self.now = now
            self.streakStartAt = streakStartAt
            self.activeSessionCount = activeSessionCount
            self.aliveSessionCount = aliveSessionCount
            self.thresholdSeconds = thresholdSeconds
            self.enabled = enabled
        }
    }

    /// Concurrent-session reminder threshold and cooldown
    static let sessionsThreshold = 5
    static let sessionsCooldown: TimeInterval = 4 * 3600
    /// Repeat interval of the duration reminder
    static let durationRepeat: TimeInterval = 3600

    public static func evaluate(
        _ input: Input, state: State,
        calendar: Calendar = .current,
        pick: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> (notices: [IslandNotice], state: State) {
        guard input.enabled else { return ([], state) }
        var state = state
        var notices: [IslandNotice] = []

        // 1) Active continuously for too long
        if let start = input.streakStartAt {
            let streak = input.now.timeIntervalSince(start)
            let sinceLast = state.lastDurationRemindAt.map {
                input.now.timeIntervalSince($0)
            } ?? .infinity
            if streak >= input.thresholdSeconds && sinceLast >= durationRepeat {
                state.lastDurationRemindAt = input.now
                let hours = streak / 3600
                let display = hours >= 1.95
                    ? L10n.format("%@ hours", zhHans: "%@ 小时", String(Int(hours.rounded())))
                    : L10n.format("%@ hours", zhHans: "%@ 小时", String(format: "%.1f", hours))
                let pool = [
                    ("🧘", L10n.format("You've been vibe coding for %@", zhHans: "连续 vibe coding %@ 了", display),
                     L10n.text("Stand up, stretch, and drink some water—I'll keep an eye on your tasks.", zhHans: "站起来伸个懒腰、喝口水吧——任务有我盯着。")),
                    ("🌿", L10n.format("You've been focused for %@", zhHans: "已经专注 %@", display),
                     L10n.text("Look away from the screen for 20 seconds and focus on something distant. Your agent is running smoothly.", zhHans: "眼睛离开屏幕 20 秒，看看远处，agent 跑得很稳。")),
                    ("☕️", L10n.format("You've gone %@ without a break", zhHans: "%@没停了", display),
                     L10n.text("Time to refill your water or coffee? Your task results may be ready when you're back.", zhHans: "去续杯水或咖啡？回来正好收割任务结果。")),
                ]
                let chosen = pool[pick(pool.count) % pool.count]
                notices.append(IslandNotice(
                    id: "duration-\(Int(input.now.timeIntervalSince1970))",
                    emoji: chosen.0, headline: chosen.1, body: chosen.2))
            }
        } else {
            // Took a break; the next continuous stretch counts from scratch
            state.lastDurationRemindAt = nil
        }

        // 2) Too many concurrent sessions
        if input.aliveSessionCount >= sessionsThreshold {
            let sinceLast = state.lastSessionsRemindAt.map {
                input.now.timeIntervalSince($0)
            } ?? .infinity
            if sinceLast >= sessionsCooldown {
                state.lastSessionsRemindAt = input.now
                notices.append(IslandNotice(
                    id: "sessions-\(Int(input.now.timeIntervalSince1970))",
                    emoji: "🤹",
                    headline: L10n.format("You have %@ sessions open at once", zhHans: "同时开着 %@ 个会话", String(input.aliveSessionCount)),
                    body: L10n.text("Context switching takes effort too—wrap up one or two sessions to make things easier.", zhHans: "上下文切换也是有成本的——挑一两个收个尾，会更轻松。")))
            }
        }

        // 3) Still running late at night (23:00 - 06:00, once per night)
        let hour = calendar.component(.hour, from: input.now)
        if (hour >= 23 || hour < 6) && input.activeSessionCount > 0 {
            // Night key: fold "tonight" into one key (early morning counts as the previous night)
            let nightAnchor = input.now.addingTimeInterval(-6 * 3600)
            let nightKey = Int(nightAnchor.timeIntervalSince1970 / 86400)
            if state.lastNightKey != nightKey {
                state.lastNightKey = nightKey
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                notices.append(IslandNotice(
                    id: "night-\(nightKey)",
                    emoji: "🌙",
                    headline: L10n.format("It's already %@", zhHans: "已经 %@ 了", formatter.string(from: input.now)),
                    body: L10n.text("You've made great progress today. Leave the long tasks running and pick up the rest tomorrow?", zhHans: "今天的进度已经很棒。长任务挂着就好，剩下的明天再说？")))
            }
        }

        return (notices, state)
    }
}
