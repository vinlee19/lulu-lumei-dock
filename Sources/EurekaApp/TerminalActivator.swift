import AppKit
import EurekaKit
import Foundation

/// Brings the terminal **app** a session runs in to the front.
///
/// Deliberately app-level only:
/// - No AppleScript / Apple Events → no "Automation" permission prompt
/// - No reading the accessibility tree → no Accessibility permission needed
///
/// The cost is that a specific tab can't be selected: with multiple tabs it can only bring the terminal app forward, and you still find the tab yourself.
/// Tab-level would need a separate implementation per terminal (iTerm by session GUID, Terminal by tty, others each have a CLI)
/// plus collecting `ITERM_SESSION_ID` / `KITTY_WINDOW_ID` -- left for later, see the plan's "explicitly out of scope".
enum TerminalActivator {
    /// Whether the binding's terminal app is currently running. Used to grey out the jump button
    /// instead of having it do nothing when clicked.
    static func isRunning(_ binding: TerminalBinding) -> Bool {
        resolve(binding) != nil
    }

    /// Whether the terminal **app** this session runs in is currently frontmost.
    ///
    /// **App-level only** -- it can't tell which tab. So the caller (smart mute) must assume: with
    /// 5 iTerm tabs open and any one of them frontmost, this returns true. Tab-level detection
    /// needs AppleScript / the accessibility tree, see the plan's "explicitly out of scope".
    static func isFrontmost(_ binding: TerminalBinding) -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let bundleId = binding.bundleId, !bundleId.isEmpty {
            // Bundle id only: Warp's TERM_PROGRAM falsely reports Apple_Terminal, so falling back
            // to name matching would misjudge "Terminal is frontmost" as "Warp is frontmost"
            return front.bundleIdentifier == bundleId
        }
        guard let app = binding.app, !app.isEmpty, let name = front.localizedName else {
            return false
        }
        return normalized(name) == normalized(app)
    }

    /// Activates the terminal app; returns true on success. App exited / unrecognized → false, and
    /// the caller shows a hint accordingly.
    @discardableResult
    static func activate(_ binding: TerminalBinding) -> Bool {
        guard let app = resolve(binding) else { return false }
        if app.isHidden { app.unhide() }
        return app.activate(options: [])
    }

    /// Finds the running terminal app from the binding. Prefers bundle id (exact), falling back to
    /// TERM_PROGRAM name matching.
    private static func resolve(_ binding: TerminalBinding) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let bundleId = binding.bundleId, !bundleId.isEmpty {
            // Bundle id is exact and reliable: use it on a hit, with no further fallback (Warp's
            // TERM_PROGRAM falsely reports Apple_Terminal, so fallback matching would pick the
            // wrong app)
            return running.first { $0.bundleIdentifier == bundleId }
        }
        guard let app = binding.app, !app.isEmpty else { return nil }
        let wanted = normalized(app)
        return running.first { candidate in
            guard let name = candidate.localizedName else { return false }
            return normalized(name) == wanted
        }
    }

    /// Normalizes "iTerm.app" / "Apple_Terminal" / "Terminal" into one comparable form
    private static func normalized(_ name: String) -> String {
        var value = name.lowercased()
        if value.hasSuffix(".app") { value = String(value.dropLast(4)) }
        if value.hasPrefix("apple_") { value = String(value.dropFirst(6)) }
        return value
    }
}
