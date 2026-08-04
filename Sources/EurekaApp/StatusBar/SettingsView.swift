import EurekaInstall
import EurekaKit
import SwiftUI

/// 设置页：五个子栏目（通用 / 集成 / 备份 / 高级 / 关于），仿参考设计的胶囊子页签条。
/// 使用统计不在此页——顶级「用量」模块已完整覆盖；
/// 审计也已升为顶级页签（采集开关随页面一起搬进了 `AuditView` 的页头齿轮浮层）。
struct SettingsView: View {
    /// 由 PopoverNavigation 持有，便于侧栏品牌区直接跳「关于」
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

        /// 子页签前置图标（与全站导航一致，单色）
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
                // 备份面板自带滚动与留白，不套外层 ScrollView
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
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11.5))
        .onAppear { notificationService.refresh() }
    }

    // MARK: - 子页签条（灰底托盘 + 品牌色选中胶囊）

    private var sectionBar: some View {
        CapsuleTabTray {
            ForEach(SettingsSection.allCases, id: \.self) { item in
                CapsuleTabButton(title: item.rawValue, icon: item.icon, isSelected: section == item) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        section = item
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 通用

    @ViewBuilder
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            settingCard("外观主题") {
                Text("选择应用的外观主题，立即生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    capsuleOption($settings.appearanceMode, "light", "浅色", icon: "sun.max")
                    capsuleOption($settings.appearanceMode, "dark", "深色", icon: "moon")
                    capsuleOption($settings.appearanceMode, "system", "跟随系统", icon: "display")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
                .fixedSize()
            }

            settingCard("界面风格") {
                Text("选择面板的界面风格，立即生效；灵动岛与桌面伙伴不受影响。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    capsuleOption($settings.themeStyle, "classic", "经典", icon: "paintpalette")
                    capsuleOption(
                        $settings.themeStyle, "brutal", "新粗野",
                        icon: "square.3.layers.3d.down.right")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
                .fixedSize()
            }

            settingCard("灵动岛通知") {
                Toggle("任务完成", isOn: $settings.notifyCompletion)
                Toggle("等待确认 / 等待输入", isOn: $settings.notifyWaiting)
                Toggle("任务出错 / 中断", isOn: $settings.notifyError)
                Toggle("关键事件发送系统通知（锁屏 / 其他桌面可见）",
                       isOn: $settings.eventSystemNotifyEnabled)
                if let hint = notificationHint, settings.eventSystemNotifyEnabled {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("自动收起")
                    Slider(value: $settings.autoDismissSeconds, in: 3...15, step: 1)
                    Text("\(Int(settings.autoDismissSeconds)) 秒")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
                Toggle("正在看着该终端时不弹完成卡",
                       isOn: $settings.suppressCardWhenTerminalFrontmost)
                Text("判定只到**应用**级、分不清标签页：开着多个标签时，任意一个在前台都算「在看」。"
                    + "「等待授权」卡不受此开关影响，永远会弹 —— 那是需要你动手的提示，藏错了你会白等。"
                    + "需要已装 hook 或探测到终端归属才生效。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("显示任务开始时间（而非已持续时长）", isOn: $settings.showStartTime)
                Toggle("菜单栏显示限额百分比", isOn: $settings.menuBarShowsLimit)
                Toggle("限额临近打满时提前预警（按最近用量速度外推）", isOn: $settings.limitAlertsEnabled)
            }

            settingCard("灵动岛位置") {
                Text("按住岛拖拽可移到任意位置（含外接屏）；拖回刘海附近会自动吸附复位。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Button("恢复默认位置（刘海居中）") {
                    NotificationCenter.default.post(
                        name: .eurekaResetIslandPosition, object: nil)
                }
                .controlSize(.small)
            }

            settingCard("桌面伙伴") {
                Toggle("显示桌面吉祥物（噜噜 & 噜妹）", isOn: $settings.mascotEnabled)
                if settings.mascotEnabled {
                    HStack {
                        Text("动画包")
                        Spacer()
                        Picker("", selection: $settings.mascotPack) {
                            ForEach(MascotPackLoader.availablePacks(), id: \.id) { pack in
                                Text(pack.name).tag(pack.id)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 180)
                    }
                    Button("打开动画包文件夹") { MascotPackLoader.revealCustomFolder() }
                        .controlSize(.small)
                    if settings.mascotPack == MascotPackLoader.builtInID {
                        let builtIn = MascotPackLoader.builtIn()
                        let idleCount = builtIn.variants(for: .idle).count
                        let workingCount = builtIn.variants(for: .working).count
                        let waitingCount = builtIn.variants(for: .waiting).count
                        Text("高频行为共 \(idleCount + workingCount + waitingCount) 种："
                            + "空闲 \(idleCount) · 工作 \(workingCount) · 等待 \(waitingCount) · "
                            + "\(builtIn.lookDirections.count) 向视线")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Theme.brand)
                    }
                    Text("自定义包放 mascots/<名字>/ + manifest.json（文件夹里有说明与示例）；"
                        + "拖动可移动位置，空闲时会看向鼠标，右键可隐藏。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }

            settingCard("启动") {
                Toggle("登录时自动启动", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
                if let hint = settings.launchAtLoginHint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                }
            }

            healthCard
        }
    }

    @ViewBuilder
    private var healthCard: some View {
        settingCard("健康提示") {
            Toggle("vibe coding 过久 / 会话过多 / 深夜时给我贴心提醒", isOn: $settings.wellnessEnabled)
            if settings.wellnessEnabled {
                HStack {
                    Text("连续活跃")
                    Slider(value: $settings.wellnessThresholdHours, in: 1...4, step: 0.5)
                    Text(String(format: "%.1f 小时", settings.wellnessThresholdHours))
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 52, alignment: .trailing)
                }
                Text("提醒后每小时最多再提醒一次；并发 ≥5 个会话、23 点后还在跑任务也会轻声提示。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// 系统通知降级提示：反映真实授权状态（开发态不可用 / 被拒 / 正常）
    private var notificationHint: String? {
        switch notificationService.availability {
        case .unavailableNotBundled:
            return "当前为开发模式（swift run）运行，系统通知不可用，仅岛内红卡告警；安装为 .app 后生效。"
        case .denied:
            return "系统通知权限已被拒绝，仅岛内红卡告警。可在 系统设置 > 通知 > lulu-lumei-dock 中开启。"
        case .authorized, .unknown:
            return nil
        }
    }

    /// 胶囊分段选项（外观主题 / 界面风格共用）：选中 = 品牌底 + onBrand 字（brutal 下为墨字）
    private func capsuleOption(
        _ selection: Binding<String>, _ mode: String, _ label: String, icon: String
    ) -> some View {
        let selected = selection.wrappedValue == mode
        return Button {
            selection.wrappedValue = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
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
