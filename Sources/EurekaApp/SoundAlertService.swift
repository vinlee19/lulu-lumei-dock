import AppKit
import EurekaKit

/// Sound alerts: one sound per island card, chosen by event category.
///
/// Whether to ring is decided by the caller with the card's rules (no card, no sound; waiting for
/// permission always rings; stale events never ring). This class only handles the master toggle,
/// the sound chosen per category, and throttling. `NSSound` also works under `swift run`, unlike
/// system notifications, which need an .app bundle.
@MainActor
final class SoundAlertService {
    private let settings: AppSettings
    private var throttle = SoundThrottle()

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Returns whether this event has a sound (rang now, or covered by the previous one). System
    /// notifications use it to drop their default sound, so one event rings once
    @discardableResult
    func play(_ cue: SoundCue) -> Bool {
        guard settings.soundAlertsEnabled,
              let name = settings.soundName(for: cue),
              SoundPlayer.exists(name) else { return false }
        switch throttle.decide(cue, at: Date()) {
        case .play:
            let started = SoundPlayer.play(name, volume: settings.soundVolume)
            log("提示音 \(cue.rawValue) → \(name)\(started ? "" : " (播放失败)")")
        case .covered:
            log("提示音 \(cue.rawValue) 被上一声覆盖")
        }
        return true
    }

    /// Dev-mode observability: one stdout line, same format as AppDelegate.logLine
    private func log(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}

/// Plays macOS alert sounds; the settings page preview uses it too
@MainActor
enum SoundPlayer {
    /// Same lookup directories as `NSSound(named:)` (user directory first)
    static let directories: [URL] = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
        URL(fileURLWithPath: "/Library/Sounds"),
        URL(fileURLWithPath: "/System/Library/Sounds"),
    ]
    private static let extensions: Set<String> = ["aiff", "aif", "wav", "mp3", "m4a", "caf"]

    /// The sound currently playing: stopped before the next one starts so sounds don't overlap
    private static var current: NSSound?

    static func exists(_ name: String) -> Bool {
        NSSound(named: NSSound.Name(name)) != nil
    }

    /// Returns whether playback actually started
    @discardableResult
    static func play(_ name: String, volume: Double) -> Bool {
        guard let sound = NSSound(named: NSSound.Name(name)) else { return false }
        current?.stop()
        // NSSound(named:) returns a shared instance; play() on one that is still playing returns false
        sound.stop()
        sound.volume = Float(min(max(volume, 0), 1))
        current = sound
        return sound.play()
    }

    /// Selectable sound names: audio files in the three directories, extension removed,
    /// de-duplicated and sorted by name
    static func availableSounds() -> [String] {
        var names = Set<String>()
        for directory in directories {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where extensions.contains(file.pathExtension.lowercased()) {
                names.insert(file.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
