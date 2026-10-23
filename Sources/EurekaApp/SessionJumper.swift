import AppKit
import EurekaIngest
import EurekaKit
import Foundation

/// One concrete "open session" button: where it goes, which app it names, which icon it shows
struct SessionJumpOption: Equatable {
    let target: SessionJumpTarget
    /// Display name of the target app ("Claude", "iTerm2", the localized "Terminal" …)
    let appName: String
    /// The target app's .app bundle, for its icon
    let appURL: URL?

    /// "Open in Claude" / "Switch to iTerm2". Computed on every read so a language switch applies
    /// to a card that is already up.
    var title: String {
        switch target {
        case .appLink:
            return L10n.text(
                "Open in \(appName)", zhHans: SessionJumper.phrase("在", appName, "中打开"))
        case .hostApp:
            return L10n.text(
                "Switch to \(appName)", zhHans: SessionJumper.phrase("切换到", appName))
        }
    }
}

/// Turns a jump target into a button and performs the jump.
///
/// No button when the target app is unavailable (better absent than a click that does nothing):
/// - direct link: some app must handle the URL scheme (it is launched if not running);
/// - host app: it must be running (once the terminal is closed, the session is gone too).
enum SessionJumper {
    static func option(for target: SessionJumpTarget) -> SessionJumpOption? {
        switch target {
        case .appLink(let link):
            guard let url = link.url,
                  let appURL = NSWorkspace.shared.urlForApplication(toOpen: url)
            else { return nil }
            return SessionJumpOption(target: target, appName: appName(at: appURL), appURL: appURL)
        case .hostApp(let binding):
            guard let app = TerminalActivator.runningApplication(binding) else { return nil }
            // The running app's name is localized by the system (Terminal shows its Chinese name
            // on a Chinese system), which is easier to recognize than the raw value in the binding
            return SessionJumpOption(
                target: target, appName: app.localizedName ?? binding.terminalName,
                appURL: app.bundleURL)
        }
    }

    static func perform(_ target: SessionJumpTarget) {
        switch target {
        case .appLink(let link):
            guard let url = link.url else { return }
            _ = NSWorkspace.shared.open(url)
        case .hostApp(let binding):
            TerminalActivator.activate(binding)
        }
    }

    /// Mixed Chinese / Latin spacing for the zhHans copy: a space between Chinese and a Latin
    /// letter or digit, none between two Chinese runs (so "iTerm2" gets spaces and a Chinese app
    /// name does not)
    static func phrase(_ before: String, _ name: String, _ after: String = "") -> String {
        func isLatin(_ character: Character?) -> Bool {
            guard let character else { return false }
            return character.isASCII && (character.isLetter || character.isNumber)
        }
        let left = isLatin(name.first) ? " " : ""
        let right = !after.isEmpty && isLatin(name.last) ? " " : ""
        return before + left + name + right + after
    }

    /// App display name: localized CFBundleDisplayName → CFBundleName → file name
    private static func appName(at appURL: URL) -> String {
        let bundle = Bundle(url: appURL)
        return bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? appURL.deletingPathExtension().lastPathComponent
    }
}

/// Cache of direct session links: reads local records in the background
/// (`SessionAppLinkResolver`) and pushes the results to the island.
///
/// Lookup starts as soon as a session shows up in the active list, so by the time it finishes or
/// waits its card can carry the button right away. A found mapping never changes while the session
/// lives and is kept; a miss is retried only after `retryInterval`: Desktop session files and Codex
/// rollouts are written when the session starts, so a miss is almost always a CLI session, and
/// every Claude lookup reads the head of every Desktop session file (940 on the test machine).
@MainActor
final class SessionAppLinkCache {
    private(set) var links: [String: SessionAppLink] = [:]
    private var missedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []
    private let queue = DispatchQueue(label: "com.vinlee.eureka.session-links", qos: .utility)
    private static let retryInterval: TimeInterval = 600

    /// Called with the full map whenever a new link is found; AppDelegate forwards it to
    /// IslandViewModel
    var onChange: (@MainActor ([String: SessionAppLink]) -> Void)?

    func prefetch(_ sessions: [(source: AgentSource, sessionId: String)], now: Date = Date()) {
        var wanted: [String: (source: AgentSource, sessionId: String)] = [:]
        for session in sessions where SessionAppLinkResolver.canResolve(session.source) {
            let key = AgentTask.key(source: session.source, sessionId: session.sessionId)
            guard links[key] == nil, !inFlight.contains(key) else { continue }
            if let missed = missedAt[key], now.timeIntervalSince(missed) < Self.retryInterval {
                continue
            }
            wanted[key] = session
        }
        guard !wanted.isEmpty else { return }
        inFlight.formUnion(wanted.keys)
        let jobs = Array(wanted)
        queue.async { [weak self] in
            let results = jobs.map { key, session in
                (key, SessionAppLinkResolver.resolve(
                    source: session.source, sessionId: session.sessionId))
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(results) }
            }
        }
    }

    private func apply(_ results: [(String, SessionAppLink?)]) {
        var changed = false
        let now = Date()
        for (key, link) in results {
            inFlight.remove(key)
            if let link {
                links[key] = link
                missedAt[key] = nil
                changed = true
            } else {
                missedAt[key] = now
            }
        }
        if changed { onChange?(links) }
    }
}
