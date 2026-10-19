import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// Offscreen-renders every Dynamic Island state to PNG: visual walkthroughs/self-checks without
/// Screen Recording permission.
@MainActor
enum PreviewRenderer {
    static func renderAll(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let notched = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            safeAreaTopInset: 32, notchWidth: 196, menuBarHeight: 32)
        let plain = IslandGeometry.ScreenInfo(
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            safeAreaTopInset: 0, notchWidth: nil, menuBarHeight: 24)

        let now = Date()
        let running1 = AgentTask(
            source: .claude, sessionId: "p1", title: L10n.text("Refactor the user authentication module", zhHans: "重构用户认证模块"),
            cwd: "/Users/me/work/auth-service", startedAt: now.addingTimeInterval(-754))
        let running2 = AgentTask(
            source: .codex, sessionId: "p2", title: L10n.text("Fix failing CI tests", zhHans: "修复 CI 失败用例"),
            cwd: "/Users/me/work/ci", startedAt: now.addingTimeInterval(-135))
        let running3 = AgentTask(
            source: .grok, sessionId: "p5", title: L10n.text("Complete semantic layer cache tags", zhHans: "补全语义层缓存标签"),
            cwd: "/Users/me/work/semantic-layer", startedAt: now.addingTimeInterval(-48))
        let running4 = AgentTask(
            source: .antigravity, sessionId: "p6", title: nil,
            cwd: "/Users/me/work/agy-app", startedAt: now.addingTimeInterval(-20))
        let running5 = AgentTask(
            source: .kimi, sessionId: "p7", title: L10n.text("Organize membership quota documentation", zhHans: "梳理会员配额文档"),
            cwd: "/Users/me/work/kimi-docs", startedAt: now.addingTimeInterval(-66))
        var waitingTask = AgentTask(
            source: .claude, sessionId: "p3", title: L10n.text("Batch update dependency versions", zhHans: "批量更新依赖版本"),
            cwd: "/Users/me/work/deps", startedAt: now.addingTimeInterval(-301),
            phase: .waiting(.permission, since: now.addingTimeInterval(-20)))
        // The point of a waiting-for-permission card is "what is being requested" (tool + target
        // from PreToolUse), not just "waiting for permission". Session identity is carried by the
        // subtitle's project + #session number.
        waitingTask.currentActivity = "Bash"
        waitingTask.currentToolDetail = "rm -rf node_modules/"
        let finished = FinishedTask(
            source: .claude, sessionId: "p1", title: L10n.text("Refactor the user authentication module", zhHans: "重构用户认证模块"),
            cwd: "/Users/me/work/auth-service",
            startedAt: now.addingTimeInterval(-754), finishedAt: now, outcome: .success)
        let errored = FinishedTask(
            source: .codex, sessionId: "p4", title: L10n.text("Migrate the legacy data pipeline", zhHans: "迁移旧数据管道"),
            cwd: "/Users/me/work/pipeline",
            startedAt: now.addingTimeInterval(-95), finishedAt: now, outcome: .error,
            detail: L10n.text("API Error: 403 Request not allowed", zhHans: "API 错误：403 请求不被允许"))

        func snapshot(_ name: String, screen: IslandGeometry.ScreenInfo, configure: (IslandViewModel) -> Void) {
            let vm = IslandViewModel()
            vm.updateScreen(screen)
            configure(vm)
            if vm.display == .taskList {
                // 排版高度须与 IslandGeometry.taskListHeight 一致：小了内容被裁，大了卡底留空
                let card = TaskListCardView(
                    tasks: vm.activeTasks, idleTasks: vm.idleTasks,
                    showStartTime: vm.showStartTime, scale: vm.uiScale,
                    centerGap: vm.pillCenterGap, expandedTaskId: vm.expandedSubagentTaskId)
                let measured = NSHostingView(rootView: card.frame(width: vm.contentSize.width))
                    .fittingSize.height
                print("任务列表高度 \(name)：排版 \(measured) / 计算 \(vm.contentSize.height)")
            }
            let root = IslandRootView(viewModel: vm)
                .frame(width: vm.layout.panelSize.width, height: vm.layout.panelSize.height)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            guard
                let image = renderer.nsImage,
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else {
                print("渲染失败: \(name)")
                return
            }
            let url = dir.appendingPathComponent("\(name).png")
            try? png.write(to: url)
            print("已渲染 \(url.path)")
        }

