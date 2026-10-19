import AppKit
import EurekaKit

// CLI modes (hook install/uninstall/status queries) are handled directly and exit without starting
// the GUI. The language preference must be applied before the CLI prints any text; with no stored
// preference it's English.
L10n.applyStoredPreference()
if EurekaCLI.runIfNeeded() {
    exit(0)
}

// Regular app entry: Dock icon + app menu + main window (lifecycle handed to AppDelegate). When run
// directly via swift run this is the only source of the activation policy, and at runtime it also
// overrides Info.plist. Top-level code isn't a static MainActor context, but it does run on the
// main thread → assumeIsolated.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
