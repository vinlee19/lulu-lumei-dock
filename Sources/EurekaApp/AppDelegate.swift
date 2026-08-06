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
    // 主窗口与菜单栏共享的服务实例（所有权在此，注入两处保证状态一致）
    private let sessionBrowser = SessionBrowserService()
    private let skillMemory = SkillMemoryService()
    private let plans = PlansService()
    private let agentConfig = AgentConfigService()
    private let syncService = SyncService()
    private let cliTools = CLIToolsService()
    private let auditService = AuditService()
    private let notificationService = NotificationService()
    private let updateService = UpdateService()
    private let navigation = PopoverNavigation()
    private let knowledgeIndexer = KnowledgeSearchIndexer()
    // ⌘K 全局搜索：依赖三个已就绪的服务实例，用 lazy 延后到首次访问（此时它们都已构造完毕）
    private lazy var palette = CommandPaletteService(
        sessionBrowser: sessionBrowser, skillMemory: skillMemory, plans: plans, settings: settings)
    private var pipeline: EventPipeline?
    private var reapTimer: Timer?
    private var islandController: IslandPanelController?
    private var mascotController: MascotPanelController?
    private var wellnessMonitor: WellnessMonitor?
    private var cancellables: Set<AnyCancellable> = []
    /// 终端归属探测：定时器 + 专用队列（syscall 与读 Info.plist 都不该占主线程）
    private var terminalProbeTimer: Timer?
    private let probeQueue = DispatchQueue(
        label: "com.vinlee.eureka.terminalprobe", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // brutal 主题字体（Space Grotesk/Mono）须先于任何 UI 渲染注册
        ThemeFonts.register()
        // 每次启动把随包 relay 同步到稳定路径（升级 app 后 hooks 不断链）
        RelaySyncer.sync()
        // 模型上下文窗口覆盖表（ctx% 的分母；启动时一次性加载）
        ContextWindows.loadOverrides(
            from: SpoolPaths.root().appendingPathComponent("context-windows.json"))

        // 常规应用主菜单（关于/隐藏/退出 + 窗口）
        NSApp.mainMenu = MainMenu.build()

        // 仅正式 .app 启用；启动后按 Sparkle 自带偏好立即执行一次后台检查。
        updateService.start()

        // 主窗口：复用 PopoverRootView 的 6 个页签，与菜单栏共享服务
        let window = MainWindowController(
            usageService: usageService, limitsService: limitsService,
            settings: settings, installer: installer,
            sessionBrowser: sessionBrowser, skillMemoryService: skillMemory,
            plansService: plans,
            agentConfigService: agentConfig, syncService: syncService,
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

        // 桌面吉祥物（默认关，opt-in；与灵动岛并存）
        let mascot = MascotPanelController()
        mascot.onRequestHide = { [weak self] in self?.settings.mascotEnabled = false }
        mascot.onOpenSettings = { [weak self] in self?.mainWindow?.show(tab: .settings) }
        mascot.applyPack(id: settings.mascotPack)
        mascot.start()
        mascotController = mascot
        settings.$mascotEnabled
            .sink { [weak mascot] on in mascot?.setVisible(on) }
            .store(in: &cancellables)
        settings.$mascotPack
            .sink { [weak mascot] id in mascot?.applyPack(id: id) }
            .store(in: &cancellables)

        // 外观主题：启动应用 + 跟随设置变更
        Self.applyAppearance(settings.appearanceMode)
        settings.$appearanceMode
            .dropFirst()
            .sink { mode in Self.applyAppearance(mode) }
            .store(in: &cancellables)

        // 知识面扫描完成 → 事件驱动重建全文索引（搜索新鲜度 = 列表新鲜度）
        skillMemory.$lastScanAt.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in self?.reindexKnowledge() }
            .store(in: &cancellables)
        plans.$lastScanAt.compactMap { $0 }.removeDuplicates()
            .sink { [weak self] _ in self?.reindexKnowledge() }
            .store(in: &cancellables)
        // 设置页「清空全文索引」清掉 knowledge 索引后没人会自愈——补一脚重建
        // （此时两个 lastScanAt 必已非 nil：清空只可能发生在启动扫描之后）
        usageService.onSearchIndexCleared = { [weak self] in self?.reindexKnowledge() }

        usageService.start()
        limitsService.start()

        // 安全审计：Codex 定时扫描 + Claude 旁路事件；高危命中 → 岛红卡 + 系统通知（各受开关门控）
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
        // 系统通知授权：开启开关时请求（非 .app 开发态自动降级为仅岛内红卡）
        if settings.auditSystemNotifyEnabled { notificationService.enable() }
        settings.$auditSystemNotifyEnabled
            .dropFirst()
            .sink { [weak notificationService] on in if on { notificationService?.enable() } }
            .store(in: &cancellables)
        // 关键事件系统通知：与高危告警共用授权，同样只在开启开关时请求
        if settings.eventSystemNotifyEnabled { notificationService.enable() }
        settings.$eventSystemNotifyEnabled
            .dropFirst()
            .sink { [weak notificationService] on in if on { notificationService?.enable() } }
            .store(in: &cancellables)

        // 云端备份：配置快照推送 + 开关驱动定时器
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

        // 启动即显示主窗口（常规应用）
        window.show()

        // 设置 → 灵动岛行为
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

        // 健康提示：vibe coding 过久/会话过多/深夜关怀
        let wellness = WellnessMonitor(settings: settings, store: store) { [weak island, weak mascot] notice in
            island?.viewModel.enqueueNotice(notice)
            mascot?.viewModel.showNotice(notice.headline)
        }
        wellness.start()

        // 限额打满预测告警 → 岛卡（每源每窗口期一次，节流在服务内）
        limitsService.onAlert = { [weak island] notice in
            island?.viewModel.enqueueNotice(notice)
        }
        wellnessMonitor = wellness

        // 首次启动：引导到设置页一键安装（窗口已显示，这里只切页签）
        if !UserDefaults.standard.bool(forKey: "didOnboard") {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { [weak self] in
                    self?.mainWindow?.show(tab: .settings)
                }
            }
        }

        // 管道在自己的队列回调；main.async 保证 FIFO 顺序后接回 MainActor。
        // auditHandler 是旁路：Claude PostToolUse 操作直接进审计服务，不经 TaskStore。
        let pipeline = EventPipeline(
            spoolRoot: SpoolPaths.root(),
            auditHandler: { [weak auditService] event, isStale in
                auditService?.ingestClaude(event, isStale: isStale)
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

        // hook 丢失兜底：定期清理长时间无活动的"幽灵"任务
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
        syncInstalledHooksIfAllowed()
        startTerminalProbing()

        render()
        logLine("启动完成 spool=\(SpoolPaths.root().path)")
    }

    /// 启动预热：不等用户点进页面就把 Skills / Memory / Agents / Plans 四类数据扫好。
    /// 原来是懒扫描（各页 onAppear 才 refresh），第一次进页面得干等 spinner。
    ///
    /// 错峰按本机实测成本从小到大排（agents 7ms → skills+memory 234ms → plans ~1s，
    /// 首次可能几分钟），避免三条 .userInitiated 队列和刚起来的窗口/灵动岛、以及
    /// usageService 的首轮扫描同时抢资源。
    /// 都走 refresh()（非 force）：语义是「没扫过才扫」，所以页面 onAppear 再调也不会重复扫。
    /// 启动后按策略刷新**已安装**的 hook（设置→集成里的「自动更新」开关）。
    /// 只碰用户已经装过的项；看不懂的配置整体跳过并在设置页给出原因。
    /// 放在启动末尾且延迟执行：它要读写用户配置文件，不该和启动抢时间。
    private func syncInstalledHooksIfAllowed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.installer.autoUpdateInstalled(enabled: self.settings.hookAutoUpdate)
                // 自动更新会改用户的配置文件，无论成功还是跳过都要留痕
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

    private func warmUpKnowledgeScans() {
        let steps: [(delay: TimeInterval, label: String, run: () -> Void)] = [
            (0.8, "agents", { [weak self] in
                guard let self else { return }
                self.agentConfig.refresh()
                self.usageService.loadAgentStats()
            }),
            (1.5, "skills+memory", { [weak self] in
                guard let self else { return }
                self.skillMemory.refresh()
                self.usageService.loadSkillStats()
                // 统计卡的「本周命中」也预热，否则数字要等进页面才出
                self.usageService.loadSkillRanking(
                    source: nil, from: UsageService.DashboardPeriod.week.startDate, to: Date())
            }),
            (3.0, "plans", { [weak self] in self?.plans.refresh() }),
        ]
        for step in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) { [weak self] in
                MainActor.assumeIsolated {
                    step.run()
                    self?.logLine("知识库预热启动 \(step.label)")
                }
            }
        }
    }

    /// 知识面全文索引重建：技能/记忆/指令/计划的最新快照喂给索引器（索引器自己做增量 diff）。
    /// 两个 lastScanAt 都非 nil 才动手——只要有一方还没扫完，它的 knowledgeSnapshot() 就是空集，
    /// index() 的 prune 会把另一方已持久化的全部 doc 当"已消失"删光，启动时先扫完的那个会
    /// 触发一次误清空、每次启动都全量重建。
    private func reindexKnowledge() {
        guard skillMemory.lastScanAt != nil, plans.lastScanAt != nil else { return }
        let snapshot = skillMemory.knowledgeSnapshot()
        knowledgeIndexer.index(
            skills: snapshot.skills, memories: snapshot.memories,
            plans: plans.knowledgeSnapshot())
    }

    /// 外观主题：system=跟随系统（nil）/ light / dark
    private static func applyAppearance(_ mode: String) {
        switch mode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// 点击 Dock 图标（或无窗口时重新打开）→ 前置主窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        mainWindow?.show()
        return true
    }

    /// ⌘K 菜单入口：先前置显示主窗口，再发面板开关通知——主窗口不可见时通知仍会送达
    /// PopoverRootView（视图树不因 orderOut 销毁），若只 post 不显示窗口，paletteVisible
    /// 会在用户看不见的地方悄悄翻转。这里保证翻转发生时窗口已经可见。
    func showPalette() {
        mainWindow?.show()
        NotificationCenter.default.post(name: .eurekaToggleCommandPalette, object: nil)
    }

    private func handle(_ event: TaskEvent, isStale: Bool) {
        // 终端归属先落库，且**不受 isStale 影响**：它是历史事实（这个会话确实在那个终端跑过），
        // 与写 history 同待遇。放在过期闸门之前，否则积压事件带来的绑定会被丢掉。
        if let terminal = event.terminal {
            usageService.recordTerminal(
                source: event.source, sessionId: event.sessionId,
                binding: terminal, at: event.timestamp)
        }
        // 积压的"存活信号"不进状态机：孤立的过期心跳/等待/会话开始
        // 不代表现在还活着，照单全收会造出一堆幽灵会话
        if isStale {
            switch event.kind {
            case .activity, .waiting, .sessionStarted, .contextUpdate, .titleUpdate,
                 .subagentsUpdated, .toolPending, .compacting:
                // toolPending / compacting 同属"存活信号"：一条几分钟前的
                // 「即将执行 Bash」不代表现在还在跑，照收会造出幽灵会话
                return
            case .taskStarted, .taskFinished, .sessionEnded:
                break  // 开始/结束要进历史与配对
            }
        }
        applyToUI(effects: store.apply(event), isStale: isStale)
    }

    /// 无 hook 会话的终端归属探测：15 秒一轮，且**仅在确实有"缺归属的活跃会话"时**才动。
    ///
    /// 覆盖没有 relay 的七个源，以及没装 Claude hooks 的用户 ——「不装 hook 也能用」是既有原则。
    /// 无事可做时一次 syscall 都不做（`probe(wanted: [])` 立即返回）。
    private func startTerminalProbing() {
        terminalProbeTimer = Timer.scheduledTimer(
            withTimeInterval: 15, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.probeMissingTerminals() }
        }
    }

    private func probeMissingTerminals() {
        // 只查缺归属的会话；并且**同 (源, cwd) 有多个会话时整组跳过** ——
        // 按 cwd 匹配无法分辨谁是谁，宁可没有也不给错的（探测侧也有同样的保护）。
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
            // 找回那个唯一的会话（探测按 (源, cwd) 归组，此处对回去）
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

    /// 智能静音：你正看着该会话所在的终端应用时，完成卡就不必再弹了（你已经看见了）。
    ///
    /// **判定只到应用级**（分不清标签页）：开了 5 个 iTerm 标签、任意一个在前台都算"在看"。
    /// 因此调用点必须遵守一条硬规则 —— **等待授权卡永不静音**：那是需要你动手的阻塞提示，
    /// 因为"某个 iTerm 标签在前台"就把它藏掉，代价是你干等着而 agent 一直卡住。
    private func shouldSuppressCard(terminal: TerminalBinding?) -> Bool {
        guard settings.suppressCardWhenTerminalFrontmost, let terminal else { return false }
        return TerminalActivator.isFrontmost(terminal)
    }

    /// 把状态机副作用投影到 UI 与历史（积压/过期事件只入历史，不弹岛）
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
                if !isStale && wantCard {
                    island.viewModel.enqueueFinished(task)
                }
                // 系统通知只看开关，不做"正在看终端"静音 —— 它正是为看不见屏幕时准备的
                if !isStale, let note = SystemEventNotifications.forFinished(
                    task, master: settings.eventSystemNotifyEnabled,
                    completion: settings.notifyCompletion, error: settings.notifyError) {
                    notificationService.postEvent(note)
                }
                if !isStale {
                    mascotController?.viewModel.showFinished(success: task.outcome == .success)
                }
            case .taskWaiting(let task):
                logLine("等待 \(task.id) \(task.title ?? "")")
                // 只有「等待输入」这种非阻塞的才允许静音；
                // 「等待授权」永远弹 —— 应用级判定分不清标签页，藏错了你会白等
                let suppressible: Bool
                if case .waiting(.idle, _) = task.phase {
                    suppressible = shouldSuppressCard(terminal: task.terminal)
                } else {
                    suppressible = false
                }
                if !isStale && settings.notifyWaiting && !suppressible {
                    island.viewModel.enqueueWaiting(task)
                }
                if !isStale, let note = SystemEventNotifications.forWaiting(
                    task, master: settings.eventSystemNotifyEnabled,
                    waiting: settings.notifyWaiting) {
                    notificationService.postEvent(note)
                }
            case .activeTasksChanged:
                break
            }
        }
        island.viewModel.updateActiveTasks(
            store.sortedActiveTasks, idle: store.sortedIdleTasks)
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
        logLine("active=\(tasks.count) waiting=\(waitingCount) idle=\(store.sortedIdleTasks.count)")
    }

    /// 开发模式可观测性：stdout 单行日志，e2e 脚本据此断言（.app 包内运行时无害）
    private func logLine(_ message: String) {
        print("[eureka] \(message)")
        fflush(stdout)
    }
}
