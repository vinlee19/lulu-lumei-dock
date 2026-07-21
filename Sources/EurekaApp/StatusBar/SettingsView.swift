import EurekaInstall
import EurekaKit
import SwiftUI

/// 设置页：六个子栏目（通用 / 备份 / 审计 / 使用统计 / 高级 / 关于），仿参考设计的胶囊子页签条。
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: InstallerService
    @ObservedObject var usageService: UsageService
    @ObservedObject var sessionBrowser: SessionBrowserService
    @ObservedObject var cliTools: CLIToolsService
    @ObservedObject var notificationService: NotificationService
    @ObservedObject var updateService: UpdateService
    @ObservedObject var syncService: SyncService
    @ObservedObject var auditService: AuditService

    @State private var section: SettingsSection = .general

    enum SettingsSection: String, CaseIterable {
        case general = "通用"
        case backup = "备份"
        case audit = "审计"
        case stats = "使用统计"
        case advanced = "高级"
        case about = "关于"
    }

    var body: some View {
        VStack(spacing: 0) {
            sectionBar
            Divider()
            switch section {
            case .backup:
                // 备份/审计面板自带滚动与留白，不套外层 ScrollView
                BackupView(service: syncService, settings: settings)
            case .audit:
                auditSection
            default:
                ScrollView {
                    Group {
                        switch section {
                        case .general: generalSection
                        case .stats: UsageDashboardView(
                            usageService: usageService, sessionBrowser: sessionBrowser)
                            .padding(-12)  // 仪表盘自带 padding，抵消外层
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

    // MARK: - 审计子栏目（配置卡 + 流水列表）

    private var auditSection: some View {
        VStack(spacing: 0) {
            auditCard
                .padding(Theme.spacing.page)
            Divider()
            AuditView(service: auditService, installer: installer)
        }
    }

    // MARK: - 子页签条（灰底托盘 + 品牌色选中胶囊）

    private var sectionBar: some View {
        CapsuleTabTray {
            ForEach(SettingsSection.allCases, id: \.self) { item in
                CapsuleTabButton(title: item.rawValue, isSelected: section == item) {
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
                    appearanceOption("light", "浅色", icon: "sun.max")
                    appearanceOption("dark", "深色", icon: "moon")
                    appearanceOption("system", "跟随系统", icon: "display")
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceSecondary))
                .fixedSize()
            }

            settingCard("灵动岛通知") {
                Toggle("任务完成", isOn: $settings.notifyCompletion)
                Toggle("等待确认 / 等待输入", isOn: $settings.notifyWaiting)
                Toggle("任务出错 / 中断", isOn: $settings.notifyError)
                HStack {
                    Text("自动收起")
                    Slider(value: $settings.autoDismissSeconds, in: 3...15, step: 1)
                    Text("\(Int(settings.autoDismissSeconds)) 秒")
                        .font(.system(size: 11).monospacedDigit())
                        .frame(width: 36, alignment: .trailing)
                }
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
                    Text("自定义包放 mascots/<名字>/ + manifest.json（文件夹里有说明与示例）；"
                        + "拖动可移动位置，右键可隐藏。")
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

    // MARK: - 安全审计

    @ViewBuilder
    private var auditCard: some View {
        settingCard("安全审计") {
            Toggle("记录 agent 操作审计流水", isOn: $settings.auditEnabled)
            Text("记录 Claude / Codex 执行的完整命令与读写的文件路径，用于事后回溯；"
                + "不记录任何执行输出内容。命令文本本就明文存于本地会话记录中。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            if settings.auditEnabled {
                Toggle("高危操作岛内红卡告警", isOn: $settings.auditRiskAlertsEnabled)
                Toggle("高危操作系统通知（锁屏 / 其他桌面可见）", isOn: $settings.auditSystemNotifyEnabled)
                if let hint = notificationHint, settings.auditSystemNotifyEnabled {
                    Text(hint)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                HStack {
                    Text("保留时长")
                    Spacer()
                    Picker("", selection: $settings.auditRetentionDays) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("180 天").tag(180)
                        Text("365 天").tag(365)
                        Text("永久").tag(0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 120)
                }
                Text("高危规则为启发式提示（sudo / rm -rf 绝对路径 / 管道执行下载脚本 / 读写密钥等），"
                    + "非沙箱拦截；命中会去重节流。下方流水可筛选、搜索、导出与清空。")
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

    private func appearanceOption(_ mode: String, _ label: String, icon: String) -> some View {
        let selected = settings.appearanceMode == mode
        return Button {
            settings.appearanceMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
            }
            .foregroundStyle(selected ? .white : .secondary)
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
