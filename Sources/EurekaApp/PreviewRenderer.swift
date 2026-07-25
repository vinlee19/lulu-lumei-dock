import AppKit
import EurekaKit
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
        let waitingTask = AgentTask(
            source: .claude, sessionId: "p3", title: "批量更新依赖版本",
            cwd: "/Users/me/work/deps", startedAt: now.addingTimeInterval(-301),
            phase: .waiting(.permission, since: now.addingTimeInterval(-20)))
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
            withActivity.contextUsedPercent = 64
            $0.updateActiveTasks([withActivity, running2, waitingTask], idle: [idle1, idle2])
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
        print("扫描结束：plans=\(plans.totalCount) "
            + "skills=\(skillMemory.skills.count) memories=\(skillMemory.memories.count) "
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

    /// 离屏渲染桌面吉祥物各状态(取每态首帧 + 贴纸卡 + 气泡)做视觉走查。
    static func renderMascot(to directory: String) {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pack = MascotPackLoader.builtIn()
        let cases: [(MascotState, String?)] = [
            (.idle, nil), (.working, nil), (.waiting, "等你确认一下 🙌"),
            (.success, "搞定啦 🎉"), (.error, "出错了 😣"), (.sleeping, nil),
            (.relax, "连续 2 小时了,起来伸个懒腰~"), (.night, "夜深了,早点歇 🌙"),
        ]
        for (state, bubble) in cases {
            guard case .frames(let urls, _)? = pack.animation(for: state),
                  let first = urls.first, let image = NSImage(contentsOf: first)
            else { print("跳过(无素材) \(state.rawValue)"); continue }
            let view = MascotPreviewCard(
                image: image, bubble: bubble, caption: pack.captions[state], state: state)
                .frame(width: 180, height: 210)
                .background(Color(white: 0.62))  // 灰底:便于核对透明抠图
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            guard let nsImage = renderer.nsImage,
                  let tiff = nsImage.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else { print("渲染失败: \(state.rawValue)"); continue }
            let url = dir.appendingPathComponent("mascot-\(state.rawValue).png")
            try? png.write(to: url)
            print("已渲染 \(url.path)")
        }
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
