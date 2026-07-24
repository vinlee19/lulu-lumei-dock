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
    /// 当前行为变体 id。变化时驱动视图切换素材。
    @Published private(set) var variantID = ""
    /// 0...15 顺时针视线；nil 表示回到普通 idle。
    @Published private(set) var lookDirection: Int?
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
    private var currentVariant: MascotVariant?
    private var nextVariantSwitchAt: Date?

    init(pack: MascotPack) {
        self.pack = pack
        currentVariant = pack.variants(for: .idle).first
        variantID = currentVariant?.id ?? ""
    }

    func start() {
        // 首次开启伙伴时先展示清醒 idle；不能把“从未记录过活跃”当成无限空闲。
        if lastActiveAt == nil { lastActiveAt = Date() }
        ticker = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recompute() }
        }
        recompute()
    }

    func setPack(_ pack: MascotPack) {
        self.pack = pack
        currentVariant = pack.variants(for: state).first
        variantID = currentVariant?.id ?? ""
        lookDirection = nil
        nextVariantSwitchAt = nil
    }

    /// 当前状态的英文艺术字标语
    var caption: String? {
        // 视线追踪是连续微交互，保持画面干净，避免每次转头都带着旧贴纸文案。
        if state == .idle, lookDirection != nil { return nil }
        if let currentVariant { return currentVariant.caption }
        return pack.captions[state]
    }

    /// 当前动画(随 state/pack/行为变体/视线 变)
    var animation: MascotAnimation? {
        if state == .idle, let lookDirection,
           let look = pack.lookAnimation(direction: lookDirection) {
            return look
        }
        return currentVariant?.animation ?? pack.animation(for: state)
    }

    var motionProfile: MascotMotionProfile {
        if state == .idle, lookDirection != nil { return .still }
        return currentVariant?.motion ?? .stateDefault
    }

    func variantCount(for state: MascotState) -> Int {
        pack.variants(for: state).count
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

    /// 睡眠时检测到用户回来 → 先播放醒来动作，再从清醒 idle 重新计时。
    func wake() {
        lastActiveAt = Date()
        pushTransient(.wake, bubble: nil, seconds: 1.5)
    }

    /// 面板控制器把鼠标相对方向映射到 16 向视线；近距离或非 idle 时回到普通姿势。
    func setLookDirection(_ direction: Int?) {
        let normalized = direction.map { (($0 % 16) + 16) % 16 }
        let next = state == .idle ? normalized : nil
        if lookDirection != next { lookDirection = next }
    }

    // MARK: - 内部

    private func pushTransient(_ state: MascotState, bubble: String?, seconds: TimeInterval) {
        let replaySameState = self.state == state
        transientState = state
        transientUntil = Date().addingTimeInterval(seconds)
        pendingBubble = bubble
        apply()
        // 连续完成/点击时也换一个表演，不重复播放完全相同的片段。
        if replaySameState { selectVariant(force: true) }
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
        let stateChanged = newState != state
        // 状态真正改变 → 选一个过场大动作并触发
        if stateChanged {
            transitionStyle = MascotTransition.choose(from: state, to: newState, tick: transitionTick)
            transitionTick &+= 1
        }
        state = newState
        bubble = newBubble
        if state != .idle { lookDirection = nil }
        if stateChanged {
            nextVariantSwitchAt = nil
            selectVariant(force: true)
        }
        updateVariantRotation()
    }

    /// 高频态会在多个变体间自然轮换，避免长任务一直重复同一张贴纸。
    private func updateVariantRotation() {
        let variants = pack.variants(for: state)
        guard [.idle, .working, .waiting].contains(state), variants.count > 1 else {
            nextVariantSwitchAt = nil
            return
        }
        let now = Date()
        guard let next = nextVariantSwitchAt else {
            nextVariantSwitchAt = now.addingTimeInterval(nextVariantInterval())
            return
        }
        if now >= next {
            selectVariant(force: true)
            nextVariantSwitchAt = now.addingTimeInterval(nextVariantInterval())
        }
    }

    private func nextVariantInterval() -> TimeInterval {
        switch state {
        case .idle: return Double.random(in: 7...13)
        case .working: return Double.random(in: 10...18)
        case .waiting: return Double.random(in: 5...9)
        default: return 30
        }
    }

    /// 按权重随机选择，并在有其他候选时避免连续重复。
    private func selectVariant(force: Bool) {
        var candidates = pack.variants(for: state)
        guard !candidates.isEmpty else {
            currentVariant = nil
            variantID = ""
            return
        }
        if force, candidates.count > 1, let currentVariant {
            let withoutCurrent = candidates.filter { $0.id != currentVariant.id }
            if !withoutCurrent.isEmpty { candidates = withoutCurrent }
        }
        let total = candidates.reduce(0) { $0 + max(1, $1.weight) }
        var ticket = Int.random(in: 0..<max(1, total))
        var selected = candidates[0]
        for candidate in candidates {
            ticket -= max(1, candidate.weight)
            if ticket < 0 {
                selected = candidate
                break
            }
        }
        currentVariant = selected
        variantID = selected.id
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
        case .success: return .jump
        case .error: return .shake
        case .waiting: return .bounce
        case .sleeping, .night: return .settle
        case .poke: return [MascotTransition.jump, .bounce, .pop][abs(tick) % 3]
        default: return .pop
        }
    }
}