        snapshot("1-compact-notched", screen: notched) {
            $0.updateActiveTasks([running1, running2, running3, running4, running5])
        }
        snapshot("2-compact-plain", screen: plain) {
            $0.updateActiveTasks([running1])
        }
        snapshot("3-compact-waiting", screen: notched) {
            $0.updateActiveTasks([running1, waitingTask])
        }
        snapshot("4-card-finished", screen: notched) {
            $0.updateActiveTasks([running2])
            $0.enqueueFinished(finished)
        }
        snapshot("5-card-error", screen: notched) {
            $0.enqueueFinished(errored)
        }
        // 完成卡按时收起、没有运行中任务：胶囊留下未读完成标记，不再整个隐藏
        snapshot("5b-compact-unread", screen: notched) {
            $0.enqueueFinished(finished)
            $0.expireCurrentCard()
        }
        // 设计稿收缩态：两个来源在跑（亮 + 青点），一个来源只剩空闲会话（变暗），空闲会话 ctx 92% 亮右翼告警
        snapshot("5d-compact-ctx-alert", screen: notched) {
            var hot = AgentTask(
                source: .gemini, sessionId: "hot-idle", title: "方案需要继续增加",
                cwd: "/Users/me/work/one-agent",
                startedAt: now.addingTimeInterval(-3600), phase: .idle)
            hot.contextUsedPercent = 92
            $0.updateActiveTasks([running1, running2], idle: [hot])
        }
        snapshot("5c-compact-running-unread", screen: notched) {
            $0.updateActiveTasks([running2])
            $0.enqueueFinished(finished)
            $0.expireCurrentCard()
        }
        snapshot("6-card-waiting", screen: notched) {
            $0.updateActiveTasks([waitingTask])
            $0.enqueueWaiting(waitingTask)
        }
        snapshot("7-card-queued", screen: notched) {
            $0.enqueueFinished(finished)
            $0.enqueueFinished(errored)
        }
        snapshot("9-card-wellness", screen: notched) {
            $0.updateActiveTasks([running1])
            $0.enqueueNotice(IslandNotice(
                id: "preview",
                emoji: "🧘",
                headline: L10n.text("You've been vibe coding for 2 hours", zhHans: "连续 vibe coding 2 小时了"),
                body: L10n.text("Stand up, stretch, and have some water—I'll keep an eye on your tasks.", zhHans: "站起来伸个懒腰、喝口水吧——任务有我盯着。")))
        }
        snapshot("10-card-alert", screen: notched) {
            $0.enqueueAlert(RiskAlert(
                opId: "preview-alert", source: .claude, sessionId: "p1",
                ruleId: "rm-rf", ruleTitle: L10n.text("Recursively delete absolute/home directory paths", zhHans: "递归删除绝对/家目录路径"),
                tool: "Bash", detail: "sudo rm -rf ~/Library/Caches",
                timestamp: now))
        }
        snapshot("8-tasklist", screen: notched) {
            var idle1 = AgentTask(
                source: .claude, sessionId: "0a1b2c3d-idle", title: L10n.text("Research the Calcite optimizer", zhHans: "Calcite 优化器调研"),
                cwd: "/Users/me/work/calcite",
                startedAt: now.addingTimeInterval(-7200), phase: .idle)
            idle1.lastActivityAt = now.addingTimeInterval(-1800)
            idle1.contextUsedPercent = 88
            var idle2 = AgentTask(
                source: .claude, sessionId: "9f8e7d6c-idle", title: nil,
                cwd: "/Users/me/work/metricflow",
                startedAt: now.addingTimeInterval(-3600), phase: .idle)
            idle2.lastActivityAt = now.addingTimeInterval(-300)
            var withActivity = running1
            withActivity.currentActivity = "Bash"
            // Concrete target string (from PreToolUse): checks long text like "Edit src/main.swift"
            // doesn't break the layout
            withActivity.currentToolDetail = "swift build -c release"
            withActivity.contextUsedPercent = 64
            // Compacting-context state: no other events arrive meanwhile, so it must be visible in
            // the list
            var compacting = running2
            compacting.isCompacting = true
            $0.updateActiveTasks([withActivity, compacting, waitingTask], idle: [idle1, idle2])
            $0.islandTapped()
        }
        snapshot("8b-tasklist-idle-only", screen: notched) {
            var idle = AgentTask(
                source: .claude, sessionId: "5e6f7a8b-idle", title: "方案需要继续增加：我提到 Analytics",
                cwd: "/Users/me/work/one-agent",
                startedAt: now.addingTimeInterval(-3600), phase: .idle)
            idle.lastActivityAt = now.addingTimeInterval(-120)
            idle.contextUsedPercent = 92
            $0.updateActiveTasks([], idle: [idle])
            $0.enqueueFinished(finished)
            $0.expireCurrentCard()
            $0.islandTapped()
        }
        snapshot("8c-tasklist-crowded-plain", screen: plain) {
            var idleTasks: [AgentTask] = []
            for index in 0..<5 {
                var idle = AgentTask(
                    source: .codex, sessionId: "idle-\(index)", title: "空闲会话 \(index)",
                    cwd: "/Users/me/work/idle", startedAt: now.addingTimeInterval(-7200),
                    phase: .idle)
                idle.lastActivityAt = now.addingTimeInterval(-Double(index + 1) * 360)
                idleTasks.append(idle)
            }
            $0.updateActiveTasks(
                [running1, running2, running3, running4, running5], idle: idleTasks)
            $0.islandTapped()
        }

        // Subagents: collapsed badge / three expanded states / capsule aggregate marker
        let subagents = [
            SubagentInfo(agentId: "a1", agentType: "Explore",
                         description: L10n.text("Locate the transcript parsing entry point", zhHans: "定位 transcript 解析入口"), status: .running,
                         currentActivity: "Grep"),
            SubagentInfo(agentId: "a2", agentType: "Plan",
                         description: L10n.text("Design subagent rendering for the Dynamic Island", zhHans: "设计灵动岛子代理渲染方案"), status: .completed),
            SubagentInfo(agentId: "a3", agentType: "claude-code-guide",
                         description: L10n.text("Verify the subagent directory format", zhHans: "核实子代理目录格式"), status: .failed),
        ]
        var withSubs = running1
        withSubs.currentActivity = "Task"
        withSubs.subagents = subagents

