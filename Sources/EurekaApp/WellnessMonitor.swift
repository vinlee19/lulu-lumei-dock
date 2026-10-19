import EurekaKit
import Foundation

/// Wellness monitor: samples activity every 5 minutes, maintains the "continuous active streak",
/// hands it to WellnessAdvisor (pure rules) for evaluation, and the resulting care cards go into
/// the Dynamic Island queue.
@MainActor
final class WellnessMonitor {
    /// An activity gap longer than this counts as a break, and the streak restarts
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
        // Demo hook: defaults write com.vinlee.eureka wellnessDemo -bool true
        // → a sample care card pops up 8 seconds after next launch (for previewing; the flag clears
        // itself afterwards)
        if UserDefaults.standard.bool(forKey: "wellnessDemo") {
            UserDefaults.standard.removeObject(forKey: "wellnessDemo")
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                MainActor.assumeIsolated { [weak self] in
                    self?.emit(IslandNotice(
                        id: "demo",
                        emoji: "🧘",
                        headline: L10n.text("You've been vibe coding for 2 hours", zhHans: "连续 vibe coding 2 小时了"),
                        body: L10n.text("Stand up, stretch, and have some water—I'll keep an eye on your tasks.", zhHans: "站起来伸个懒腰、喝口水吧——任务有我盯着。")))
                }
            }
        }
    }

    func sample(now: Date = Date()) {
        let isActive = !store.sortedActiveTasks.isEmpty
        if isActive {
            if let last = lastActiveAt, now.timeIntervalSince(last) > streakGap {
                streakStartAt = now  // rested enough, start a new streak
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
