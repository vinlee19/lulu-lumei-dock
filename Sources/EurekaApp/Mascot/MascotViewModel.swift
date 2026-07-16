import AppKit
import EurekaKit
import Foundation
import SwiftUI

/// 吉祥物展示状态机:基础态由快照推导,瞬时态(完成/出错/关怀)按事件叠加、计时回落。
@MainActor
final class MascotViewModel: ObservableObject {
    @Published private(set) var state: MascotState = .idle
    @Published private(set) var bubble: String?
    @Published private(set) var pack: MascotPack
    /// 空闲姿势轮换下标(idle 久了在多个姿势间随机切)
    @Published private(set) var idlePoseIndex = 0
    /// 状态切换时 +1,驱动视图播放一次"大动作"过场(旋转/跳/翻等)
    @Published private(set) var transitionTick = 0
    /// 当前过场风格(每次切换选定,视图读取)
    private(set) var transitionStyle: MascotTransition = .pop

    var idleSleepSeconds: TimeInterval = 60

    private var baseState: MascotState = .idle
    private var transientState: MascotState?
    private var transientUntil: Date?
    private var pendingBubble: String?
    private var lastActiveAt: Date?
    private var hasRunning = false
    private var hasWaiting = false
    private var ticker: Timer?
    private var nextIdleSwitchAt: Date?

    init(pack: MascotPack) {
        self.pack = pack
    }

    func start() {
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        recompute()
    }

    func setPack(_ pack: MascotPack) {
        self.pack = pack
        idlePoseIndex = 0
        nextIdleSwitchAt = nil
    }

    /// 当前状态的英文艺术字标语
    var caption: String? {
        pack.captions[state]
    }

    /// 当前动画(随 state/pack/空闲轮换 变)
    var animation: MascotAnimation? {
        if state == .idle {
            let poses = pack.idlePoses
            if poses.count > 1 { return poses[idlePoseIndex % poses.count] }
        }
        return pack.animation(for: state)
    }

    // MARK: - 输入

    func updateActiveTasks(active: [AgentTask], idle: [AgentTask]) {
        hasRunning = !active.isEmpty
        hasWaiting = active.contains {
            if case .waiting = $0.phase { return true } else { return false }
        }
        if !active.isEmpty { lastActiveAt = Date() }
        recompute()
    }

    func showFinished(success: Bool) {
        pushTransient(success ? .success : .error,
                      bubble: success ? "搞定啦 🎉" : "出错了 😣", seconds: 2.5)
    }

    /// 关怀提示:复用 WellnessAdvisor 的文案;深夜进困倦态,否则放松态
    func showNotice(_ headline: String) {
        let hour = Calendar.current.component(.hour, from: Date())
        let deepNight = hour >= 23 || hour < 6
        pushTransient(deepNight ? .night : .relax, bubble: headline, seconds: 6)
    }

    /// 被点击 → 俏皮反应(蹦/转一下 + 短暂气泡)
    func poke() {
        pushTransient(.poke, bubble: nil, seconds: 1.2)
    }

    // MARK: - 内部

    private func pushTransient(_ state: MascotState, bubble: String?, seconds: TimeInterval) {
        transientState = state
        transientUntil = Date().addingTimeInterval(seconds)
        pendingBubble = bubble
        apply()
    }

