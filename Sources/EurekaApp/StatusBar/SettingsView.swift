import EurekaInstall
import EurekaKit
import SwiftUI

/// Settings page: five sub-sections (General / Integrations / Backup / Advanced / About), with a
/// capsule sub-tab bar modeled on the reference design. Usage stats aren't here -- the top-level
/// Usage module already covers them fully; Audit has also been promoted to a top-level tab (its
/// capture toggle moved with it into the header gear popover of `AuditView`).
struct SettingsView: View {
    /// Owned by PopoverNavigation so the sidebar brand area can jump straight to "About"
    @Binding var section: SettingsSection

    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: InstallerService
    @ObservedObject var usageService: UsageService
    @ObservedObject var cliTools: CLIToolsService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var syncService: SyncService

    enum SettingsSection: String, CaseIterable {
        case general = "通用"
        case integrations = "集成"
        case backup = "备份"
        case advanced = "高级"
        case about = "关于"

        /// Name shown on the sub-tab. rawValue is still the original Chinese text; offscreen-render
        /// file names keep using the case name.
        var title: String {
            switch self {
            case .general: return L10n.text("General", zhHans: "通用")
            case .integrations: return L10n.text("Integrations", zhHans: "集成")
            case .backup: return L10n.text("Backup", zhHans: "备份")
            case .advanced: return L10n.text("Advanced", zhHans: "高级")
            case .about: return L10n.text("About", zhHans: "关于")
            }
        }

