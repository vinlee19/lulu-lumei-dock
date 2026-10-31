import AppKit
import Combine
import EurekaIngest
import EurekaKit
import EurekaSync

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var mainWindow: MainWindowController?
    private let store = TaskStore()
    private let usageService = UsageService()
    private let limitsService = RateLimitsService()
    private let settings = AppSettings()
    private let installer = InstallerService()
    // Service instances shared by the main window and the menu bar (owned here, injected into both
    // so state stays consistent)
    private let sessionBrowser = SessionBrowserService()
    /// Root of the summary workspace, resolved once for the per-event check
    private let summaryWorkspaceRoot = SummaryWorkspacePaths.root()
    private let skillMemory = SkillMemoryService()
    private let plans = PlansService()
    // The prompt library depends on sessionBrowser's session index, so construct it lazily (same
    // precedent as palette)
    private lazy var promptsService = PromptsService(sessionBrowser: sessionBrowser)
    private let agentConfig = AgentConfigService()
    private let mcpService = MCPService()
    private let syncService = SyncService()
    private let cliTools = CLIToolsService()
    private let auditService = AuditService()
    private let notificationService = NotificationService()
    private lazy var soundAlerts = SoundAlertService(settings: settings)
    private let updateService = UpdateService()
    private let navigation = PopoverNavigation()
    private let knowledgeIndexer = KnowledgeSearchIndexer()
    // ⌘K global search: depends on already-built service instances, so defer it lazily to first
    // access (by then they all exist)
    private lazy var palette = CommandPaletteService(
        sessionBrowser: sessionBrowser, skillMemory: skillMemory, plans: plans,
        prompts: promptsService, settings: settings)
    private var pipeline: EventPipeline?
    private var reapTimer: Timer?
    private var islandController: IslandPanelController?
    private var questionBridge: IslandQuestionBridge?
    private var mascotController: MascotPanelController?
    private var wellnessMonitor: WellnessMonitor?
    private var cancellables: Set<AnyCancellable> = []
    /// Terminal ownership probing: timer + dedicated queue (neither the syscalls nor reading
    /// Info.plist belong on the main thread)
    private var terminalProbeTimer: Timer?
    private let probeQueue = DispatchQueue(
        label: "com.vinlee.eureka.terminalprobe", qos: .utility)
    /// Direct session links (Claude / Codex Desktop) for the island's "open session" button
    private let sessionLinks = SessionAppLinkCache()

    @objc private func languageDidChange() {
        MainActor.assumeIsolated {
            NSApp.mainMenu = MainMenu.build()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Release a hook waiting for an island answer right away, leaving only Claude's own dialog
        questionBridge?.stop()
        // Stop managed summary processes and keep their drafts
        SessionSummaryService.shared.shutdown()
    }

    /// `EUREKA_SANDBOX=1`: a second copy running beside the installed app on a private
    /// data root (see Scripts/run-sandbox.sh). It skips the two launch-time steps that
    /// reach outside that root: Sparkle update checks and the installed-hook refresh.
    static let isSandboxed = ProcessInfo.processInfo.environment["EUREKA_SANDBOX"] == "1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The brutal theme's fonts (Space Grotesk/Mono) must be registered before any UI renders
        ThemeFonts.register()
        // On every launch, sync the bundled relay / answer hook to their stable paths (hooks stay
        // linked across app upgrades)
        RelaySyncer.sync()
        RelaySyncer.syncAsk()
        // Per-model context-window overrides (the denominator for ctx%; loaded once at launch)
        ContextWindows.loadOverrides(
            from: SpoolPaths.root().appendingPathComponent("context-windows.json"))

        // Standard app main menu (About / Hide / Quit + Window). Rebuilt through the same entry
        // point after a language switch.
        NSApp.mainMenu = MainMenu.build()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(languageDidChange),
            name: .eurekaLanguageDidChange,
            object: nil)

        // Only enabled in a real .app; runs one background check right after launch, honoring
        // Sparkle's own preferences.
        // A sandboxed trial copy (Scripts/run-sandbox.sh) never checks for updates:
        // Sparkle would offer to replace the trial bundle with the latest release.
        if !Self.isSandboxed { updateService.start() }

        // Main window: reuses PopoverRootView's 6 tabs and shares services with the menu bar
        let window = MainWindowController(
            usageService: usageService, limitsService: limitsService,
            settings: settings, installer: installer,
            sessionBrowser: sessionBrowser, skillMemoryService: skillMemory,
            plansService: plans,
            promptsService: promptsService,
            agentConfigService: agentConfig, mcpService: mcpService, syncService: syncService,
            cliToolsService: cliTools, auditService: auditService,
            notificationService: notificationService, updateService: updateService,
            navigation: navigation, palette: palette)
        mainWindow = window

        statusController = StatusItemController(
            usageService: usageService, limitsService: limitsService,
            settings: settings,
            onActivate: { [weak self] in self?.mainWindow?.show() })
        let island = IslandPanelController()
        island.start()
        islandController = island

        // Desktop mascot (off by default, opt-in; coexists with the Dynamic Island)
        let mascot = MascotPanelController()
        mascot.onRequestHide = { [weak self] in self?.settings.mascotEnabled = false }
        mascot.onOpenSettings = { [weak self] in self?.mainWindow?.show(tab: .settings) }
        mascot.applyPack(id: settings.mascotPack)
        mascot.start()
        mascotController = mascot
        settings.$mascotPack
            .sink { [weak mascot] id in mascot?.applyPack(id: id) }
            .store(in: &cancellables)
        settings.$mascotSleepMinutes
            .sink { [weak mascot] minutes in
                mascot?.viewModel.idleSleepSeconds = minutes > 0 ? Double(minutes) * 60 : .infinity
            }
            .store(in: &cancellables)
        settings.$mascotNightMode
            .sink { [weak mascot] on in mascot?.viewModel.nightMode = on }
            .store(in: &cancellables)
        settings.$mascotBubbles
            .sink { [weak mascot] on in mascot?.viewModel.showsBubbles = on }
            .store(in: &cancellables)
        // Size before visibility: the saved origin belongs to the scaled panel
        settings.$mascotSize
            .sink { [weak mascot] raw in mascot?.setSize(MascotSize.resolve(raw)) }
            .store(in: &cancellables)
        settings.$mascotEnabled
            .sink { [weak mascot] on in mascot?.setVisible(on) }
            .store(in: &cancellables)

        // Appearance theme: apply at launch + follow Settings changes
        Self.applyAppearance(settings.appearanceMode)
        settings.$appearanceMode
            .dropFirst()
            .sink { mode in Self.applyAppearance(mode) }
            .store(in: &cancellables)

        // Knowledge-surface scan finished -> event-driven full-text index rebuild (search freshness
        // = list freshness). @Published fires in willSet: reading lastScanAt synchronously inside
        // the sink yields the **old value**, so on the first scan at launch reindexKnowledge's
        // both-non-nil guard swallows both emissions and the index is never built. Deferring with
        // main.async reads it after didSet, so the guard sees the new value.
        skillMemory.$lastScanAt.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reindexKnowledge() } }
            .store(in: &cancellables)
        plans.$lastScanAt.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reindexKnowledge() } }
            .store(in: &cancellables)
        // After Settings' "clear full-text index" wipes the knowledge index nothing would heal it,
        // so kick a rebuild (both lastScanAt values must be non-nil by then: clearing can only
        // happen after the launch scan)
        usageService.onSearchIndexCleared = { [weak self] in self?.reindexKnowledge() }

        // Prompt library: extract incrementally as soon as the session index finishes scanning
        // (scanning -> false); refresh skips by fingerprint internally, so repeated triggers only
        // parse sessions with new messages
        sessionBrowser.$scanning
            .dropFirst()
            .filter { !$0 }
            .sink { [weak self] _ in DispatchQueue.main.async { self?.promptsService.refresh() } }
            .store(in: &cancellables)
        promptsService.$lastScanAt.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.reindexPrompts() } }
            .store(in: &cancellables)

        usageService.start()
        limitsService.start()
        // AI session summaries: reconciles runs a previous process left unfinished, probes CLIs
        SessionSummaryService.shared.start()
        // Model pricing catalog: recompute costs after a price change (usage summary + sessions
        // page)
        PricingCatalogService.shared.onPricingChanged = { [weak self] in
            self?.usageService.pricingDidChange()
            self?.sessionBrowser.refresh()
        }
        PricingCatalogService.shared.start()

        // Security audit: periodic Codex scan + Claude side-channel events; a high-risk hit -> red
        // island card + system notification (each gated by its toggle)
        auditService.onRiskAlert = { [weak self] alert in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logLine("审计告警 \(alert.ruleId) [\(alert.source.rawValue)] \(alert.tool): \(alert.detail)")
                if self.settings.auditRiskAlertsEnabled {
                    self.islandController?.viewModel.enqueueAlert(alert)
                }
                if self.settings.auditSystemNotifyEnabled {
                    self.notificationService.postRiskAlert(alert)
                }
            }
        }
        auditService.setCaptureEnabled(settings.auditEnabled)
        auditService.updateRetention(days: settings.auditRetentionDays)
        auditService.start()
        settings.$auditEnabled
            .sink { [weak auditService] on in auditService?.setCaptureEnabled(on) }
            .store(in: &cancellables)
        settings.$auditRetentionDays
            .sink { [weak auditService] days in auditService?.updateRetention(days: days) }
            .store(in: &cancellables)
        // System notification authorization: requested when the toggle is turned on (non-.app dev
        // mode falls back to the in-island red card only)
        if settings.auditSystemNotifyEnabled { notificationService.enable() }
        settings.$auditSystemNotifyEnabled
            .dropFirst()
            .sink { [weak notificationService] on in if on { notificationService?.enable() } }
            .store(in: &cancellables)
        // Key-event system notifications: share authorization with high-risk alerts and likewise
        // only request it when the toggle is on
        if settings.eventSystemNotifyEnabled { notificationService.enable() }
        settings.$eventSystemNotifyEnabled
            .dropFirst()
            .sink { [weak notificationService] on in if on { notificationService?.enable() } }
            .store(in: &cancellables)

        // Cloud backup: config snapshot push + toggle-driven timer
        let pushSyncConfig = { [weak self] in
            guard let self else { return }
            self.syncService.updateConfig(
                provider: StorageProvider(rawValue: self.settings.storageProvider) ?? .tencentCOS,
                region: self.settings.cosRegion, bucket: self.settings.cosBucket,
                endpointHost: self.settings.cosEndpointHost,
                keyPrefix: self.settings.cosKeyPrefix,
                retryAttempts: self.settings.cosRetryAttempts,
                retryBackoffSeconds: self.settings.cosRetryBackoffSeconds,
                customFolders: self.settings.customSyncFolders)
        }
        pushSyncConfig()
        settings.$storageProvider.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRegion.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosBucket.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosEndpointHost.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosKeyPrefix.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRetryAttempts.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$cosRetryBackoffSeconds.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        settings.$customSyncFolders.sink { _ in pushSyncConfig() }.store(in: &cancellables)
        syncService.updateInterval(minutes: settings.cosSyncIntervalMinutes)
        settings.$cosSyncIntervalMinutes
            .sink { [weak syncService] minutes in syncService?.updateInterval(minutes: minutes) }
            .store(in: &cancellables)
        if settings.cloudBackupEnabled {
            syncService.start()
        }
        settings.$cloudBackupEnabled
            .dropFirst()
            .sink { [weak syncService] on in
                if on { syncService?.start() } else { syncService?.stop() }
            }
            .store(in: &cancellables)

        // Show the main window right at launch (regular app)
        window.show()

        // Settings -> Dynamic Island behavior
        island.viewModel.autoDismissSeconds = settings.autoDismissSeconds
        settings.$autoDismissSeconds
            .sink { [weak island] seconds in island?.viewModel.autoDismissSeconds = seconds }
            .store(in: &cancellables)
        island.viewModel.showStartTime = settings.showStartTime
        settings.$showStartTime
            .sink { [weak island] value in island?.viewModel.showStartTime = value }
            .store(in: &cancellables)
        island.viewModel.onToggleTimeMode = { [weak settings] in
            settings?.showStartTime.toggle()
        }
        // "Open session": direct links for desktop-app sessions are looked up in the background and
        // pushed to the island; clicks go to SessionJumper
        sessionLinks.onChange = { [weak island] links in
            island?.viewModel.updateAppLinks(links)
        }
        island.viewModel.onOpenSession = { SessionJumper.perform($0) }

        // Answering Claude's questions on the island: the toggle governs both the heartbeat/polling
        // and the answer hook in settings.json. settings.json is only edited when the user actually
        // flips the toggle (dropFirst); installing at launch is left to autoUpdateInstalled, which
        // is gated by the "auto-update hooks" toggle
        let questionBridge = IslandQuestionBridge(viewModel: island.viewModel)
        self.questionBridge = questionBridge
        island.viewModel.onQuestionArrived = { [weak self] in
            self?.soundAlerts.play(.question)
        }
        installer.askHookEnabled = { [weak settings] in settings?.answerQuestionsOnIsland ?? true }
        settings.$answerQuestionsOnIsland
            .sink { [weak questionBridge] on in questionBridge?.setEnabled(on) }
            .store(in: &cancellables)
        settings.$answerQuestionsOnIsland
            .dropFirst()
            .sink { [weak installer] _ in
                // @Published fires on willSet: read the toggle only after the value is actually
                // written
                DispatchQueue.main.async { installer?.applyAskHookSetting() }
            }
            .store(in: &cancellables)

        // Wellbeing nudges: vibe coding too long / too many sessions / late-night care
        let wellness = WellnessMonitor(settings: settings, store: store) { [weak island, weak mascot] notice in
            island?.viewModel.enqueueNotice(notice)
            mascot?.viewModel.showNotice(notice.headline)
        }
        wellness.start()

        // Rate-limit exhaustion forecast alerts -> island card (once per source per window;
        // throttled inside the service)
        limitsService.onAlert = { [weak island] notice in
            island?.viewModel.enqueueNotice(notice)
        }
        wellnessMonitor = wellness

        // Monthly budget: island card (+ system notification when enabled) once per threshold per
        // month, checked on every usage scan
        usageService.$monthOverview
            .combineLatest(settings.$usageMonthlyBudget)
            .sink { [weak self, weak island] overview, budget in
                guard let self, let overview else { return }
                guard let notice = BudgetAlertStore.check(
                    spent: overview.monthToDate, budget: budget, projected: overview.projected)
                else { return }
                island?.viewModel.enqueueNotice(notice)
                if self.settings.eventSystemNotifyEnabled {
                    self.notificationService.postEvent(SystemEventNotification(
                        identifier: "eureka-\(notice.id)", title: notice.headline,
                        body: notice.body))
                }
            }
            .store(in: &cancellables)

        // First launch: guide to the Settings page for one-click install (the window is already
        // shown, so only switch tabs here)
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { [weak self] in
                    self?.mainWindow?.show(tab: .settings)
                }
            }
        }

        // The pipeline calls back on its own queue; main.async preserves FIFO order and hops back
        // to the MainActor. auditHandler is a side channel: Claude PostToolUse operations go
        // straight to the audit service, bypassing TaskStore.
        let pipeline = EventPipeline(
            spoolRoot: SpoolPaths.root(),
            auditHandler: { [weak auditService] event, isStale in
                auditService?.ingestHook(event, isStale: isStale)
            }
        ) { [weak self] event, isStale in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.handle(event, isStale: isStale)
                }
            }
        }
        pipeline.start()
        self.pipeline = pipeline

        // Fallback for lost hooks: periodically reap "ghost" tasks with no activity for a long time
        reapTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let effects = self.store.reapStaleTasks(now: Date(), runningTimeout: 4 * 3600)
                if !effects.isEmpty {
                    self.applyToUI(effects: effects, isStale: true)
                }
            }
        }

        warmUpKnowledgeScans()
        // The sandbox runs on its own data root, so the installed hooks (which point at
        // the real relay path) would read as drifted; never let a trial copy touch them.
        if !Self.isSandboxed { syncInstalledHooksIfAllowed() }
        startTerminalProbing()

        render()
        logLine("启动完成 spool=\(SpoolPaths.root().path)")
    }

    /// Launch prewarm: scan the Skills / Memory / Agents / Plans data without waiting for the user
    /// to open those pages. It used to be a lazy scan (each page refreshed on onAppear), so the
    /// first visit to a page meant staring at a spinner.
    ///
    /// Staggered by locally measured cost, cheapest first (agents 7ms -> skills+memory 234ms -> plans ~1s,
    /// possibly minutes the first time), so the three .userInitiated queues don't compete with the freshly launched window / Dynamic Island and
    /// usageService's first scan for resources.
    /// All go through refresh() (not force): it means "scan only if never scanned", so a later page onAppear call won't rescan.
    /// After launch, refresh **already installed** hooks per policy (the "auto-update" toggle in Settings -> Integrations).
    /// Only touches items the user already installed; an unrecognizable config is skipped entirely, with the reason shown in Settings.
    /// Runs late and delayed at the end of launch: it reads and writes user config files and shouldn't compete with startup.
    private func syncInstalledHooksIfAllowed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.installer.autoUpdateInstalled(enabled: self.settings.hookAutoUpdate)
                // Auto-update edits the user's config files, so leave a trace whether it succeeded
                // or skipped
                if let message = self.installer.message {
                    self.logLine("hook 自动更新 \(message)")
                }
                if !self.installer.autoUpdateSkipped.isEmpty {
                    self.logLine("hook 自动更新已跳过 "
                        + self.installer.autoUpdateSkipped.map(\.title).joined(separator: ","))
                }
            }
        }
    }

    /// Launch warm-ups. The light config scans start right away; the three heavy ones (skills +
    /// memory, plans, sessions + prompts) each parse a whole history on a first install, and
    /// started together a few seconds apart they saturated every core next to the usage backfill
    /// and pushed memory into swap, stalling even the cursor. So they run one after another, and
    /// the first waits for the usage pass to publish. Each wait has a ceiling, so a stalled step
    /// never holds the rest back. Opening a page still loads it at once.
    private func warmUpKnowledgeScans() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.agentConfig.refresh()
                // MCP indexing goes in the same batch as agents (both lightweight config-file
                // scans, milliseconds)
                self.mcpService.refresh()
                self.usageService.loadAgentStats()
                self.logLine("知识库预热启动 agents")
            }
        }
        whenReady(usageService.$summary.map { $0 != nil }, within: 120, label: "skills+memory") {
            [weak self] in
            guard let self else { return }
            self.skillMemory.refresh()
            self.usageService.loadSkillStats()
            // Prewarm the stat card's "hits this week" too, otherwise the number only appears
            // after opening the page
            self.usageService.loadSkillRanking(
                source: nil, from: UsageService.DashboardPeriod.week.startDate, to: Date())
            self.whenReady(self.skillMemory.$lastScanAt.map { $0 != nil }, within: 60, label: "plans") {
                [weak self] in
                guard let self else { return }
                self.plans.refresh()
                // The session index feeds the prompt library (the scanning -> false subscription
                // picks up extraction automatically)
                self.whenReady(
                    self.plans.$lastScanAt.map { $0 != nil }, within: 60, label: "sessions+prompts"
                ) { [weak self] in self?.sessionBrowser.refresh() }
            }
        }
    }

    /// Runs `body` once on the main thread when `ready` first emits true, or after `within`
    /// seconds, whichever comes first
    private func whenReady<P: Publisher>(
        _ ready: P, within limit: TimeInterval, label: String, _ body: @escaping () -> Void
    ) where P.Output == Bool, P.Failure == Never {
        var fired = false
        var token: AnyCancellable?
        let fire: () -> Void = { [weak self] in
            guard !fired else { return }
            fired = true
            token?.cancel()
            body()
            self?.logLine("知识库预热启动 \(label)")
        }
        token = ready.filter { $0 }.first()
            .receive(on: DispatchQueue.main)
            .sink { _ in MainActor.assumeIsolated { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) {
            MainActor.assumeIsolated { fire() }
        }
    }

    /// Knowledge-surface full-text index rebuild: feeds the latest skills / memory / instructions /
    /// plans snapshot to the indexer (which diffs incrementally itself). Acts only when both
    /// lastScanAt values are non-nil. While either side hasn't finished scanning, its
    /// knowledgeSnapshot() is empty, and index()'s prune would treat every doc the other side
    /// already persisted as "gone" and delete them all; the side that finishes first at launch
    /// would trigger a spurious wipe, forcing a full rebuild on every launch.
    private func reindexKnowledge() {
        guard skillMemory.lastScanAt != nil, plans.lastScanAt != nil else { return }
        let snapshot = skillMemory.knowledgeSnapshot()
        knowledgeIndexer.index(
            skills: snapshot.skills, memories: snapshot.memories,
            plans: plans.knowledgeSnapshot())
    }

    /// Prompt library full-text index: the bodies are in memory (the SQLite prompts table), a
    /// separate channel from the file-based knowledge surfaces; triggered independently (doesn't
    /// wait for skills/plans; that guard chain doesn't include prompts, and mixing them would slow
    /// each other's first scan)
    private func reindexPrompts() {
        knowledgeIndexer.indexPrompts(promptsService.knowledgeSnapshot())
    }

    /// Appearance theme: system = follow the system (nil) / light / dark
    private static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// Clicking the Dock icon (or reopening with no windows) -> bring the main window forward
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    /// ⌘K menu entry: show the main window first, then post the palette-toggle notification. While
    /// the main window is hidden the notification still reaches PopoverRootView (the view tree
    /// isn't destroyed by orderOut), so posting without showing the window would make
    /// paletteVisible flip silently where the user can't see it. This ensures the window is already
    /// visible when the flip happens.
    func showPalette() {
        // When the window is already key, just toggle without calling show() again: show()
        // piggybacks a usage/limits refresh, and a pure UI toggle shouldn't carry that load every
        // time. Only summon the window when it is hidden / not key, and use forceOpen to force
        // "open only, never toggle": closing with ⌘W may leave paletteVisible=true, and a toggle
        // would then close it instead.
        let windowWasKey = mainWindow?.window?.isKeyWindow == true
        if !windowWasKey { mainWindow?.show() }
        NotificationCenter.default.post(
            name: .eurekaToggleCommandPalette, object: nil,
            userInfo: windowWasKey ? nil : ["forceOpen": true])
    }


    private func handle(_ event: TaskEvent, isStale: Bool) {
        // Eureka's own summary runs execute in the app-managed workspace; whatever channel still
        // reports them (a CLI that ignored the hook / persistence switches) must not reach the
        // island, history or terminal bindings
        if SummaryWorkspacePaths.isInternal(event.cwd, under: summaryWorkspaceRoot) { return }
        // Persist terminal ownership first, and **regardless of isStale**: it is a historical fact
        // (this session really did run in that terminal), treated the same as history writes. It
        // sits before the staleness gate, otherwise bindings carried by backlogged events would be
        // dropped.
        if let terminal = event.terminal {
            usageService.recordTerminal(
                source: event.source, sessionId: event.sessionId,
                binding: terminal, at: event.timestamp)
        }
        // Backlogged "liveness signals" stay out of the state machine: an isolated stale heartbeat
        // / waiting / session start doesn't mean the session is alive now, and accepting them all
        // would conjure up a pile of ghost sessions
        if isStale {
            switch event.kind {
            case .activity, .waiting, .sessionStarted, .contextUpdate, .titleUpdate,
                 .subagentsUpdated, .toolPending, .compacting, .awaitingBackgroundTasks:
                // toolPending / compacting are also "liveness signals": a "about to run Bash" from
                // a few minutes ago doesn't mean it is still running, and accepting it would create
                // a ghost session
                return
            case .taskStarted, .taskFinished, .sessionEnded:
                break  // starts/finishes must reach history and pairing
            }
        }
        applyToUI(effects: store.apply(event), isStale: isStale)
    }

    /// Terminal ownership probing for hook-less sessions: one round every 15 seconds, and it only
    /// acts **when there really are active sessions missing an owner**.
    ///
    /// Covers the seven sources without a relay, plus users who haven't installed Claude hooks; "works without hooks" is an established principle.
    /// With nothing to do it makes not a single syscall (`probe(wanted: [])` returns immediately).
    private func startTerminalProbing() {
        terminalProbeTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeMissingTerminals() }
        }
    }

    private func probeMissingTerminals() {
        // Only query sessions missing an owner; and **skip the whole group when one (source, cwd)
        // has several sessions**: matching by cwd can't tell them apart, and no answer beats a
        // wrong one (the probe side has the same guard).
        var byKey: [String: [AgentTask]] = [:]
        for task in store.activeTasks.values where task.terminal == nil {
            guard let cwd = task.cwd, !cwd.isEmpty else { continue }
            byKey["\(task.source.rawValue)|\(cwd)", default: []].append(task)
        }
        let unique = byKey.values.filter { $0.count == 1 }.compactMap(\.first)
        guard !unique.isEmpty else { return }
        let wanted = unique.map { (source: $0.source, cwd: $0.cwd ?? "") }
        probeQueue.async { [weak self] in
            let probes = TerminalProber.probe(wanted: wanted)
            guard !probes.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.applyProbedTerminals(probes) }
            }
        }
    }

    private func applyProbedTerminals(_ probes: [TerminalProber.Probe]) {
        var changed = false
        for probe in probes {
            // Find that single session again (the probe groups by (source, cwd); map it back here)
            guard let task = store.activeTasks.values.first(where: {
                $0.source == probe.source && $0.cwd == probe.cwd
            }) else { continue }
            if store.attachTerminal(
                probe.binding, source: probe.source, sessionId: task.sessionId) {
                changed = true
                usageService.recordTerminal(
                    source: probe.source, sessionId: task.sessionId,
                    binding: probe.binding, at: Date())
                logLine("终端归属（探测）\(task.id) → \(probe.binding.displayName)")
            }
        }
        if changed { applyToUI(effects: [.activeTasksChanged], isStale: false) }
    }

    /// Smart mute: when you are looking at the terminal app the session runs in, the finished card
    /// needn't pop (you've already seen it).
    ///
    /// **The check is app-level only** (it can't tell tabs apart): with 5 iTerm tabs open, any one
    /// in the foreground counts as "watching". So call sites must obey one hard rule:
    /// **waiting-for-permission cards are never muted**. That is a blocking prompt that needs you
    /// to act, and hiding it because "some iTerm tab is in front" costs you waiting idly while the
    /// agent stays stuck.
    private func shouldSuppressCard(terminal: TerminalBinding?) -> Bool {
        guard settings.suppressCardWhenTerminalFrontmost, let terminal else { return false }
        return TerminalActivator.isFrontmost(terminal)
    }

    /// Projects state-machine effects onto the UI and history (backlogged/stale events only go to
    /// history, no island pop)
    private func applyToUI(effects: [TaskStoreEffect], isStale: Bool) {
        guard let island = islandController else { return }
        for effect in effects {
            switch effect {
            case .taskFinished(let task):
                let duration = task.duration.map { String(format: "%.0f秒", $0) } ?? "未知耗时"
                logLine("完成 \(task.id) [\(task.outcome.rawValue)] \(duration) \(task.title ?? "")\(isStale ? " (积压)" : "")")
                usageService.recordFinished(task)
                let wantCard = (task.outcome == .success
                    ? settings.notifyCompletion
                    : settings.notifyError)
                    && !shouldSuppressCard(terminal: task.terminal)
                // The sound alert follows the card: no card, no sound
                var rang = false
                if !isStale && wantCard {
                    // A session never seen in the active list (a very short turn) starts its lookup
                    // only now; the button appears once the link is found
                    sessionLinks.prefetch([(task.source, task.sessionId)])
                    island.viewModel.enqueueFinished(task)
                    rang = soundAlerts.play(.forFinished(task.outcome))
                }
                // System notifications only check the toggle, no "watching the terminal" mute: they
                // exist precisely for when you can't see the screen
                if !isStale, let note = SystemEventNotifications.forFinished(
                    task, master: settings.eventSystemNotifyEnabled,
                    completion: settings.notifyCompletion, error: settings.notifyError) {
                    notificationService.postEvent(note, silent: rang)
                }
                if !isStale {
                    mascotController?.viewModel.showFinished(success: task.outcome == .success)
                }
            case .taskWaiting(let task):
                logLine("等待 \(task.id) \(task.title ?? "")")
                // Only the non-blocking "waiting for input" kind may be muted; "waiting for
                // permission" always pops: the app-level check can't tell tabs apart, and hiding
                // the wrong one leaves you waiting for nothing
                let suppressible: Bool
                if case .waiting(.idle, _) = task.phase {
                    suppressible = shouldSuppressCard(terminal: task.terminal)
                } else {
                    suppressible = false
                }
                var rang = false
                if !isStale && settings.notifyWaiting && !suppressible {
                    island.viewModel.enqueueWaiting(task)
                    if case .waiting(let reason, _) = task.phase {
                        rang = soundAlerts.play(.forWaiting(reason))
                    }
                }
                if !isStale, let note = SystemEventNotifications.forWaiting(
                    task, master: settings.eventSystemNotifyEnabled,
                    waiting: settings.notifyWaiting) {
                    notificationService.postEvent(note, silent: rang)
                }
            case .activeTasksChanged:
                // History page's "running" group: push a copy to UsageService on the same path, in
                // sync with IslandViewModel
                usageService.publishRunningTasks(store.sortedActiveTasks)
            }
        }
        island.viewModel.updateActiveTasks(
            store.sortedActiveTasks, idle: store.sortedIdleTasks)
        // Look up direct links as soon as a session appears, so its finished / waiting card can
        // carry the button right away (sessions already looked up cost no file reads)
        sessionLinks.prefetch(
            (store.sortedActiveTasks + store.sortedIdleTasks).map { ($0.source, $0.sessionId) })
        mascotController?.viewModel.updateActiveTasks(
            active: store.sortedActiveTasks, idle: store.sortedIdleTasks)
        render()
    }

    private func render() {
        let tasks = store.sortedActiveTasks
        statusController?.update(tasks: tasks)
        let waitingCount = tasks.filter {
            if case .waiting = $0.phase { return true } else { return false }
        }.count
        let unread = islandController?.viewModel.unreadFinished.count ?? 0
        logLine("active=\(tasks.count) waiting=\(waitingCount) idle=\(store.sortedIdleTasks.count) unread=\(unread)")
    }

    /// Dev-mode observability: single-line stdout log that e2e scripts assert on (harmless when
    /// running inside the .app)
    private func logLine(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