        snapshot("10-tasklist-subagents-collapsed", screen: notched) {
            $0.updateActiveTasks([withSubs, running2])
            $0.islandTapped()
        }
        snapshot("11-tasklist-subagents-expanded", screen: notched) {
            $0.updateActiveTasks([withSubs, running2])
            $0.islandTapped()
            $0.toggleSubagentExpansion(withSubs.id)
        }
        snapshot("12-compact-subagent-marker", screen: notched) {
            $0.updateActiveTasks([withSubs, running2])
        }
        // Crowded floating pill, reproduced from two real screenshots (2026-10-16): one source
        // (so the wing carries the "claude" word), a two-digit count, a waiting task, subagents
        // and a cross-day start time with a two-digit month. Neither the count nor the time may
        // wrap; the wings drop the word label / the subagent marker before that happens.
        snapshot("13-compact-crowded-floating", screen: plain) {
            var crowd: [AgentTask] = [waitingTask, withSubs]
            for index in 0..<28 {
                crowd.append(AgentTask(
                    source: .claude, sessionId: "crowd-\(index)", title: L10n.format("Session %@", zhHans: "会话 %@", String(index)),
                    cwd: "/Users/me/work/crowd",
                    startedAt: now.addingTimeInterval(-Double(index) * 600)))
            }
            crowd[0].startedAt = now.addingTimeInterval(-6 * 86400)  // two-digit month, e.g. 10/10
            $0.isFloating = true
            $0.showStartTime = true
            $0.updateActiveTasks(crowd)
        }
    }

    /// Offscreen-renders the knowledge pages (Plans/Skills/Memory/Agents × card/list) for visual
    /// walkthroughs. Real services scan local data; screenshots are taken after the scan finishes.
    /// Width matches the main window's content area.
    @MainActor
    static func renderKnowledge(to directory: String, style: ThemeStyle = .classic) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        ThemeStyle.current = style
        defer { ThemeStyle.current = .classic }

        let plans = PlansService()
        let skillMemory = SkillMemoryService()
        let agents = AgentConfigService()
        let usage = UsageService()
        plans.refresh(force: true)
        skillMemory.refresh()
        agents.refresh()

        // Wait for all three scans to finish (the CLI has no main runloop → pump manually; the
        // first full session parse may take minutes, capped at 300s)
        let deadline = Date().addingTimeInterval(300)
        while (plans.scanning || skillMemory.scanning || agents.scanning), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // Print memories by the counting rule: memoryTotal includes entries inside memory
        // libraries, memories is only standalone list entries — both numbers are needed, otherwise
        // you can't tell whether folding took effect
        print("扫描结束：plans=\(plans.totalCount) "
            + "skills=\(skillMemory.skills.count) "
            + "memoryTotal=\(skillMemory.memoryTotal) "
            + "standalone=\(skillMemory.memories.count) "
            + "instructions=\(skillMemory.instructionTotal) "
            + "libraries=\(skillMemory.libraries.count)"
            + "(\(skillMemory.libraries.map { "\($0.projectName):\($0.count)" }.joined(separator: ","))) "
            + "claudeAgents=\(agents.claudeAgents.count) codexProfiles=\(agents.codexProfiles.count) "
            + "scanning=\(plans.scanning)/\(skillMemory.scanning)/\(agents.scanning)")

        // Rasterize via NSHostingView + cacheDisplay: offscreen, ImageRenderer doesn't materialize
        // Lazy containers/ScrollView, and dynamic NSColor and SF Symbols get distorted too; going
        // through AppKit layout and drawing is closer to the real window.
        @MainActor func snap<V: View>(_ name: String, _ view: V, dark: Bool = false,
                                      width: CGFloat = 780) {
            // Lay a window background underneath: the page's surfaceSecondary is a translucent
            // overlay, so transparent PNG areas would be wrong without it
            let hosting = NSHostingView(rootView: ZStack {
                Color(nsColor: .windowBackgroundColor)
                view
            })
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: 980)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { print("渲染失败: \(name)"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:])
            else { print("编码失败: \(name)"); return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("已渲染 \(name).png")
        }

        // One image per page for list + icons each (list by default, matching the design mock); a
        // wide window checks three-column card proportions; one dark spot check
        snap("knowledge-plans-list", PlansView(service: plans, initialLayout: .list))
        snap("knowledge-plans-cards", PlansView(service: plans, initialLayout: .cards))
        snap("knowledge-plans-cards-wide", PlansView(service: plans, initialLayout: .cards), width: 1270)
        snap("knowledge-skills-list",
             SkillMemoryView(service: skillMemory, mode: .skills, usageService: usage,
                             initialLayout: .list))
        snap("knowledge-skills-cards",
             SkillMemoryView(service: skillMemory, mode: .skills, usageService: usage,
                             initialLayout: .cards))
        snap("knowledge-skills-cards-wide",
             SkillMemoryView(service: skillMemory, mode: .skills, usageService: usage,
                             initialLayout: .cards),
             width: 1270)
        snap("knowledge-memory-list",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .list))
        snap("knowledge-memory-cards",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .cards))
        // Memory library sub-page + graph: both are reachable only by clicking, so offscreen
        // rendering must inject initial state
        snap("knowledge-memory-library",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLibraryKey: skillMemory.libraries.first?.key))
        snap("knowledge-memory-graph",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .graph))
        snap("knowledge-memory-graph-dark",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .graph), dark: true)
        // Memory detail + one-hop relation mini-graph: pick the entry with the most
        // references/sources (with no relations that graph doesn't render, hiding problems)
        if let busiest = skillMemory.libraries.first?.entries
            .max(by: { ($0.links.count + ($0.originSessionId == nil ? 0 : 1))
                < ($1.links.count + ($1.originSessionId == nil ? 0 : 1)) }) {
            snap("knowledge-memory-detail",
                 SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                                 initialLibraryKey: skillMemory.libraries.first?.key,
                                 initialMemoryPath: busiest.path))
        }
        snap("knowledge-instructions-list",
             SkillMemoryView(service: skillMemory, mode: .instructions, usageService: usage,
                             initialLayout: .list))
        // Search state: hit-count capsule + round clear button (the focus gradient ring needs real
        // keyboard focus, impossible offscreen)
        skillMemory.searchText = "arkcli"
        snap("knowledge-skills-search",
             SkillMemoryView(service: skillMemory, mode: .skills, usageService: usage,
                             initialLayout: .list))
        skillMemory.searchText = ""
        snap("knowledge-agents-list",
             AgentsView(service: agents, usageService: usage, initialLayout: .list))
        snap("knowledge-agents-cards",
             AgentsView(service: agents, usageService: usage, initialLayout: .cards))
        snap("knowledge-plans-list-dark",
             PlansView(service: plans, initialLayout: .list), dark: true)

        // MCP page: list / icons / detail (cross-source matrix + every config location). Scanning
        // takes milliseconds, so a short wait suffices.
        let mcp = MCPService()
        mcp.refresh()
        let mcpDeadline = Date().addingTimeInterval(30)
        while mcp.scanning, Date() < mcpDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("MCP 扫描结束：servers=\(mcp.servers.count)")
        snap("knowledge-mcp-list", MCPView(service: mcp, usageService: usage, initialLayout: .list))
        snap("knowledge-mcp-cards", MCPView(service: mcp, usageService: usage, initialLayout: .cards))
        if let first = mcp.servers.first {
            snap("knowledge-mcp-detail",
                 MCPView(service: mcp, usageService: usage, initialDetailName: first.name))
            snap("knowledge-mcp-form-edit",
                 MCPView(service: mcp, usageService: usage, initialFormTarget: MCPFormTarget(
                    id: "edit", mode: .form, editing: first)))
        }
        // One more detail for a remote server: auth routing (OAuth / header secret) only shows for
        // remote
        if let remote = mcp.servers.first(where: { $0.transport != "stdio" }) {
            snap("knowledge-mcp-detail-remote",
                 MCPView(service: mcp, usageService: usage, initialDetailName: remote.name))
        }
        snap("knowledge-mcp-form-new",
             MCPView(service: mcp, usageService: usage, initialFormTarget: MCPFormTarget(id: "new", mode: .quick)))
        snap("knowledge-mcp-form-manual",
             MCPView(service: mcp, usageService: usage, initialFormTarget: MCPFormTarget(id: "new", mode: .form)))
        snap("knowledge-mcp-list-dark", MCPView(service: mcp, usageService: usage, initialLayout: .list), dark: true)
    }

    /// Offscreen-renders the "shell": the sidebar (with the brand area) and the audit page, light
    /// and dark.
    ///
    /// Why it exists: the sidebar and audit page previously had **no automated way to look at them** (only the Dynamic Island and badges had renderers),
    /// so changes to logo size, group-label count, or row density needed a human to compare by eye. Two must-checks are only possible with renders:
    ///  1. Is the brand mark clearly larger than the nav icons, with highlight and shadow (not a
    ///     flat square)?
    ///  2. **At the minimum window height of 540, are the five group labels + brand footnote
    ///     clipped?** — `MainWindowController` uses `hosting.sizingOptions = []`, so overflowing
    ///     content is clipped rather than growing the window.
    @MainActor
    static func renderShell(to directory: String, style: ThemeStyle = .classic) {
        // Theme fonts (Space Grotesk/Mono) must be registered before any view renders; registration
        // failure falls back to the system font
        ThemeFonts.register()
        ThemeStyle.current = style
        defer { ThemeStyle.current = .classic }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // NSHostingView + cacheDisplay (same as renderKnowledge: ImageRenderer distorts offscreen)
        @MainActor func snap<V: View>(
            _ name: String, _ view: V, dark: Bool = false,
            width: CGFloat = 780, height: CGFloat = 980
        ) {
            let hosting = NSHostingView(rootView: ZStack {
                style == .classic ? Color(nsColor: .windowBackgroundColor) : Theme.windowBackground
                view
            })
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { print("渲染失败: \(name)"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:])
            else { print("编码失败: \(name)"); return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("已渲染 \(name).png")
        }

        // MARK: Sidebar
        func sidebar(selected: PopoverRootView.Tab) -> some View {
            SidebarView(
                selected: selected,
                limitsBadge: ("67%", Theme.gold),
                appVersion: "0.15.0",
                onSelect: { _ in })
        }
        // A separate comparison sheet for the enlarged brand mark (26 = footnote, 44 = About card,
        // 18 = old size baseline)
        snap("shell-logo-sizes", HStack(spacing: 24) {
            ForEach([18.0, 26.0, 44.0, 88.0], id: \.self) { size in
                VStack(spacing: 8) {
                    LuluLogoTile(size: size)
                    Text("\(Int(size))pt").font(.system(size: 10))
                }
            }
        }
        .padding(30), width: 320, height: 160)
        snap("shell-sidebar", sidebar(selected: .audit), width: SidebarView.width, height: 980)
        snap("shell-sidebar-dark", sidebar(selected: .audit), dark: true,
             width: SidebarView.width, height: 980)
        // Measured minimum window height. Note `MainWindowController`'s `window.minSize` 540 is the
        // **window frame**, including the title bar (~28pt) → the content area is really only ~512.
        // Render one more at 470 to see how much headroom is left.
        snap("shell-sidebar-min-height", sidebar(selected: .history),
             width: SidebarView.width, height: 512)
        snap("shell-sidebar-tight", sidebar(selected: .history),
             width: SidebarView.width, height: 470)

        // MARK: Audit page (real local data)
        let audit = AuditService()
        let installer = InstallerService()
        let settings = AppSettings()
        // AppSettings.init resets ThemeStyle.current from the persisted preference, so restate the
        // render parameters here
        ThemeStyle.current = style
        let notifications = NotificationService()
        audit.start()
        installer.refresh()
        // The service reads the DB on its own serial queue and publishes @Published back on main,
        // but the CLI has no main runloop → pump manually. ⚠️ Must pump for a fixed time
        // **unconditionally**: pumping earlier with `while events.isEmpty`, on the second query
        // switch events still held the previous batch (non-empty), the loop exited at once, and the
        // capture showed **the previous query's stale data** — in the "risk only" image the chip
        // was red while the list was the full set.
        @MainActor func loadAndSettle(_ query: AuditRepo.Query, seconds: Double = 2.5) {
            audit.load(query: query, page: 1, pageSize: 100)
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        // The first round waits for the DB to open + the first scan, so give it plenty of time
        loadAndSettle(AuditRepo.Query(), seconds: 8)
        print("审计读库：total=\(audit.total) risk=\(audit.riskTotal) "
            + "sources=\(audit.sourceCounts.count) kinds=\(audit.kindCounts.count)")

        // The config-consistency card needs real data to have content (it takes no space while
        // lastScanAt == nil)
        let skillMemory = SkillMemoryService()
        skillMemory.refresh()
        let scanDeadline = Date().addingTimeInterval(180)
        while skillMemory.scanning, Date() < scanDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let consistency = skillMemory.consistencyReport
        print("一致性检查：指令缺口 \(consistency.instructionGaps.count) "
            + "技能缺口 \(consistency.skillGaps.count) 记忆漂移 \(consistency.libraryDrifts.count)")

        func auditPage(riskOnly: Bool = false, keyword: String = "") -> some View {
            AuditView(
                service: audit, installer: installer, settings: settings,
                notificationService: notifications, skillMemory: skillMemory,
                initialRiskOnly: riskOnly, initialKeyword: keyword)
        }
        snap("shell-audit", auditPage())
        snap("shell-audit-dark", auditPage(), dark: true)
        // Wide window: do the source chips wrap to two lines, do the row title lines push into each
        // other
        snap("shell-audit-wide", auditPage(), width: 1270)
        // Sidebar + audit page side by side (checks font size/spacing continuity across the
        // divider). Placed before the filter changes: AuditService is singleton-style shared state,
        // so this image would be empty after the query switch below.
        snap("shell-full", HStack(spacing: 0) {
            sidebar(selected: .audit)
            Divider()
            auditPage()
        }, width: SidebarView.width + 1 + 780)

        // Risk only: both the inline risk TagChip and the overview card's "Risk N" must appear
        loadAndSettle(AuditRepo.Query(riskOnly: true))
        print("仅风险：\(audit.events.count) 行 / total=\(audit.total)")
        snap("shell-audit-risk", auditPage(riskOnly: true))
        // Empty state (nothing matches): confirm it goes through EmptyStateView rather than a blank
        // area
        let nonsense = "zzz-no-such-command-zzz"
        loadAndSettle(AuditRepo.Query(keyword: nonsense))
        print("空态：\(audit.events.count) 行 / total=\(audit.total)")
        snap("shell-audit-empty", auditPage(keyword: nonsense), height: 520)

        // Capture off: hooksHint yields to captureOffHint (the two hint cards should never appear
        // together)
        loadAndSettle(AuditRepo.Query())
        settings.auditEnabled = false
        snap("shell-audit-capture-off", auditPage(), height: 620)
        settings.auditEnabled = true  // don't leave render side effects in the real preferences

        // Render the gear popover separately: the popover depends on a real window and isn't
        // rasterized when rendering the whole page offscreen. This version holds the 4 toggles
        // moved over from the Settings → Audit card, which must carry their own switch/small/11.5
        // style.
        let auditView = AuditView(
            service: audit, installer: installer, settings: settings,
            notificationService: notifications, skillMemory: skillMemory)
        snap("shell-audit-settings", auditView.settingsPopover, width: 340, height: 300)
    }

    /// Offscreen-render the remaining pages: history / sessions (two-pane + detail) / usage (all six
    /// sub-tabs) / limits / prompts (list + detail) / settings (five sections) / ⌘K palette.
    ///
    /// These pages had no automated way to be looked at (knowledge pages and the audit page
    /// each have a renderer; nothing covered the rest). Driven by real local data, same
    /// skeleton as `renderShell` / `renderKnowledge`. Services publish from their own queues
    /// and the CLI has no main runloop, so every wait pumps the runloop by hand.
    @MainActor
    static func renderPages(to directory: String, style: ThemeStyle = .classic) {
        ThemeFonts.register()
        ThemeStyle.current = style
        defer { ThemeStyle.current = .classic }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        @MainActor func snap<V: View>(
            _ name: String, _ view: V, dark: Bool = false,
            width: CGFloat = 780, height: CGFloat = 980
        ) {
            let hosting = NSHostingView(rootView: ZStack {
                style == .classic ? Color(nsColor: .windowBackgroundColor) : Theme.windowBackground
                view
            })
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { print("渲染失败: \(name)"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:])
            else { print("渲染失败: \(name)"); return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("已渲染 \(name).png")
        }

        @MainActor func pump(_ seconds: Double) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        @MainActor func wait(_ label: String, upTo seconds: Double, until done: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !done(), Date() < deadline { pump(0.2) }
            if !done() { print("等待超时：\(label)") }
        }

        let settings = AppSettings()
        // AppSettings.init resets ThemeStyle.current from the persisted preference
        ThemeStyle.current = style
        let usage = UsageService()
        let sessions = SessionBrowserService()
        let skillMemory = SkillMemoryService()
        let plans = PlansService()
        let prompts = PromptsService(sessionBrowser: sessions)
        let limits = RateLimitsService()
        let installer = InstallerService()
        let cliTools = CLIToolsService()
        let notifications = NotificationService()
        let update = UpdateService()
        let sync = SyncService()
        let palette = CommandPaletteService(
            sessionBrowser: sessions, skillMemory: skillMemory, plans: plans,
            prompts: prompts, settings: settings)

        usage.start()
        installer.refresh()
        cliTools.detectLocal()
        skillMemory.refresh()
        sessions.refresh()
        limits.refresh()
        wait("用量汇总", upTo: 180) { usage.summary != nil }
        wait("会话索引", upTo: 300) { !sessions.scanning }
        wait("知识扫描", upTo: 180) { !skillMemory.scanning }
        prompts.refresh()
        wait("Prompt 库", upTo: 120) { !prompts.scanning }
        print("数据就绪：history=\(usage.recentHistory.count) "
            + "sessions=\(sessions.summary.sessionCount) prompts=\(prompts.totalCount) "
            + "codex=\(limits.codex != nil) grok=\(limits.grok != nil) "
            + "antigravity=\(limits.antigravity != nil)")

        // MARK: History
        let history = HistoryView(
            tasks: usage.recentHistory, dailyOutcomes: usage.historyDailyOutcomes,
            tokens: usage.historyTokens, runningTasks: usage.runningTasks,
            terminals: sessions.terminals, settings: settings)
        snap("pages-history", history)
        snap("pages-history-dark", history, dark: true)
        snap("pages-history-min", history, width: 675, height: 512)

        // MARK: Sessions (two-pane + detail)
        // Prefer a recent session that produced memories so the session-artifacts row is in the shot
        let candidates = sessions.flatSessions + sessions.groups.flatMap(\.sessions)
        let withArtifacts = candidates.prefix(200).first {
            !skillMemory.memories(relatedTo: $0.id).isEmpty
        }
        if let first = withArtifacts ?? candidates.first {
            sessions.select(first)
            wait("对话记录", upTo: 60) { !sessions.transcriptLoading }
            pump(1)
        }
        func sessionsPage() -> SessionsView {
            SessionsView(service: sessions, settings: settings, skillMemory: skillMemory, plans: plans)
        }
        snap("pages-sessions", sessionsPage(), width: 1270)
        snap("pages-sessions-min", sessionsPage(), width: 675, height: 512)
        snap("pages-sessions-dark", sessionsPage(), dark: true, width: 1270)
        if sessions.selected != nil {
            snap("pages-session-lineage-list",
                 TurnLineageView(
                    sessionName: sessions.selected?.displayName ?? L10n.text("Session", zhHans: "会话"),
                    turns: TurnSlicer.slice(sessions.transcript), onBack: {}),
                 width: 1270)
        }

        // MARK: Usage: all six sub-tabs (this month; onAppear is unreliable offscreen, so load by hand)
        let month = UsageService.DashboardPeriod.month
        let range = (from: month.startDate, to: Date())
        usage.loadRecords(page: 1, pageSize: 50, source: nil, from: range.from, to: range.to)
        usage.loadModelTotals(from: range.from, to: range.to)
        usage.loadProjectTotals(from: range.from, to: range.to)
        usage.loadToolCalls(source: nil, from: range.from, to: range.to)
        usage.loadTrend(from: range.from, to: range.to)
        usage.loadSessionTotals(from: range.from, to: range.to, source: nil)
        usage.loadHeatmap(from: range.from, to: range.to, source: nil)
        usage.loadSkillStats()
        usage.loadMCPStats()
        usage.loadAgentStats()
        usage.loadSkillRanking(from: range.from, to: range.to)
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())
            ?? DateInterval(start: Date(), duration: 7 * 86400)
        usage.loadWeeklyReport(weekStart: week.start, weekEnd: week.end)
        wait("用量明细", upTo: 60) {
            !usage.records.isEmpty && !usage.modelTotals.isEmpty && usage.weeklyReport != nil
        }
        pump(1)
        print("用量明细：records=\(usage.records.count)/\(usage.recordTotal) "
            + "models=\(usage.modelTotals.count) projects=\(usage.projectTotals.count) "
            + "sessions=\(usage.sessionTotals.count) heatmap=\(usage.heatmapCells.count) "
            + "weekly=\(usage.weeklyReport != nil)")
        let subTabs: [(UsageDashboardView.SubTab, String)] = [
            (.log, "log"), (.models, "models"), (.projects, "projects"),
            (.sessions, "sessions"), (.tools, "tools"), (.weekly, "weekly"),
        ]
        for (tab, suffix) in subTabs {
            let view = UsageDashboardView(
                usageService: usage, sessionBrowser: sessions,
                initialPeriod: .month, initialSubTab: tab)
            snap("pages-usage-\(suffix)", view, width: 1270, height: 2000)
        }
        snap("pages-usage-log-min",
             UsageDashboardView(usageService: usage, sessionBrowser: sessions,
                                initialPeriod: .month, initialSubTab: .log),
             width: 675, height: 1600)
        snap("pages-usage-log-dark",
             UsageDashboardView(usageService: usage, sessionBrowser: sessions,
                                initialPeriod: .month, initialSubTab: .log),
             dark: true, width: 1270, height: 2000)
        // Sidebar + usage page side by side (check type size / spacing across the divider)
        snap("pages-full-usage", HStack(spacing: 0) {
            SidebarView(
                selected: .usage, limitsBadge: ("9%", Theme.enabledGreen),
                historyBadge: "\(usage.recentHistory.count)", appVersion: "0.35.1",
                onSelect: { _ in })
            Divider()
            UsageDashboardView(usageService: usage, sessionBrowser: sessions,
                               initialPeriod: .month, initialSubTab: .models)
        }, width: SidebarView.width + 1 + 1270, height: 1400)

        // MARK: Limits
        pump(2)
        snap("pages-limits", LimitsPanelView(service: limits, settings: settings), height: 700)
        snap("pages-limits-dark", LimitsPanelView(service: limits, settings: settings),
             dark: true, height: 700)

        // MARK: Prompts (list + detail)
        snap("pages-prompts",
             PromptsView(service: prompts, sessionBrowser: sessions, skillMemory: skillMemory))
        snap("pages-prompts-wide",
             PromptsView(service: prompts, sessionBrowser: sessions, skillMemory: skillMemory),
             width: 1270)
        if let entry = prompts.prompts.first {
            snap("pages-prompt-detail",
                 PromptsView(service: prompts, sessionBrowser: sessions,
                             skillMemory: skillMemory, initialDetail: entry))
        }

        // MARK: Settings: five sections
        for section in SettingsView.SettingsSection.allCases {
            let view = SettingsView(
                section: .constant(section), settings: settings, installer: installer,
                usageService: usage, cliTools: cliTools, notificationService: notifications,
                updateService: update, syncService: sync)
            snap("pages-settings-\(section)", view, height: 1200)
        }
        snap("pages-settings-general-dark",
             SettingsView(
                section: .constant(.general), settings: settings, installer: installer,
                usageService: usage, cliTools: cliTools, notificationService: notifications,
                updateService: update, syncService: sync),
             dark: true, height: 1200)

        // MARK: ⌘K palette
        palette.query = "metricflow"
        wait("⌘K 命中", upTo: 20) { !palette.hits.isEmpty }
        print("⌘K 命中：\(palette.hits.count)")
        snap("pages-palette", VStack {
            CommandPaletteView(service: palette, onClose: {})
                .padding(.top, 40)
            Spacer()
        }, width: 700, height: 560)
    }

    /// Offscreen-renders the **turn lineage graph**.
    ///
    /// Input is **hand-written `TurnInput` literals** rather than real local sessions: acceptance is one specific shape
    /// (question → thinking fork → subagent pointing back at an existing Read → Edit⇄build retry loop → converging answer),
    /// which real sessions can't reproduce reliably, and offscreen rendering is the acceptance tool ⇒ **the baseline must be reproducible**.
    /// The precedent is `renderAll`: it renders the Dynamic Island entirely from hand-written `AgentTask`/`SubagentInfo` literals too.
    @MainActor
    static func renderLineage(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        @MainActor func snap<V: View>(
            _ name: String, _ view: V, dark: Bool = false,
            width: CGFloat = 780, height: CGFloat = 620
        ) {
            let hosting = NSHostingView(rootView: ZStack {
                Color(nsColor: .windowBackgroundColor)
                view
            })
            hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            hosting.frame = CGRect(x: 0, y: 0, width: width, height: height)
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
            else { print("渲染失败: \(name)"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:])
            else { print("编码失败: \(name)"); return }
            try? png.write(to: dir.appendingPathComponent("\(name).png"))
            print("已渲染 \(name).png")
        }

        /// Canvas + legend + one stats line, fixed size, no ScrollView/no Lazy → lowest
        /// rasterization risk
        @MainActor func board(
            _ turn: TurnInput, width: CGFloat, compact: Bool = false,
            expandedSubagents: Set<String> = []
        ) -> some View {
            let metrics = compact
                ? TurnGraphLayout.Metrics.compact(width: width)
                : TurnGraphLayout.Metrics.standard(width: width)
            let graph = TurnGraphBuilder.build(
                turn, options: .init(
                    maxColumns: metrics.maxColumns, expandedSubagents: expandedSubagents))
            let result = TurnGraphLayout.layout(graph, metrics: metrics)
            let diagnostics = TurnDiagnostics.evaluate(graph, promptChars: turn.promptText.count)
            print("  \(turn.turnIndex): 节点 \(result.nodes.count) 层 \(result.layerCount) "
                + "最宽 \(result.maxLayerWidth) 交叉 \(result.crossings) "
                + "画布 \(Int(result.canvasSize.height)) "
                + "降级 \(result.degraded.map { "\($0)" } ?? "无") "
                + "信号 \(diagnostics.signals.map(\.rule))")
            return TurnLineageBoardView(
                result: result, diagnostics: diagnostics, hasThinking: graph.hasThinking)
                .frame(width: width)
        }

        func step(
            _ kind: ToolKind, _ name: String, _ detail: String = "",
            batch: Int, index: Int, isError: Bool = false
        ) -> TurnInput.Step {
            TurnInput.Step(
                kind: kind, name: name, detail: detail, isError: isError,
                batch: batch, messageId: 1, stepIndex: index)
        }

        // Acceptance shape (the preview the user picked)
        let accepted = TurnInput(
            turnIndex: 7, promptMessageId: 0, promptText: L10n.text("Fix pagination on the audit page", zhHans: "修一下审计页的分页"),
            thinkingTexts: [L10n.text("Locate the pagination code first, then decide which layer to change", zhHans: "先定位分页代码在哪，再决定改哪一层")],
            steps: [
                step(.search, "Grep", "paginationBar", batch: 1, index: 0),
                step(.agent, "Explore", "定位分页实现", batch: 1, index: 1),
                step(.read, "Read", "/w/AuditView.swift", batch: 2, index: 2),
                step(.edit, "Edit", "/w/AuditView.swift", batch: 3, index: 3),
                step(.command, "Bash", "swift build", batch: 4, index: 4, isError: true),
                step(.read, "Read", "/w/AuditView.swift", batch: 5, index: 5),
                step(.edit, "Edit", "/w/AuditView.swift", batch: 6, index: 6),
                step(.command, "Bash", "swift build", batch: 7, index: 7),
            ],
            answerMessageIds: [9], answerText: L10n.text("Fixed; the pagination bar now has a page jump input", zhHans: "改好了，分页条现在有跳页输入框"))
        snap("lineage-golden-accepted", board(accepted, width: 780))
        snap("lineage-golden-accepted-dark", board(accepted, width: 780), dark: true)
        snap("lineage-golden-min-width", board(accepted, width: 674), height: 512)
        snap("lineage-golden-wide", board(accepted, width: 1270), width: 1270)
        snap("lineage-golden-compact", board(accepted, width: 780, compact: true))

        // Subagent expanded: its inner steps merge into the same graph, and files it reads are
        // deduped with the main flow → a **cross-boundary read-back edge** appears. That edge is
        // the whole reason for "expand inline instead of drawing a separate subgraph" (a separate
        // subgraph would cut it).
        var withSubagent = accepted
        withSubagent.turnIndex = 8
        withSubagent.steps[1].subSteps = [
            TurnInput.Step(kind: .search, name: "Grep", detail: "PaginationBar", batch: 1),
            TurnInput.Step(kind: .read, name: "Read", detail: "/w/AuditView.swift", batch: 2),
            TurnInput.Step(kind: .read, name: "Read", detail: "/w/Styles.swift", batch: 2),
        ]
        snap("lineage-golden-subagent-collapsed", board(withSubagent, width: 780))
        snap("lineage-golden-subagent-expanded", board(
            withSubagent, width: 780,
            expandedSubagents: ["Explore|定位分页实现"]), height: 700)

        // Claude shape: no plaintext thinking → don't fake thinking nodes, use a fork point instead
        var noThinking = accepted
        noThinking.thinkingTexts = []
        noThinking.turnIndex = 3
        snap("lineage-golden-no-thinking", board(noThinking, width: 780))

        // Pure chain: checks the spine is straight
        var chainSteps: [TurnInput.Step] = []
        for index in 0..<7 {
            chainSteps.append(step(
                .read, "Read", "/w/File\(index).swift", batch: index + 1, index: index))
        }
        snap("lineage-golden-chain", board(TurnInput(
            turnIndex: 1, promptMessageId: 0, promptText: L10n.text("Review each one", zhHans: "逐个看一遍"),
            steps: chainSteps, answerMessageIds: [1], answerText: L10n.text("Review complete", zhHans: "看完了")), width: 780))

        // 9 siblings of one kind in one layer: checks folding
        var wideSteps: [TurnInput.Step] = []
        for index in 0..<9 {
            wideSteps.append(step(.search, "Grep", "pattern-\(index)", batch: 1, index: index))
        }
        snap("lineage-golden-fold", board(TurnInput(
            turnIndex: 2, promptMessageId: 0, promptText: L10n.text("Search the entire codebase", zhHans: "全库找一遍"),
            steps: wideSteps, answerMessageIds: [1], answerText: L10n.text("Found it", zhHans: "找到了")), width: 780))

        // Worst-case readable state with 60 nodes
        var bigSteps: [TurnInput.Step] = []
        var cursor = 0
        for batchIndex in 0..<12 {
            for column in 0..<5 {
                bigSteps.append(step(
                    .read, "Read", "/w/mod\(batchIndex)/File\(column).swift",
                    batch: batchIndex + 1, index: cursor))
                cursor += 1
            }
        }
        snap("lineage-golden-60", board(TurnInput(
            turnIndex: 4, promptMessageId: 0, promptText: L10n.text("Read through the entire module", zhHans: "通读整个模块"),
            steps: bigSteps, answerMessageIds: [1], answerText: L10n.text("Finished reading", zhHans: "读完了")),
            width: 780), height: 1100)

        // Multiple read-backs + multiple retries: checks left/right lanes and corner-badge
        // degradation
        var laneSteps: [TurnInput.Step] = []
        cursor = 0
        for index in 0..<5 {
            laneSteps.append(step(
                .read, "Read", "/w/A\(index).swift", batch: cursor + 1, index: cursor))
            cursor += 1
            laneSteps.append(step(
                .edit, "Edit", "/w/A\(index).swift", batch: cursor + 1, index: cursor))
            cursor += 1
            laneSteps.append(step(
                .command, "Bash", "swift build", batch: cursor + 1, index: cursor,
                isError: index < 3))
            cursor += 1
            laneSteps.append(step(
                .read, "Read", "/w/A\(index).swift", batch: cursor + 1, index: cursor))
            cursor += 1
        }
        snap("lineage-golden-lanes", board(TurnInput(
            turnIndex: 5, promptMessageId: 0, promptText: L10n.text("Update all of these files", zhHans: "把这几个文件都改了"),
            steps: laneSteps, answerMessageIds: [1], answerText: L10n.text("All files updated", zhHans: "都改完了")),
            width: 780), height: 900)

        // Over the limit: checks it degrades instead of laying out
        var hugeSteps: [TurnInput.Step] = []
        for index in 0..<160 {
            hugeSteps.append(step(
                .command, "Bash", "echo \(index)", batch: index + 1, index: index))
        }
        snap("lineage-golden-degraded", board(TurnInput(
            turnIndex: 6, promptMessageId: 0, promptText: L10n.text("Run a batch of commands", zhHans: "跑一堆命令"),
            steps: hugeSteps, answerMessageIds: [1], answerText: L10n.text("All commands finished", zhHans: "跑完了")),
            width: 780), height: 320)

        // MARK: Real data (golden is the shape baseline; live answers "does real data crash it or look bad")
        // Use the default 30-day window: `rangeAll = true` widens the window to infinity with a cap of 2000,
        // which offscreen rendering can't wait for (and isn't what users see by default)
        let browser = SessionBrowserService()
        browser.refresh()
        // ⚠️ Wait for scanning to settle first, then pump some more **unconditionally**. Pumping
        // only until "results non-empty" fails: old results linger when data switches, the loop
        // exits at once and captures stale data (bitten before)
        let deadline = Date().addingTimeInterval(90)
        while browser.scanning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // Pick the session with the most turns, a reproducible rule (not "the first one") Depending
        // on the sort bucket a session may live in flatSessions or groups (SessionsView itself adds
        // both)
        let candidates = browser.flatSessions + browser.groups.flatMap(\.sessions)
        print("live 候选会话 \(candidates.count) 个")
        var best: (session: AgentSessionInfo, turns: [TurnInput])?
        for session in candidates.prefix(40) {
            let messages = TranscriptReader.load(session: session).messages
            let turns = TurnSlicer.slice(messages)
            if turns.count > (best?.turns.count ?? 0) { best = (session, turns) }
        }
        guard let picked = best, !picked.turns.isEmpty else {
            print("（本机没扫到可用会话，跳过 live 图）")
            return
        }
        let worst = picked.turns.enumerated().max { lhs, rhs in
            lhs.element.steps.count < rhs.element.steps.count
        }?.offset ?? 0
        print("live 会话 \(picked.session.id.prefix(8)) "
            + "来源 \(picked.session.source.rawValue) 轮数 \(picked.turns.count) "
            + "最长轮 #\(worst + 1)（\(picked.turns[worst].steps.count) 步）")

        @MainActor func page(_ pane: TurnLineageView.Pane, turn: Int) -> some View {
            TurnLineageView(
                sessionName: picked.session.displayName, turns: picked.turns,
                onBack: {}, initialPane: pane, initialTurn: turn)
        }
        snap("lineage-live-list", page(.list, turn: 0), height: 900)
        snap("lineage-live-graph", page(.graph, turn: worst), height: 900)
        snap("lineage-live-graph-dark", page(.graph, turn: worst), dark: true, height: 900)
    }

    /// Offscreen-renders every desktop mascot state, variant, and storyboard, producing per-variant
    /// contact sheets for visual walkthroughs.
    static func renderMascot(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pack = MascotPackLoader.builtIn()
        let bubbles: [MascotState: String] = [
            .waiting: L10n.text("Waiting for your confirmation 🙌", zhHans: "等你确认一下 🙌"),
            .success: L10n.text("All done 🎉", zhHans: "搞定啦 🎉"),
            .error: L10n.text("Something went wrong 😣", zhHans: "出错了 😣"),
            .relax: L10n.text("It's been 2 hours; stand up and stretch～", zhHans: "连续 2 小时了，起来伸个懒腰～"),
            .night: L10n.text("It's late; get some rest 🌙", zhHans: "夜深了，早点歇 🌙"),
            .poke: L10n.text("You poked me", zhHans: "戳到啦"),
            .wake: L10n.text("Good morning", zhHans: "早上好"),
        ]

        for state in MascotState.allCases {
            let variants = pack.variants(for: state)
            guard !variants.isEmpty else {
                print("跳过（无素材）\(state.rawValue)")
                continue
            }
            for variant in variants {
                let images = mascotImages(for: variant.animation)
                guard !images.isEmpty else {
                    print("跳过（无法解码）\(state.rawValue)/\(variant.id)")
                    continue
                }
                let safeID = variant.id.filter {
                    $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_"
                }
                guard !safeID.isEmpty else { continue }
                let sheet = MascotVariantPreviewSheet(
                    images: images,
                    state: state,
                    variantID: variant.id,
                    caption: variant.caption,
                    playback: variant.playback)
                writeMascotPreview(
                    sheet,
                    name: "mascot-\(state.rawValue)-\(safeID)",
                    to: dir)
            }

            if let firstVariant = variants.first,
               let image = mascotImages(for: firstVariant.animation).first {
                let overview = MascotPreviewCard(
                    image: image,
                    bubble: bubbles[state],
                    caption: firstVariant.caption,
                    state: state)
                    .frame(width: 180, height: 210)
                    .background(Color(white: 0.62))
                writeMascotPreview(
                    overview,
                    name: "mascot-\(state.rawValue)",
                    to: dir)
            }
        }
    }

    private static func mascotImages(for animation: MascotAnimation) -> [NSImage] {
        switch animation {
        case .frames(let urls, _):
            urls.compactMap(NSImage.init(contentsOf:))
        case .animatedImage(let url):
            NSImage(contentsOf: url).map { [$0] } ?? []
        case .spriteSequence(let sheet, let cells, _):
            MascotSpriteCache.frames(sheet: sheet, cells: cells)
        }
    }

    private static func writeMascotPreview<Content: View>(
        _ content: Content,
        name: String,
        to directory: URL
    ) {
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else {
            print("渲染失败：\(name)")
            return
        }
        let url = directory.appendingPathComponent("\(name).png")
        do {
            try png.write(to: url, options: .atomic)
            print("已渲染 \(url.path)")
        } catch {
            print("写入失败：\(url.lastPathComponent)：\(error.localizedDescription)")
        }
    }
}

private struct MascotVariantPreviewSheet: View {
    let images: [NSImage]
    let state: MascotState
    let variantID: String
    let caption: String?
    let playback: MascotPlaybackMode

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(state.rawValue) · \(variantID)")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Spacer()
                Text(L10n.format("%@ frames · %@", zhHans: "%@ 帧 · %@", String(images.count), String(playback == .loop ? L10n.text("Loop", zhHans: "循环") : L10n.text("Once", zhHans: "单次"))))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(.white.opacity(0.92))

            HStack(spacing: 0) {
                ForEach(images.indices, id: \.self) { index in
                    MascotPreviewCard(
                        image: images[index],
                        caption: caption,
                        state: state)
                        .frame(width: 160, height: 190)
                        .overlay(alignment: .topLeading) {
                            Text("\(index + 1)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .padding(5)
                                .foregroundStyle(.white)
                                .background(Circle().fill(.black.opacity(0.45)))
                                .padding(6)
                        }
                }
            }
            .background(Color(white: 0.62))
        }
        .frame(width: CGFloat(images.count * 160), height: 220)
    }
}