        /// Sub-tab leading icon (monochrome, consistent with site-wide navigation)
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .integrations: return "puzzlepiece.extension"
            case .backup: return "icloud.and.arrow.up"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            Divider()
            switch section {
            case .backup:
                // The backup panel has its own scrolling and padding; don't wrap it in an outer
                // ScrollView
                BackupView(service: syncService, settings: settings)
            default:
                ScrollView {
                    Group {
                        switch section {
                        case .general: generalSection
                        case .integrations: IntegrationsSettingsView(
                            installer: installer, settings: settings)
                        case .advanced: AdvancedSettingsView(
                            installer: installer, usageService: usageService,
                            settings: settings)
                        case .about: AboutView(cliTools: cliTools, updateService: updateService)
                        default: EmptyView()
                        }
                    }
                    .padding(Theme.spacing.page)
                }
            }
        }
        .toggleStyle(.themedSwitch)
        .controlSize(.small)
        // Classic keeps the system accent (nil = no override) so it stays pixel-identical;
        // the other styles tint sliders and system controls with their brand color.
        .tint(ThemeStyle.current == .classic ? nil : Theme.brand)
        .font(Theme.font.themed(11.5))
        .onAppear { notificationService.refresh() }
    }

    // MARK: - Sub-tab bar (grey tray + brand-colored selected capsule)

    private var sectionBar: some View {
        CapsuleTabTray {
            ForEach(SettingsSection.allCases, id: \.self) { item in
                CapsuleTabButton(title: item.title, icon: item.icon, isSelected: section == item) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        section = item
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - General

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            settingCard(L10n.text("Language", zhHans: "语言")) {
                Text(L10n.text(
                    "The interface language. English is the default, and the change applies immediately.",
                    zhHans: "界面语言。默认是英文，立即生效。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(AppLanguage.allCases, id: \.self) { language in
                        capsuleOption(
                            $settings.appLanguage, language.rawValue, language.endonym,
                            icon: "globe")
                    }
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
            }

            settingCard(L10n.text("Appearance", zhHans: "外观主题")) {
                Text(L10n.text(
                    "Choose the appearance. The change applies immediately.",
                    zhHans: "选择应用的外观主题，立即生效。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    capsuleOption(
                        $settings.appearanceMode, "light",
                        L10n.text("Light", zhHans: "浅色"), icon: "sun.max")
                    capsuleOption(
                        $settings.appearanceMode, "dark",
                        L10n.text("Dark", zhHans: "深色"), icon: "moon")
                    capsuleOption(
                        $settings.appearanceMode, "system",
                        L10n.text("System", zhHans: "跟随系统"), icon: "display")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
            }

            settingCard(L10n.text("Interface style", zhHans: "界面风格")) {
                Text(L10n.text(
                    "Choose the panel style. The change applies immediately. The island and the desktop companion are not affected.",
                    zhHans: "选择面板的界面风格，立即生效；灵动岛与桌面伙伴不受影响。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                FlowLayout(spacing: 3, lineSpacing: 3) {
                    capsuleOption(
                        $settings.themeStyle, "classic",
                        L10n.text("Classic", zhHans: "经典"), icon: "paintpalette")
                    capsuleOption(
                        $settings.themeStyle, "brutal", "Neo-Brutalism",
                        icon: "square.3.layers.3d.down.right")
                    Group {
                        capsuleOption($settings.themeStyle, "catppuccin", "Catppuccin", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "gruvbox", "Gruvbox", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "nord", "Nord", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "solarized", "Solarized", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "rosepine", "Rosé Pine", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "onedark", "One Dark", icon: "swatchpalette")
                        capsuleOption($settings.themeStyle, "kanagawa", "Kanagawa", icon: "swatchpalette")
                    }
                }
                // No `.fixedSize()` here: it proposed an unbounded width, so FlowLayout never
                // wrapped and the nine chips (~900pt) pushed the whole page out of the window
                // below ~910pt. FlowLayout already hugs its content when it fits on one line.
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
            }

            settingCard(L10n.text("Island notifications", zhHans: "灵动岛通知")) {
                Toggle(L10n.text("Task finished", zhHans: "任务完成"), isOn: $settings.notifyCompletion)
                Toggle(
                    L10n.text("Waiting for confirmation / input", zhHans: "等待确认 / 等待输入"),
                    isOn: $settings.notifyWaiting)
                Toggle(
                    L10n.text("Answer Claude's questions on the island", zhHans: "在灵动岛上回答 Claude 的提问"),
                    isOn: $settings.answerQuestionsOnIsland)
                Text(askHookHint)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    L10n.text("Task failed / interrupted", zhHans: "任务出错 / 中断"),
                    isOn: $settings.notifyError)
                Toggle(
                    L10n.text(
                        "Also send key events as system notifications (visible on the lock screen and other desktops)",
                        zhHans: "关键事件发送系统通知（锁屏 / 其他桌面可见）"),
                    isOn: $settings.eventSystemNotifyEnabled)
                if let hint = notificationHint, settings.eventSystemNotifyEnabled {
                    Text(hint)
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text(L10n.text("Auto-hide", zhHans: "自动收起"))
                    Slider(value: $settings.autoDismissSeconds, in: 3...15, step: 1)
                    Text(L10n.format(
                        "%@s", zhHans: "%@ 秒",
                        String(Int(settings.autoDismissSeconds))))
                        .font(Theme.font.themedMono(11))
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle(
                    L10n.text(
                        "Don't show a finished card while that terminal is frontmost",
                        zhHans: "正在看着该终端时不弹完成卡"),
                    isOn: $settings.suppressCardWhenTerminalFrontmost)
                Text(L10n.markdown(
                    "Detection is **per app**, not per tab: if any tab of that app is frontmost, you count as watching. Permission cards always appear — they need you, and hiding one would leave you waiting. Requires an installed hook or a detected terminal.",
                    zhHans: "判定只到**应用**级、分不清标签页：开着多个标签时，任意一个在前台都算「在看」。「等待授权」卡不受此开关影响，永远会弹 —— 那是需要你动手的提示，藏错了你会白等。需要已装 hook 或探测到终端归属才生效。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(
                    L10n.text(
                        "Show the task start time (instead of the elapsed time)",
                        zhHans: "显示任务开始时间（而非已持续时长）"),
                    isOn: $settings.showStartTime)
                Toggle(
                    L10n.text("Show the limit percentage in the menu bar", zhHans: "菜单栏显示限额百分比"),
                    isOn: $settings.menuBarShowsLimit)
                Toggle(
                    L10n.text(
                        "Warn before a limit fills up (projected from recent usage)",
                        zhHans: "限额临近打满时提前预警（按最近用量速度外推）"),
                    isOn: $settings.limitAlertsEnabled)
            }

            settingCard(L10n.text("Island position", zhHans: "灵动岛位置")) {
                Text(L10n.text(
                    "Drag the island anywhere, including onto another display. Drag it back near the notch and it snaps home.",
                    zhHans: "按住岛拖拽可移到任意位置（含外接屏）；拖回刘海附近会自动吸附复位。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                Button(L10n.text(
                    "Reset to the default position (centered on the notch)",
                    zhHans: "恢复默认位置（刘海居中）")) {
                    NotificationCenter.default.post(
                        name: .eurekaResetIslandPosition, object: nil)
                }
                .controlSize(.small)
            }

            settingCard(L10n.text("Desktop companion", zhHans: "桌面伙伴")) {
                Toggle(
                    L10n.text("Show the desktop companions (Lulu & Lumei)", zhHans: "显示桌面吉祥物（噜噜 & 噜妹）"),
                    isOn: $settings.mascotEnabled)
                if settings.mascotEnabled {
                    HStack {
                        Text(L10n.text("Animation pack", zhHans: "动画包"))
                        Spacer()
                        Picker("", selection: $settings.mascotPack) {
                            ForEach(MascotPackLoader.availablePacks(), id: \.id) { pack in
                                Text(pack.name).tag(pack.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    }
                    Button(L10n.text("Open the animation-pack folder", zhHans: "打开动画包文件夹")) {
                        MascotPackLoader.revealCustomFolder()
                    }
                        .controlSize(.small)
                    if settings.mascotPack == MascotPackLoader.builtInID {
                        let builtIn = MascotPackLoader.builtIn()
                        let idleCount = builtIn.variants(for: .idle).count
                        let workingCount = builtIn.variants(for: .working).count
                        let waitingCount = builtIn.variants(for: .waiting).count
                        Text(L10n.format(
                            "%1$@ frequent poses: idle %2$@ · working %3$@ · waiting %4$@ · %5$@ gaze directions",
                            zhHans: "高频行为共 %1$@ 种：空闲 %2$@ · 工作 %3$@ · 等待 %4$@ · %5$@ 向视线",
                            String(idleCount + workingCount + waitingCount),
                            String(idleCount),
                            String(workingCount),
                            String(waitingCount),
                            String(builtIn.lookDirections.count)))
                            .font(Theme.font.themed(9.5, .medium))
                            .foregroundStyle(Theme.brandFg)
                    }
                    Text(L10n.text(
                        "Put a custom pack in mascots/<name>/ plus manifest.json (the folder has notes and an example). Drag to move, it looks toward the pointer when idle, and right-click hides it.",
                        zhHans: "自定义包放 mascots/<名字>/ + manifest.json（文件夹里有说明与示例）；拖动可移动位置，空闲时会看向鼠标，右键可隐藏。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            settingCard(L10n.text("Startup", zhHans: "启动")) {
                Toggle(L10n.text("Launch at login", zhHans: "登录时自动启动"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let hint = settings.launchAtLoginHint {
                    Text(hint)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.orange)
                }
            }

            healthCard
        }
    }

    @ViewBuilder
    private var healthCard: some View {
        settingCard(L10n.text("Wellness", zhHans: "健康提示")) {
            Toggle(
                L10n.text(
                    "Nudge me after long vibe-coding sessions, too many sessions, or a late night",
                    zhHans: "vibe coding 过久 / 会话过多 / 深夜时给我贴心提醒"),
                isOn: $settings.wellnessEnabled)
            if settings.wellnessEnabled {
                HStack {
                    Text(L10n.text("Continuous activity", zhHans: "连续活跃"))
                    Slider(value: $settings.wellnessThresholdHours, in: 1...4, step: 0.5)
                    Text(L10n.format(
                        "%@ h", zhHans: "%@ 小时",
                        String(format: "%.1f", settings.wellnessThresholdHours)))
                        .font(Theme.font.themedMono(11))
                        .frame(width: 52, alignment: .trailing)
                }
                Text(L10n.text(
                    "After a nudge, at most one more per hour. Five or more sessions at once, or tasks still running after 23:00, also get a quiet reminder.",
                    zhHans: "提醒后每小时最多再提醒一次；并发 ≥5 个会话、23 点后还在跑任务也会轻声提示。"))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 答题 hook 的实际状态：开关开着不等于装上了（要先装 Claude Code hooks）
    private var askHookHint: String {
        guard settings.answerQuestionsOnIsland else {
            return L10n.text(
                "When off, Claude's multiple-choice questions are answered only in Claude's own dialog.",
                zhHans: "关闭时 Claude 的选择题只在 Claude 自己的确认界面里回答。")
        }
        if installer.askHookInstalled {
            return L10n.text(
                "Active: when Claude asks, the options also pop up on the island and whichever side answers first wins. The island card stays up to 10 minutes.",
                zhHans: "已生效：Claude 提问时岛上同时弹出选项，岛上或 Claude 里哪边先答用哪边；岛上的卡最多保留 10 分钟。")
        }
        return L10n.text(
            "Not active yet: install Claude Code hooks on the Integrations page first; that also adds an AskUserQuestion hook to settings.json.",
            zhHans: "尚未生效：需要先在「集成」页安装 Claude Code hooks，会一并在 settings.json 加一条 AskUserQuestion 专用 hook。")
    }

    /// 系统通知降级提示：反映真实授权状态（开发态不可用 / 被拒 / 正常）
    private var notificationHint: String? {
        switch notificationService.availability {
        case .unavailableNotBundled:
            return L10n.text(
                "This is a development run (swift run), so system notifications are unavailable and only the in-island alert shows. They work after the app is installed.",
                zhHans: "当前为开发模式（swift run）运行，系统通知不可用，仅岛内红卡告警；安装为 .app 后生效。")
        case .denied:
            return L10n.text(
                "System notification permission was denied, so only the in-island alert shows. Turn it on in System Settings > Notifications > lulu-lumei-dock.",
                zhHans: "系统通知权限已被拒绝，仅岛内红卡告警。可在 系统设置 > 通知 > lulu-lumei-dock 中开启。")
        case .authorized, .unknown:
            return nil
        }
    }

    /// Capsule segmented option (shared by appearance theme / UI style): selected = brand fill +
    /// onBrand text (ink text under brutal)
    private func capsuleOption(
        _ selection: Binding<String>, _ mode: String, _ label: String, icon: String
    ) -> some View {
        let selected = selection.wrappedValue == mode
        return Button {
            selection.wrappedValue = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(Theme.font.themed(10))
                Text(label)
                    .font(Theme.font.themed(11, selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? Theme.onBrand : .secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(
                selected ? AnyShapeStyle(Theme.brand.gradient)
                         : AnyShapeStyle(Color.clear)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func settingCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        SectionCard(title, content: content)
    }
}
