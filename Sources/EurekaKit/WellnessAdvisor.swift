import Foundation

/// 灵动岛关怀卡内容
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

/// 健康提示规则引擎：纯逻辑（输入快照 → 提示 + 新状态），便于单测。
/// 规则：连续活跃超阈值（之后每小时最多一次）、并发会话过多（4h 冷却）、
/// 深夜还在跑任务（每晚一次）。文案按池随机（注入索引保证可测）。
public enum WellnessAdvisor {
    public struct State: Equatable, Sendable {
        public var lastDurationRemindAt: Date?
        public var lastSessionsRemindAt: Date?
        /// 上次深夜提醒的"夜晚标识"（当晚 18:00 起算的天序数）
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
        /// 当前连续活跃段的起点（无活跃任务时为 nil）
        public var streakStartAt: Date?
        /// 运行/等待中的任务数
        public var activeSessionCount: Int
        /// 含空闲的存活会话总数
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

    /// 并发会话提醒阈值与冷却
    static let sessionsThreshold = 5
    static let sessionsCooldown: TimeInterval = 4 * 3600
    /// 时长提醒的重复间隔
    static let durationRepeat: TimeInterval = 3600

    public static func evaluate(
        _ input: Input, state: State,
        calendar: Calendar = .current,
        pick: (Int) -> Int = { Int.random(in: 0..<$0) }
    ) -> (notices: [IslandNotice], state: State) {
        guard input.enabled else { return ([], state) }
        var state = state
        var notices: [IslandNotice] = []

        // 1) 连续活跃过久
        if let start = input.streakStartAt {
            let streak = input.now.timeIntervalSince(start)
            let sinceLast = state.lastDurationRemindAt.map {
                input.now.timeIntervalSince($0)
            } ?? .infinity
            if streak >= input.thresholdSeconds && sinceLast >= durationRepeat {
                state.lastDurationRemindAt = input.now
                let hours = streak / 3600
                let display = hours >= 1.95
                    ? "\(Int(hours.rounded())) 小时"
                    : String(format: "%.1f 小时", hours)
                let pool = [
                    ("🧘", "连续 vibe coding \(display) 了", "站起来伸个懒腰、喝口水吧——任务有我盯着。"),
                    ("🌿", "已经专注 \(display)", "眼睛离开屏幕 20 秒，看看远处，agent 跑得很稳。"),
                    ("☕️", "\(display)没停了", "去续杯水或咖啡？回来正好收割任务结果。"),
                ]
                let chosen = pool[pick(pool.count) % pool.count]
                notices.append(IslandNotice(
                    id: "duration-\(Int(input.now.timeIntervalSince1970))",
                    emoji: chosen.0, headline: chosen.1, body: chosen.2))
            }
        } else {
            // 歇下来了，下个连续段重新计
            state.lastDurationRemindAt = nil
        }

        // 2) 并发会话过多
        if input.aliveSessionCount >= sessionsThreshold {
            let sinceLast = state.lastSessionsRemindAt.map {
                input.now.timeIntervalSince($0)
            } ?? .infinity
            if sinceLast >= sessionsCooldown {
                state.lastSessionsRemindAt = input.now
                notices.append(IslandNotice(
                    id: "sessions-\(Int(input.now.timeIntervalSince1970))",
                    emoji: "🤹",
                    headline: "同时开着 \(input.aliveSessionCount) 个会话",
                    body: "上下文切换也是有成本的——挑一两个收个尾，会更轻松。"))
            }
        }

        // 3) 深夜还在跑（23:00 - 06:00，每晚一次）
        let hour = calendar.component(.hour, from: input.now)
        if (hour >= 23 || hour < 6) && input.activeSessionCount > 0 {
            // 夜晚标识：把"当晚"折算成同一个 key（凌晨归前一晚）
            let nightAnchor = input.now.addingTimeInterval(-6 * 3600)
            let nightKey = Int(nightAnchor.timeIntervalSince1970 / 86400)
            if state.lastNightKey != nightKey {
                state.lastNightKey = nightKey
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                notices.append(IslandNotice(
                    id: "night-\(nightKey)",
                    emoji: "🌙",
                    headline: "已经 \(formatter.string(from: input.now)) 了",
                    body: "今天的进度已经很棒。长任务挂着就好，剩下的明天再说？"))
            }
        }

        return (notices, state)
    }
}
