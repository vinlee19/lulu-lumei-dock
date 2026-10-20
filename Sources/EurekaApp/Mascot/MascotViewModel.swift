import AppKit
import EurekaKit
import Foundation
import SwiftUI

/// Mascot presentation state machine: the base state derives from snapshots; transient states
/// (finished / error / wellness) overlay on events and fall back on a timer.
@MainActor
final class MascotViewModel: ObservableObject {
    @Published private(set) var state: MascotState = .idle
    @Published private(set) var bubble: String?
    @Published private(set) var pack: MascotPack
    /// Current behavior variant id. A change makes the view switch assets.
    @Published private(set) var variantID = ""
    /// Clockwise gaze 0...15; nil means back to plain idle.
    @Published private(set) var lookDirection: Int?
    /// Incremented each time a sequence replays, so transient moves start from frame 0.
    @Published private(set) var playbackTick = 0
    /// +1 on state change, making the view play one "big move" transition (spin / hop / flip, etc.)
    @Published private(set) var transitionTick = 0
    /// Current transition style (chosen on each change, read by the view)
    private(set) var transitionStyle: MascotTransition = .pop

    /// .infinity = never fall asleep from idleness
    var idleSleepSeconds: TimeInterval = 300 {
        didSet { if ticker != nil { recompute() } }
    }
    /// Off = late-night hours behave like daytime
    var nightMode = true {
        didSet { if ticker != nil { recompute() } }
    }
    /// Off = finish / error / wellness events still animate, but without a speech bubble
    var showsBubbles = true
    /// Card scale picked in Settings (1 = the original 132pt card)
    @Published var cardScale: CGFloat = 1
    /// A Settings preview is playing: pointer movement must not wake it out of "sleeping"
    var isPreviewing: Bool {
        guard previewing, let until = transientUntil else { return false }
        return until > Date()
    }
    private var previewing = false

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
        // When the companion is first enabled, show awake idle; "never recorded any activity" must
        // not be treated as infinite idleness.
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
        playbackTick &+= 1
    }

    /// English word-art caption for the current state
    var caption: String? {
        // Gaze tracking is a continuous micro-interaction; keep the frame clean instead of carrying
        // old sticker captions on every head turn.
        if state == .idle, lookDirection != nil { return nil }
        if let currentVariant { return currentVariant.caption }
        return pack.captions[state]
    }

    /// Current animation (changes with state / pack / behavior variant / gaze)
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

    var playbackMode: MascotPlaybackMode {
        if state == .idle, lookDirection != nil { return .loop }
        return currentVariant?.playback ?? .loop
    }

    func variantCount(for state: MascotState) -> Int {
        pack.variants(for: state).count
    }

    // MARK: - Input

    func updateActiveTasks(active: [AgentTask], idle: [AgentTask]) {
        hasRunning = !active.isEmpty
        hasWaiting = active.contains {
            if case .waiting = $0.phase { return true } else { return false }
        }
        if !active.isEmpty { lastActiveAt = Date() }
        recompute()
    }

    /// Settings "Preview": acts out one state on the real companion for a few seconds
    func preview(_ state: MascotState) {
        lastActiveAt = Date()
        pushTransient(state, bubble: nil, seconds: 3)
        previewing = true
    }

    func showFinished(success: Bool) {
        pushTransient(success ? .success : .error,
                      bubble: success ? L10n.text("All done 🎉", zhHans: "搞定啦 🎉") : L10n.text("Something went wrong 😣", zhHans: "出错了 😣"), seconds: 2.5)
    }

    /// Wellness nudge: reuses WellnessAdvisor's copy; late at night enters the drowsy state,
    /// otherwise the relax state
    func showNotice(_ headline: String) {
        let deepNight = nightMode && MascotBaseResolver.isDeepNight(Date())
        pushTransient(deepNight ? .night : .relax, bubble: headline, seconds: 6)
    }

    /// Clicked → playful reaction (a bounce/spin + brief bubble)
    func poke() {
        pushTransient(.poke, bubble: nil, seconds: 1.2)
    }

    /// User returns while asleep → play the wake-up move first, then restart timing from awake
    /// idle.
    func wake() {
        lastActiveAt = Date()
        pushTransient(.wake, bubble: nil, seconds: 1.5)
    }

    /// The panel controller maps the mouse's relative direction to the 16-direction gaze; up close
    /// or when not idle, back to the plain pose.
    func setLookDirection(_ direction: Int?) {
        let normalized = direction.map { (($0 % 16) + 16) % 16 }
        // Packs without gaze assets (single uploaded images, etc.) don't enter gaze mode; otherwise
        // the captions and motion freeze when the mouse comes near.
        let next = state == .idle && !pack.lookDirections.isEmpty ? normalized : nil
        if lookDirection != next { lookDirection = next }
    }

    // MARK: - Internal

    private func pushTransient(_ state: MascotState, bubble: String?, seconds: TimeInterval) {
        let replaySameState = self.state == state
        previewing = false
        transientState = state
        transientUntil = Date().addingTimeInterval(seconds)
        pendingBubble = showsBubbles ? bubble : nil
        apply()
        // Repeated finishes/clicks also pick a different performance and retrigger the transition
        // and frame sequence.
        if replaySameState {
            transitionStyle = MascotTransition.choose(
                from: self.state, to: state, tick: transitionTick)
            transitionTick &+= 1
            selectVariant(force: true)
            playbackTick &+= 1
        }
    }

    private func recompute() {
        let idleSeconds = lastActiveAt.map { Date().timeIntervalSince($0) }
            ?? .greatestFiniteMagnitude
        baseState = MascotBaseResolver.base(.init(
            hasWaitingTask: hasWaiting,
            hasRunningTask: hasRunning,
            idleSeconds: (hasRunning || hasWaiting) ? 0 : idleSeconds,
            sleepThreshold: idleSleepSeconds,
            nightMode: nightMode,
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
            previewing = false
            newState = baseState
            newBubble = nil
        }
        let stateChanged = newState != state
        // State really changed → pick a big transition move and trigger it
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
            playbackTick &+= 1
        }
        updateVariantRotation()
    }

    /// High-frequency states rotate naturally among variants so long tasks don't repeat the same
    /// sticker.
    private func updateVariantRotation() {
        let variants = pack.variants(for: state)
        guard [.idle, .working, .waiting, .sleeping, .night].contains(state),
              variants.count > 1
        else {
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
            playbackTick &+= 1
            nextVariantSwitchAt = now.addingTimeInterval(nextVariantInterval())
        }
    }

    private func nextVariantInterval() -> TimeInterval {
        switch state {
        case .idle: return Double.random(in: 7...13)
        case .working: return Double.random(in: 10...18)
        case .waiting: return Double.random(in: 5...9)
        case .sleeping: return Double.random(in: 18...30)
        case .night: return Double.random(in: 14...24)
        default: return 30
        }
    }

    /// Weighted random choice, avoiding back-to-back repeats when other candidates exist.
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

/// "Big move" transition played once on state change. Phase sequence [0,1,2,3] (phase 0 / the last
/// phase are at rest).
enum MascotTransition {
    case pop, spin, jump, flip, jumpSpin, shake, bounce, settle

    struct Pose: Equatable {
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotation: Double = 0   // 2D z axis (degrees)
        var flip: Double = 0       // 3D y-axis flip (degrees)
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
        if phase == 0 { return nil }  // No animation at the reset instant
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