    private func recompute() {
        let idleSeconds = lastActiveAt.map { Date().timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        baseState = MascotBaseResolver.base(.init(
            hasWaitingTask: hasWaiting,
            hasRunningTask: hasRunning,
            idleSeconds: (hasRunning || hasWaiting) ? 0 : idleSeconds,
            sleepThreshold: idleSleepSeconds,
            now: Date()))
        apply()
    }

    private func apply() {
        let newState: MascotState
        let newBubble: String?
        if let until = transientUntil, until > Date(), let transientState {
            newState = transientState
            newBubble = pendingBubble
        } else {
            transientState = nil
            transientUntil = nil
            pendingBubble = nil
            newState = baseState
            newBubble = nil
        }
        // 状态真正改变 → 选一个过场大动作并触发
        if newState != state {
            transitionStyle = MascotTransition.choose(from: state, to: newState, tick: transitionTick)
            transitionTick &+= 1
        }
        state = newState
        bubble = newBubble
        updateIdleRotation()
    }

    /// 空闲态每隔 10–18s 随机换个姿势;离开空闲则复位
    private func updateIdleRotation() {
        guard state == .idle, pack.idlePoses.count > 1 else {
            nextIdleSwitchAt = nil
            return
        }
        let now = Date()
        guard let next = nextIdleSwitchAt else {
            nextIdleSwitchAt = now.addingTimeInterval(Double.random(in: 10...18))
            return
        }
        if now >= next {
            idlePoseIndex = (idlePoseIndex + 1) % pack.idlePoses.count
            nextIdleSwitchAt = now.addingTimeInterval(Double.random(in: 10...18))
        }
    }
}

/// 状态切换时播放一次的"大动作"过场。phase 序列 [0,1,2,3](0/末相位为静止)。
enum MascotTransition {
    case pop, spin, jump, flip, jumpSpin, shake, bounce, settle

    struct Pose: Equatable {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0   // 2D z 轴(度)
        var flip: Double = 0       // 3D y 轴翻转(度)
        var yOffset: CGFloat = 0
    }

    func pose(phase: Int) -> Pose {
        switch self {
        case .pop:
            switch phase { case 1: return Pose(scaleX: 1.18, scaleY: 1.18)
                           case 2: return Pose(scaleX: 0.96, scaleY: 0.96); default: return Pose() }
        case .spin:
            switch phase { case 1: return Pose(scaleX: 1.05, scaleY: 1.05, rotation: 150)
                           case 2: return Pose(rotation: 300)
                           case 3: return Pose(rotation: 360); default: return Pose() }
        case .jump:
            switch phase { case 1: return Pose(scaleX: 0.94, scaleY: 1.12, yOffset: -30)
                           case 2: return Pose(scaleX: 1.08, scaleY: 0.92); default: return Pose() }
        case .flip:
            switch phase { case 1: return Pose(flip: 150); case 2: return Pose(flip: 300)
                           case 3: return Pose(flip: 360); default: return Pose() }
        case .jumpSpin:
            switch phase { case 1: return Pose(scaleX: 1.05, scaleY: 1.05, rotation: 150, yOffset: -34)
                           case 2: return Pose(rotation: 330)
                           case 3: return Pose(rotation: 360); default: return Pose() }
        case .shake:
            switch phase { case 1: return Pose(rotation: -13); case 2: return Pose(rotation: 12)
                           default: return Pose() }
        case .bounce:
            switch phase { case 1: return Pose(scaleX: 0.95, scaleY: 1.1, yOffset: -22)
                           case 2: return Pose(scaleX: 1.05, scaleY: 0.95, yOffset: -4)
                           default: return Pose() }
        case .settle:
            switch phase { case 1: return Pose(scaleX: 1.08, scaleY: 0.9)
                           case 2: return Pose(scaleX: 0.98, scaleY: 1.02); default: return Pose() }
        }
    }

    func animation(toPhase phase: Int) -> Animation? {
        if phase == 0 { return nil }  // 复位瞬间不做动画
        switch self {
        case .shake: return .easeInOut(duration: 0.09)
        case .spin, .flip, .jumpSpin: return .spring(response: 0.3, dampingFraction: 0.62)
        default: return .spring(response: 0.26, dampingFraction: 0.55)
        }
    }

    static func choose(from: MascotState, to: MascotState, tick: Int) -> MascotTransition {
        switch to {
        case .success: return .jumpSpin
        case .error: return .shake
        case .waiting: return .bounce
        case .sleeping, .night: return .settle
        case .poke: return [MascotTransition.jump, .spin, .bounce, .pop][abs(tick) % 4]
        default:
            let cycle: [MascotTransition] = [.spin, .jump, .flip, .pop]
            return cycle[abs(tick) % cycle.count]
        }
    }
}
