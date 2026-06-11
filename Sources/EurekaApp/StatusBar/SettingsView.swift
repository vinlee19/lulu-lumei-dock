import EurekaInstall
import EurekaKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var installer: InstallerService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                section("接入状态") {
                    statusRow("Claude Code hooks", installer.claudeStatus)
                    statusRow("Codex notify", installer.codexStatus)
                    HStack {
                        Button("一键安装/更新") { installer.installAll() }
                            .controlSize(.small)
                        Button("全部卸载") { installer.uninstallAll() }
                            .controlSize(.small)
                    }
                    if let message = installer.message {
                        Text(message)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Text("写入前自动备份（保留最近 5 份 *.bak.eureka.*）")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }

                section("灵动岛通知") {
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
                }

                section("灵动岛位置") {
                    Text("按住岛拖拽可移到任意位置（含外接屏）；拖回刘海附近会自动吸附复位。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Button("恢复默认位置（刘海居中）") {
                        NotificationCenter.default.post(
                            name: .eurekaResetIslandPosition, object: nil)
                    }
                    .controlSize(.small)
                }

                section("启动") {
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

                section("健康提示") {
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

                section("数据健康") {
                    HealthSection()
                }

                Text("relay：~/Library/Application Support/Eureka/bin/eureka-relay\n事件 spool 与数据库同目录，可直接用 sqlite3 查询 eureka.sqlite。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)

                Button("退出 Eureka") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            .padding(12)
        }
        .onAppear { installer.refresh() }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 11.5))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            VStack(alignment: .leading, spacing: 7, content: content)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.045)))
        }
    }

    private func statusRow(_ name: String, _ status: InstallStatus) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text(label(for: status))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color(for: status).opacity(0.15)))
                .foregroundStyle(color(for: status))
        }
    }

    private func label(for status: InstallStatus) -> String {
        switch status {
        case .installed: return "已安装"
        case .partial: return "部分安装"
        case .foreign: return "有他人配置"
        case .none: return "未安装"
        }
    }

    private func color(for status: InstallStatus) -> Color {
        switch status {
        case .installed: return .green
        case .partial: return .orange
        case .foreign: return .orange
        case .none: return .gray
        }
    }
}

/// 五个数据源的心跳/产出/失败一览（每 5 秒刷新）。
/// 轮询型数据源停摆（定时器死掉）会直接红灯，不用再"感觉不对"。
private struct HealthSection: View {
    @State private var rows: [(name: String, entry: HealthRegistry.Entry)] = []
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("数据源尚未启动")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: row.entry.status()))
                        .frame(width: 7, height: 7)
                    Text(row.name)
                        .font(.system(size: 10.5))
                    Spacer()
                    Text(detail(for: row.entry))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if row.entry.failureCount > 0, let note = row.entry.lastFailureNote {
                    Text("失败 \(row.entry.failureCount) 次 · 最近：\(note)")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .padding(.leading, 13)
                }
            }
        }
        .onAppear { rows = HealthRegistry.shared.snapshot() }
        .onReceive(timer) { _ in rows = HealthRegistry.shared.snapshot() }
    }

    private func color(for status: HealthRegistry.Entry.Status) -> Color {
        switch status {
        case .ok: return .green
        case .degraded: return .orange
        case .stalled: return .red
        case .idle: return .gray
        }
    }

    private func detail(for entry: HealthRegistry.Entry) -> String {
        var parts: [String] = []
        if let beat = entry.lastBeatAt {
            parts.append("心跳 \(ago(beat))")
        }
        if let event = entry.lastEventAt {
            parts.append("产出 \(ago(event))")
        }
        if entry.status() == .stalled {
            parts.append("已停摆")
        }
        return parts.isEmpty ? "等待中" : parts.joined(separator: " · ")
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<5: return "刚刚"
        case ..<60: return "\(seconds)秒前"
        case ..<3600: return "\(seconds / 60)分钟前"
        default: return "\(seconds / 3600)小时前"
        }
    }
}
