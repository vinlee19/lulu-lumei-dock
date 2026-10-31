import Foundation

/// Sound alert category: whichever card the island pops decides which sound plays.
///
/// Covers only the task's own states (finished / failed / interrupted / waiting for permission /
/// waiting for input / island question); audit alerts, limit warnings and wellness nudges stay
/// silent. A sound name is the alert file's base name; the app hands it to `NSSound(named:)`, which
/// looks in `~/Library/Sounds`, `/Library/Sounds` and `/System/Library/Sounds`.
public enum SoundCue: String, CaseIterable, Sendable {
    case completed
    case failed
    case interrupted
    case permission
    case input
    case question

    /// Settings page label
    public var label: String {
        switch self {
        case .completed: return L10n.text("Task finished", zhHans: "任务完成")
        case .failed: return L10n.text("Task failed", zhHans: "任务出错")
        case .interrupted: return L10n.text("Task interrupted", zhHans: "任务中断")
        case .permission: return L10n.text("Waiting for permission", zhHans: "等待权限确认")
        case .input: return L10n.text("Waiting for input", zhHans: "等待输入")
        case .question: return L10n.text("Island question", zhHans: "岛上提问")
        }
    }

    /// Default sound (built into macOS): a bright one for finished, a low one for failed, and a
    /// distinct one for each state that needs you
    public var defaultSound: String {
        switch self {
        case .completed: return "Glass"
        case .failed: return "Basso"
        case .interrupted: return "Funk"
        case .permission: return "Ping"
        case .input: return "Pop"
        case .question: return "Purr"
        }
    }

    /// Who wins when only one sound plays in a window: needs you > went wrong > ended normally
    public var priority: Int {
        switch self {
        case .permission: return 5
        case .question: return 4
        case .failed: return 3
        case .interrupted: return 2
        case .input: return 1
        case .completed: return 0
        }
    }

    public static func forFinished(_ outcome: TaskOutcome) -> SoundCue {
        switch outcome {
        case .success: return .completed
        case .error: return .failed
        case .interrupted: return .interrupted
        }
    }

    public static func forWaiting(_ reason: WaitReason) -> SoundCue {
        switch reason {
        case .permission: return .permission
        case .idle: return .input
        }
    }
}

/// Sound throttle: several sessions finishing together, or a question that also brings a
/// "waiting for permission", ring once.
///
/// Within `window` seconds of the last sound, a new event only rings if it has a higher priority
/// (cutting the previous one off); otherwise it counts as covered by the previous sound. Covered
/// events don't extend the window, so a steady stream of events still rings now and then.
public struct SoundThrottle: Equatable, Sendable {
    public static let window: TimeInterval = 1.5

    public enum Decision: Equatable, Sendable {
        /// Ring now
        case play
        /// The previous sound just rang; stay quiet
        case covered
    }

    private var lastCue: SoundCue?
    private var lastAt: Date?

    public init() {}

    public mutating func decide(_ cue: SoundCue, at now: Date) -> Decision {
        if let lastCue, let lastAt {
            let elapsed = now.timeIntervalSince(lastAt)
            if elapsed >= 0, elapsed < Self.window, cue.priority <= lastCue.priority {
                return .covered
            }
        }
        lastCue = cue
        lastAt = now
        return .play
    }
}
