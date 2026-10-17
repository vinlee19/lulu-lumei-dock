import AppKit
import SwiftUI

/// Main app window: hosts PopoverRootView's sidebar navigation as a standard resizable /
/// full-screen-capable window. Shares the same service instances as the menu bar (injected by
/// AppDelegate), so state stays in sync live.
@MainActor
final class MainWindowController: NSWindowController {
    private let usageService: UsageService
    private let limitsService: RateLimitsService
    private let navigation: PopoverNavigation

    init(
        usageService: UsageService,
        limitsService: RateLimitsService,
        settings: AppSettings,
        installer: InstallerService,
        sessionBrowser: SessionBrowserService,
        skillMemoryService: SkillMemoryService,
        plansService: PlansService,
        promptsService: PromptsService,
        agentConfigService: AgentConfigService,
        mcpService: MCPService,
        syncService: SyncService,
        cliToolsService: CLIToolsService,
        auditService: AuditService,
        notificationService: NotificationService,
        updateService: UpdateService,
        navigation: PopoverNavigation,
        palette: CommandPaletteService
    ) {
        self.usageService = usageService
        self.limitsService = limitsService
        self.navigation = navigation

        // Default size: 75% of the screen's visible area, capped at 1440×900, floored at 840×540 (=
        // minSize)
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let defaultSize = NSSize(
            width: min(max(visible.width * 0.75, 840), 1440),
            height: min(max(visible.height * 0.75, 540), 900))

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "lulu-lumei-dock"
        window.minSize = NSSize(width: 840, height: 540)
        window.collectionBehavior.insert(.fullScreenPrimary)
        // Not released on close: a menu-bar / Dock click can reopen the same window (otherwise
        // use-after-free)
        window.isReleasedWhenClosed = false

        let hosting = NSHostingController(
            rootView: PopoverRootView(
                usageService: usageService,
                limitsService: limitsService,
                settings: settings,
                installer: installer,
                sessionBrowser: sessionBrowser,
                skillMemoryService: skillMemoryService,
                plansService: plansService,
                promptsService: promptsService,
                agentConfigService: agentConfigService,
                mcpService: mcpService,
                syncService: syncService,
                cliToolsService: cliToolsService,
                auditService: auditService,
                notificationService: notificationService,
                updateService: updateService,
                navigation: navigation,
                palette: palette))
        // Don't let SwiftUI's ideal size reset the window frame (otherwise the first open is
        // squashed to the minimum size and content overlaps)
        hosting.sizingOptions = []
        window.contentViewController = hosting
        // Assigning contentViewController shrinks the window to the content's fitting size; pin it
        // back to the default size here
        window.setContentSize(defaultSize)
        // The key carries a 2: the shrink bug before v0.1.8 saved the squashed window under the old
        // key; renaming discards that bad data once
        window.setFrameAutosaveName("EurekaMainWindow2")
        // Restore the saved frame if there is one, otherwise center on first open
        if !window.setFrameUsingName("EurekaMainWindow2") {
            window.center()
        } else if window.frame.width < 840 || window.frame.height < 540 {
            // Clamp a restored frame that is below the minimum size (guards against bad values
            // written externally)
            var frame = window.frame
            frame.size.width = max(frame.size.width, 840)
            frame.size.height = max(frame.size.height, 540)
            window.setFrame(frame, display: false)
        }

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) 未实现") }

    /// Shows / brings forward the main window (optionally switching to a given tab). Activation
    /// order: activate first, then makeKey, otherwise the window may stay hidden behind other apps.
    func show(tab: PopoverRootView.Tab? = nil) {
        if let tab { navigation.tab = tab }
        usageService.refreshNow()
        limitsService.refresh()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
