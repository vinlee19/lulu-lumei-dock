import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// 离屏渲染灵动岛各形态为 PNG：无需屏幕录制权限即可做视觉走查/自检。
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
            source: .claude, sessionId: "p1", title: "重构用户认证模块",
            cwd: "/Users/me/work/auth-service", startedAt: now.addingTimeInterval(-754))
        let running2 = AgentTask(
            source: .codex, sessionId: "p2", title: "修复 CI 失败用例",
            cwd: "/Users/me/work/ci", startedAt: now.addingTimeInterval(-135))
        let running3 = AgentTask(
            source: .grok, sessionId: "p5", title: "补全语义层缓存标签",
            cwd: "/Users/me/work/semantic-layer", startedAt: now.addingTimeInterval(-48))
        let running4 = AgentTask(
            source: .antigravity, sessionId: "p6", title: nil,
            cwd: "/Users/me/work/agy-app", startedAt: now.addingTimeInterval(-20))
        let running5 = AgentTask(
            source: .kimi, sessionId: "p7", title: "梳理会员配额文档",
            cwd: "/Users/me/work/kimi-docs", startedAt: now.addingTimeInterval(-66))
        var waitingTask = AgentTask(
            source: .claude, sessionId: "p3", title: "批量更新依赖版本",
            cwd: "/Users/me/work/deps", startedAt: now.addingTimeInterval(-301),
            phase: .waiting(.permission, since: now.addingTimeInterval(-20)))
        // 等待授权卡的重点是"在请求什么"（PreToolUse 带来的工具 + 对象），
        // 而不只是"等待权限确认"。会话身份由副标题的项目 + #会话号承担。
        waitingTask.currentActivity = "Bash"
        waitingTask.currentToolDetail = "rm -rf node_modules/"
        let finished = FinishedTask(
            source: .claude, sessionId: "p1", title: "重构用户认证模块",
            cwd: "/Users/me/work/auth-service",
            startedAt: now.addingTimeInterval(-754), finishedAt: now, outcome: .success)
        let errored = FinishedTask(
            source: .codex, sessionId: "p4", title: "迁移旧数据管道",
            cwd: "/Users/me/work/pipeline",
            startedAt: now.addingTimeInterval(-95), finishedAt: now, outcome: .error,
            detail: "API Error: 403 Request not allowed")

        func snapshot(_ name: String, screen: IslandGeometry.ScreenInfo, configure: (IslandViewModel) -> Void) {
            let vm = IslandViewModel()
            vm.updateScreen(screen)
            configure(vm)
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
                headline: "连续 vibe coding 2 小时了",
                body: "站起来伸个懒腰、喝口水吧——任务有我盯着。"))
        }
        snapshot("10-card-alert", screen: notched) {
            $0.enqueueAlert(RiskAlert(
                opId: "preview-alert", source: .claude, sessionId: "p1",
                ruleId: "rm-rf", ruleTitle: "递归删除绝对/家目录路径",
                tool: "Bash", detail: "sudo rm -rf ~/Library/Caches",
                timestamp: now))
        }
        snapshot("8-tasklist", screen: notched) {
            var idle1 = AgentTask(
                source: .claude, sessionId: "0a1b2c3d-idle", title: "Calcite 优化器调研",
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
            // 具体对象串（PreToolUse 带来）：验证「Edit src/main.swift」这类长文本不破版
            withActivity.currentToolDetail = "swift build -c release"
            withActivity.contextUsedPercent = 64
            // 压缩上下文态：这段时间没有别的事件，必须在列表里看得出来
            var compacting = running2
            compacting.isCompacting = true
            $0.updateActiveTasks([withActivity, compacting, waitingTask], idle: [idle1, idle2])
            $0.islandTapped()
        }

        // 子 agent：收起徽标 / 展开三态 / 胶囊聚合标识
        let subagents = [
            SubagentInfo(agentId: "a1", agentType: "Explore",
                         description: "定位 transcript 解析入口", status: .running,
                         currentActivity: "Grep"),
            SubagentInfo(agentId: "a2", agentType: "Plan",
                         description: "设计灵动岛子代理渲染方案", status: .completed),
            SubagentInfo(agentId: "a3", agentType: "claude-code-guide",
                         description: "核实子代理目录格式", status: .failed),
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
    }

    /// 离屏渲染知识库页（Plans/Skills/Memory/Agents × 卡片/列表）做视觉走查。
    /// 真实服务扫本机数据，等扫描完成后截图；宽度对齐主窗口内容区。
    @MainActor
    static func renderKnowledge(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let plans = PlansService()
        let skillMemory = SkillMemoryService()
        let agents = AgentConfigService()
        let usage = UsageService()
        plans.refresh(force: true)
        skillMemory.refresh()
        agents.refresh()

        // 等三边扫描完成（CLI 无主 runloop 驱动 → 手动泵；首次全量解析会话可能要几分钟，上限 300s）
        let deadline = Date().addingTimeInterval(300)
        while (plans.scanning || skillMemory.scanning || agents.scanning), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        // 记忆按「统计口径」打印：memoryTotal 含记忆库内条目，memories 只是列表里的独立条目
        // —— 两个数字都要有，否则看不出折叠是否生效
        print("扫描结束：plans=\(plans.totalCount) "
            + "skills=\(skillMemory.skills.count) "
            + "memoryTotal=\(skillMemory.memoryTotal) "
            + "standalone=\(skillMemory.memories.count) "
            + "instructions=\(skillMemory.instructionTotal) "
            + "libraries=\(skillMemory.libraries.count)"
            + "(\(skillMemory.libraries.map { "\($0.projectName):\($0.count)" }.joined(separator: ","))) "
            + "claudeAgents=\(agents.claudeAgents.count) codexProfiles=\(agents.codexProfiles.count) "
            + "scanning=\(plans.scanning)/\(skillMemory.scanning)/\(agents.scanning)")

        // NSHostingView + cacheDisplay 光栅化：ImageRenderer 离屏下 Lazy 容器/ScrollView 不物化、
        // 动态 NSColor 与 SF Symbol 也会失真；走 AppKit 布局绘制才接近真实窗口观感。
        @MainActor func snap<V: View>(_ name: String, _ view: V, dark: Bool = false,
                                      width: CGFloat = 780) {
            // 垫一层窗口底色：页面 surfaceSecondary 是半透明叠加层，无底色时 PNG 透明区会失真
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

        // 每页列表 + 图标各出一张（默认列表，对齐设计稿）；宽窗核对三列卡片比例；深色抽查一张
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
        // 记忆库二级页 + 图谱：两处都只有点击才能到，离屏渲染必须靠初始状态注入
        snap("knowledge-memory-library",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLibraryKey: skillMemory.libraries.first?.key))
        snap("knowledge-memory-graph",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .graph))
        snap("knowledge-memory-graph-dark",
             SkillMemoryView(service: skillMemory, mode: .memory, usageService: usage,
                             initialLayout: .graph), dark: true)
        // 记忆详情 + 一跳关联小图：挑引用/来源最多的一条（关联为空时那张图不出现，就看不出问题了）
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
        // 搜索态：命中数胶囊 + 圆形清空键（聚焦渐变环需真实键盘焦点，离屏无法呈现）
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
    }

    /// 离屏渲染「外壳」：侧栏（含品牌区）与审计页，明/暗两版。
    ///
    /// 之所以需要它：侧栏与审计页此前**没有任何自动看图的办法**（只有灵动岛和徽标有渲染器），
    /// 改 logo 尺寸、组标签数量、行内密度只能请人肉眼比。两个必查项也只有渲图能查：
    ///  1. 品牌标是不是明显大于导航图标、有没有高光与投影（不是一块扁方块）；
    ///  2. **最小窗高 540 下五个组标签 + 品牌脚注会不会被裁**
    ///     —— `MainWindowController` 用的是 `hosting.sizingOptions = []`，内容超出是裁剪而不是撑窗。
    @MainActor
    static func renderShell(to directory: String, style: ThemeStyle = .classic) {
        // 主题字体（Space Grotesk/Mono）须先于任何视图渲染注册；注册失败自动回退系统字体
        ThemeFonts.register()
        ThemeStyle.current = style
        defer { ThemeStyle.current = .classic }
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // NSHostingView + cacheDisplay（同 renderKnowledge：ImageRenderer 离屏下会失真）
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

        // MARK: 侧栏
        func sidebar(selected: PopoverRootView.Tab) -> some View {
            SidebarView(
                selected: selected,
                limitsBadge: ("67%", Theme.gold),
                appVersion: "0.15.0",
                onSelect: { _ in })
        }
        // 品牌标放大后单独放一版对照（26 = 脚注，44 = 关于卡，18 = 旧尺寸基准）
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
        // 最小窗高实测。注意 `MainWindowController` 的 `window.minSize` 540 是**窗口 frame**，
        // 含标题栏（~28pt）→ 内容区实际只有 ~512。再多渲一版 470 看还剩多少余量。
        snap("shell-sidebar-min-height", sidebar(selected: .history),
             width: SidebarView.width, height: 512)
        snap("shell-sidebar-tight", sidebar(selected: .history),
             width: SidebarView.width, height: 470)

        // MARK: 审计页（真实本机数据）
        let audit = AuditService()
        let installer = InstallerService()
        let settings = AppSettings()
        // AppSettings.init 会按持久化偏好重置 ThemeStyle.current，这里重申渲染参数
        ThemeStyle.current = style
        let notifications = NotificationService()
        audit.start()
        installer.refresh()
        // 服务在自己的串行队列上读库、@Published 回主线程，而 CLI 没有主 runloop → 手动泵。
        // ⚠️ 必须**无条件**泵满一段时间：早先按 `while events.isEmpty` 泵，第二次换查询时
        // events 还留着上一批（非空），循环立刻退出，于是截到的是**上一次查询的旧数据**
        // ——「仅风险」那张图里 chip 是红的、列表却是全量。
        @MainActor func loadAndSettle(_ query: AuditRepo.Query, seconds: Double = 2.5) {
            audit.load(query: query, page: 1, pageSize: 100)
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        // 首次要等库打开 + 首轮扫描，给足时间
        loadAndSettle(AuditRepo.Query(), seconds: 8)
        print("审计读库：total=\(audit.total) risk=\(audit.riskTotal) "
            + "sources=\(audit.sourceCounts.count) kinds=\(audit.kindCounts.count)")

        // 配置一致性卡要真实数据才有内容（它在 lastScanAt == nil 时不占版面）
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
        // 宽窗：来源 chips 会不会挤成两行、行内标题行有没有互相顶
        snap("shell-audit-wide", auditPage(), width: 1270)
        // 侧栏 + 审计页并排（核对分隔线两侧的字号/留白衔接）。
        // 放在改筛选之前：AuditService 是单例式共享状态，下面换查询后这张就变空了。
        snap("shell-full", HStack(spacing: 0) {
            sidebar(selected: .audit)
            Divider()
            auditPage()
        }, width: SidebarView.width + 1 + 780)

        // 仅风险：行内风险 TagChip 与总览卡的「风险 N」都要出得来
        loadAndSettle(AuditRepo.Query(riskOnly: true))
        print("仅风险：\(audit.events.count) 行 / total=\(audit.total)")
        snap("shell-audit-risk", auditPage(riskOnly: true))
        // 空态（筛不到）：确认走的是 EmptyStateView 而不是一片空白
        let nonsense = "zzz-no-such-command-zzz"
        loadAndSettle(AuditRepo.Query(keyword: nonsense))
        print("空态：\(audit.events.count) 行 / total=\(audit.total)")
        snap("shell-audit-empty", auditPage(keyword: nonsense), height: 520)

        // 采集关闭：hooksHint 让位给 captureOffHint（两张提示卡不该同时出现）
        loadAndSettle(AuditRepo.Query())
        settings.auditEnabled = false
        snap("shell-audit-capture-off", auditPage(), height: 620)
        settings.auditEnabled = true  // 别把渲染副作用留在真实偏好里

        // 齿轮浮层单独出图：popover 依赖真实窗口，整页离屏渲染时不会被光栅化。
        // 这一版是「设置 → 审计」那张卡搬过来的 4 个开关，必须自带 switch/small/11.5 样式。
        let auditView = AuditView(
            service: audit, installer: installer, settings: settings,
            notificationService: notifications, skillMemory: skillMemory)
        snap("shell-audit-settings", auditView.settingsPopover, width: 340, height: 300)
    }

    /// 离屏渲染**轮次血缘图**。
    ///
    /// 输入用**手搓的 `TurnInput` 字面量**而不是本机真实会话：验收形态是一个具体形状
    /// （提问→思考分叉→子代理回指已存在的 Read→Edit⇄build 重试环→汇聚回答），
    /// 真实会话不可能稳定复现，而离屏渲染就是验收手段 ⇒ **基准必须可复现**。
    /// 先例正是 `renderAll`：它渲灵动岛用的也全是手搓的 `AgentTask`/`SubagentInfo` 字面量。
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

        /// 画布 + 图例 + 一行统计，固定尺寸、无 ScrollView/无 Lazy → 光栅化风险最低
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

        // 验收形态（用户选中的那张预览）
        let accepted = TurnInput(
            turnIndex: 7, promptMessageId: 0, promptText: "修一下审计页的分页",
            thinkingTexts: ["先定位分页代码在哪，再决定改哪一层"],
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
            answerMessageIds: [9], answerText: "改好了，分页条现在有跳页输入框")
        snap("lineage-golden-accepted", board(accepted, width: 780))
        snap("lineage-golden-accepted-dark", board(accepted, width: 780), dark: true)
        snap("lineage-golden-min-width", board(accepted, width: 674), height: 512)
        snap("lineage-golden-wide", board(accepted, width: 1270), width: 1270)
        snap("lineage-golden-compact", board(accepted, width: 780, compact: true))

        // 子代理展开：内部步骤并进同一张图，且它读的文件与主流程去重 → 出现**跨界回读边**。
        // 这条边正是「内联展开而不是画独立子图」的全部理由（独立子图会把它剪掉）。
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

        // Claude 形态：没有思考明文 → 不伪造思考节点，改用分叉点
        var noThinking = accepted
        noThinking.thinkingTexts = []
        noThinking.turnIndex = 3
        snap("lineage-golden-no-thinking", board(noThinking, width: 780))

        // 纯链式：验脊线笔直
        var chainSteps: [TurnInput.Step] = []
        for index in 0..<7 {
            chainSteps.append(step(
                .read, "Read", "/w/File\(index).swift", batch: index + 1, index: index))
        }
        snap("lineage-golden-chain", board(TurnInput(
            turnIndex: 1, promptMessageId: 0, promptText: "逐个看一遍",
            steps: chainSteps, answerMessageIds: [1], answerText: "看完了"), width: 780))

        // 一层 9 个同类：验折叠
        var wideSteps: [TurnInput.Step] = []
        for index in 0..<9 {
            wideSteps.append(step(.search, "Grep", "pattern-\(index)", batch: 1, index: index))
        }
        snap("lineage-golden-fold", board(TurnInput(
            turnIndex: 2, promptMessageId: 0, promptText: "全库找一遍",
            steps: wideSteps, answerMessageIds: [1], answerText: "找到了"), width: 780))

        // 60 节点最坏可读态
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
            turnIndex: 4, promptMessageId: 0, promptText: "通读整个模块",
            steps: bigSteps, answerMessageIds: [1], answerText: "读完了"),
            width: 780), height: 1100)

        // 多条回读 + 多条重试：验左右分道与角标降级
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
            turnIndex: 5, promptMessageId: 0, promptText: "把这几个文件都改了",
            steps: laneSteps, answerMessageIds: [1], answerText: "都改完了"),
            width: 780), height: 900)

        // 超上限：验降级不排版
        var hugeSteps: [TurnInput.Step] = []
        for index in 0..<160 {
            hugeSteps.append(step(
                .command, "Bash", "echo \(index)", batch: index + 1, index: index))
        }
        snap("lineage-golden-degraded", board(TurnInput(
            turnIndex: 6, promptMessageId: 0, promptText: "跑一堆命令",
            steps: hugeSteps, answerMessageIds: [1], answerText: "跑完了"),
            width: 780), height: 320)

        // MARK: 真实数据（golden 是形态基准，live 是「真数据下会不会崩/难看」）
        // 用默认 30 天窗口：`rangeAll = true` 会把窗口放到无穷、上限 2000，
        // 离屏渲染等不起（也不是用户默认看到的样子）
        let browser = SessionBrowserService()
        browser.refresh()
        // ⚠️ 先等 scanning 落定，再**无条件**多泵一段。
        // 不能只按「结果非空」泵：切换数据时旧结果还在，循环会立刻退出、截到旧数据（上一轮踩过）
        let deadline = Date().addingTimeInterval(90)
        while browser.scanning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        // 挑轮次最多的会话，规则可复现（不是「第一个」）
        // 会话按排序档可能落在 flatSessions 或 groups 里（SessionsView 自己也是两者相加）
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

    /// 离屏渲染桌面吉祥物全部状态、变体和分镜，生成逐变体接触表做视觉走查。
    static func renderMascot(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pack = MascotPackLoader.builtIn()
        let bubbles: [MascotState: String] = [
            .waiting: "等你确认一下 🙌",
            .success: "搞定啦 🎉",
            .error: "出错了 😣",
            .relax: "连续 2 小时了，起来伸个懒腰～",
            .night: "夜深了，早点歇 🌙",
            .poke: "戳到啦",
            .wake: "早上好",
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
                Text("\(images.count) 帧 · \(playback == .loop ? "循环" : "单次")")
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

/// 静态贴纸卡(预览用,不走帧动画)
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

// MARK: - 来源徽标一览（新增 agent 源后离屏核对 logo 渲染用）

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
