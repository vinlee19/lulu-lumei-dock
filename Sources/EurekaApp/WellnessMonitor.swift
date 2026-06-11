import EurekaKit
import Foundation

/// 健康提示监控：每 5 分钟采样一次活跃状态，维护"连续活跃段"，
/// 交给 WellnessAdvisor（纯规则）评估，产出的关怀卡进灵动岛队列。
@MainActor
final class WellnessMonitor {
    /// 活跃中断超过这个间隔视为歇过了，连续段重新计
    private let streakGap: TimeInterval = 30 * 60
    private let sampleInterval: TimeInterval = 5 * 60

    private var streakStartAt: Date?
    private var lastActiveAt: Date?
    private var advisorState = WellnessAdvisor.State()
    private var timer: Timer?

    private let settings: AppSettings
    private let store: TaskStore
    private let emit: (IslandNotice) -> Void

    init(settings: AppSettings, store: TaskStore, emit: @escaping (IslandNotice) -> Void) {
        self.settings = settings
        self.store = store
        self.emit = emit
    }

    func start() {
        timer = Timer.scheduledTimer(
            withTimeInterval: sampleInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        // 演示钩子：defaults write com.vinlee.eureka wellnessDemo -bool true
        // → 下次启动 8 秒后弹一张样例关怀卡（看效果用，弹完自动清除标记）
        if UserDefaults.standard.bool(forKey: "wellnessDemo") {
            UserDefaults.standard.removeObject(forKey: "wellnessDemo")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated { [weak self] in
                    self?.emit(IslandNotice(
                        id: "demo",
                        emoji: "🧘",
                        headline: "连续 vibe coding 2 小时了",
                        body: "站起来伸个懒腰、喝口水吧——任务有我盯着。"))
                }
            }
        }
    }

    func sample(now: Date = Date()) {
        let isActive = !store.sortedActiveTasks.isEmpty
        if isActive {
            if let last = lastActiveAt, now.timeIntervalSince(last) > streakGap {
                streakStartAt = now  // 歇够了，重新起段
            } else if streakStartAt == nil {
                streakStartAt = now
            }
            lastActiveAt = now
        } else if let last = lastActiveAt, now.timeIntervalSince(last) > streakGap {
            streakStartAt = nil
            lastActiveAt = nil
        }

        let input = WellnessAdvisor.Input(
            now: now,
            streakStartAt: streakStartAt,
            activeSessionCount: store.sortedActiveTasks.count,
            aliveSessionCount: store.sortedActiveTasks.count + store.sortedIdleTasks.count,
            thresholdSeconds: settings.wellnessThresholdHours * 3600,
            enabled: settings.wellnessEnabled
        )
        let result = WellnessAdvisor.evaluate(input, state: advisorState)
        advisorState = result.state
        for notice in result.notices {
            emit(notice)
        }
    }
}