/// Static sticker card (for previews; no frame animation)
private struct MascotPreviewCard: View {
    let image: NSImage
    var bubble: String?
    var caption: String?
    var state: MascotState = .idle

    var body: some View {
        VStack(spacing: 5) {
            Spacer(minLength: 0)
            if let bubble {
                Text(bubble)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .frame(maxWidth: 150)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.black.opacity(0.08), lineWidth: 1))
                    .shadow(color: .black.opacity(0.15), radius: 5, y: 2)
            }
            Image(nsImage: image)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 132, height: 132)
                .shadow(color: .black.opacity(0.28), radius: 7, y: 3)
                .overlay(alignment: .bottom) {
                    if let caption {
                        ArtTextView(text: caption, state: state, maxWidth: 132 - 8)
                            .padding(.bottom, 2)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(8)
    }
}

// MARK: - Source badge overview (for checking logo rendering offscreen after adding an agent source)

@MainActor
enum BadgeSheetRenderer {
    static func render(to path: String) {
        func row(dark: Bool) -> some View {
            HStack(spacing: 18) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    VStack(spacing: 6) {
                        SourceBadge(source: source, size: 28, onDark: dark)
                        Text(source.displayName).font(.system(size: 10))
                            .foregroundStyle(dark ? .white : .black)
                    }
                }
            }
            .padding(20)
            .background(dark ? Color.black : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
        }
        let renderer = ImageRenderer(content: VStack(spacing: 0) {
            row(dark: false)
            row(dark: true)
        })
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            print("徽标渲染失败")
            exit(1)
        }
        try? png.write(to: URL(fileURLWithPath: path))
        print("已渲染 \(path)")
    }
}
