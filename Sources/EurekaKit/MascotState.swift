import Foundation

/// Desktop mascot state (= the set of states an animation pack must support)
public enum MascotState: String, Sendable, CaseIterable {
    /// Base states (derived from the current snapshot, loop playback)
    case idle, working, waiting, sleeping, night
    /// Transient states (layered on by events; play for a while, then fall back to the base
    /// state)
    case success, error, relax
    case poke, wake  // phase-two interaction states

    /// Fallback chain when artwork is missing (ends at idle)
    public var fallback: MascotState {
        switch self {
        case .idle: return .idle
        case .working, .waiting, .sleeping: return .idle
        case .night: return .sleeping
        case .success, .error, .relax: return .working
        case .poke, .wake: return .idle
        }
    }
}

/// How a mascot sequence plays. Base states loop; transient states such as finish/click/wake
/// may play once and hold the last frame.
public enum MascotPlaybackMode: String, Sendable, Equatable {
    case loop
    case onceHoldLast

    /// Returns the frame index for the local playback time. Pure function shared by the
    /// renderer and unit tests.
    public func frameIndex(elapsed: TimeInterval, fps: Double, frameCount: Int) -> Int {
        guard frameCount > 1 else { return 0 }
        let safeElapsed = max(0, elapsed)
        let safeFPS = max(0.1, fps)
        let raw = Int(floor(safeElapsed * safeFPS))
        switch self {
        case .loop:
            return raw % frameCount
        case .onceHoldLast:
            return min(raw, frameCount - 1)
        }
    }
}

/// Logical grid of a sprite sheet. The app layer reads the image size; this only handles safe
/// cell bounds.
public struct MascotSpriteGrid: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public func contains(row: Int, column: Int) -> Bool {
        (0..<rows).contains(row) && (0..<columns).contains(column)
    }
}

/// Frame-by-frame refresh should only run while the panel is visible and the system is awake.
public enum MascotAnimationPolicy {
    public static func shouldAnimate(isVisible: Bool, isAwake: Bool) -> Bool {
        isVisible && isAwake
    }
}

/// Base state derivation (pure function, easy to unit-test). Transient states
/// (success/error/relax/poke/wake) are layered on by the ViewModel per event.
public enum MascotBaseResolver {
    public struct Input {
        public var hasWaitingTask: Bool
        public var hasRunningTask: Bool
        /// Seconds since last activity (0 when there are active tasks)
        public var idleSeconds: TimeInterval
        /// .infinity = never fall asleep from idleness
        public var sleepThreshold: TimeInterval
        /// Off = the late-night hours behave like daytime (no drowsy working, no forced sleep)
        public var nightMode: Bool
        public var now: Date

        public init(
            hasWaitingTask: Bool, hasRunningTask: Bool,
            idleSeconds: TimeInterval, sleepThreshold: TimeInterval = 60,
            nightMode: Bool = true, now: Date
        ) {
            self.hasWaitingTask = hasWaitingTask
            self.hasRunningTask = hasRunningTask
            self.idleSeconds = idleSeconds
            self.sleepThreshold = sleepThreshold
            self.nightMode = nightMode
            self.now = now
        }
    }

    /// Late-night window shared by the night state and the companion settings copy
    public static let nightHours = (start: 23, end: 6)

    public static func isDeepNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= nightHours.start || hour < nightHours.end
    }

    /// Priority: waiting on you > (running late at night → sleepy / otherwise focused) > long
    /// idle or late night with no tasks → asleep > calm
    public static func base(_ input: Input, calendar: Calendar = .current) -> MascotState {
        if input.hasWaitingTask { return .waiting }
        let deepNight = input.nightMode && isDeepNight(input.now, calendar: calendar)
        if input.hasRunningTask {
            return deepNight ? .night : .working
        }
        // No active tasks
        if input.idleSeconds >= input.sleepThreshold || deepNight {
            return .sleeping
        }
        return .idle
    }
}
