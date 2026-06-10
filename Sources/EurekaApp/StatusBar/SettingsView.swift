import EurekaInstall
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
