import EurekaIngest
import EurekaKit
import SwiftUI

/// 设置→关于：应用信息 + CLI 工具版本卡片网格（仿参考设计）
struct AboutView: View {
    @ObservedObject var cliTools: CLIToolsService
    @ObservedObject var updateService: UpdateService

    @State private var showInstallCommands = false
    @State private var copiedToolId: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            appCard
            toolsHeader
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(cliTools.tools) { tool in
                    toolCard(tool)
                }
            }
            installCommands
            Spacer(minLength: 8)
            Button(L10n.text("Quit lulu-lumei-dock", zhHans: "退出 lulu-lumei-dock")) { NSApp.terminate(nil) }
                .controlSize(.small)
        }
        .onAppear {
            cliTools.detectLocal()
            cliTools.checkLatest()  // 自动查最新版 → 有新版本才浮现「更新」
        }
    }

    // MARK: - 应用卡

    private var appCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                LuluLogoTile(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lulu-lumei-dock")
                        .font(.system(size: 14, weight: .semibold))
                    Text(L10n.format(
                        "Version %@ · local AI coding activity panel",
                        zhHans: "版本 %@ · 本地 AI 编码活动面板",
                        appVersion))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(L10n.format(
                        "Data directory: %@",
                        zhHans: "数据目录：%@",
                        SpoolPaths.root().path))
                        .font(.system(size: 9.5).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button(L10n.text("Show Data in Finder", zhHans: "在 Finder 显示数据")) {
                    NSWorkspace.shared.activateFileViewerSelecting([SpoolPaths.root()])
                }
                .controlSize(.small)
            }

            Divider()

            HStack {
                Toggle(L10n.text("Check for updates at launch", zhHans: "启动时自动检查更新"), isOn: Binding(
                    get: { updateService.automaticallyChecksForUpdates },
                    set: { updateService.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(!updateService.isAvailable)
                Spacer()
                Button(L10n.text("Check for Updates…", zhHans: "检查更新…")) { updateService.checkForUpdates() }
                    .controlSize(.small)
                    .disabled(!updateService.canCheckForUpdates)
            }
            if !updateService.isAvailable {
                Text(L10n.text("Dev builds (swift run) do not check for app updates. That starts working after the app is installed as a .app.", zhHans: "开发模式（swift run）不检查应用更新；安装为 .app 后可用。"))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - CLI 工具

    private var toolsHeader: some View {
        HStack {
            Text(L10n.text("CLI tools", zhHans: "CLI 工具"))
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button(L10n.text("Check for CLI Updates", zhHans: "检查 CLI 更新")) { cliTools.checkLatest() }
                .controlSize(.small)
                .disabled(cliTools.tools.contains { $0.checkingLatest })
        }
    }

    private func toolCard(_ tool: CLIToolsService.Tool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                SourceBadge(source: tool.source, size: 14)
                Text(tool.name)
                    .font(.system(size: 12, weight: .semibold))
                Text("macOS")
                    .font(.system(size: 8.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(.secondary)
                Spacer()
                statusIcon(tool)
            }
            versionRow(
                L10n.text("Current version", zhHans: "当前版本"),
                tool.detecting
                    ? L10n.text("Detecting…", zhHans: "检测中…")
                    : (tool.localVersion ?? L10n.text("Not installed", zhHans: "未安装")))
            versionRow(
                L10n.text("Latest version", zhHans: "最新版本"),
                tool.checkingLatest
                    ? L10n.text("Checking…", zhHans: "查询中…")
                    : (tool.latestVersion ?? "—"))
            HStack(spacing: 6) {
                if tool.localVersion != nil, tool.latestVersion != nil {
                    if CLIToolsService.hasUpdate(tool) {
                        Text(L10n.text("Update available", zhHans: "可更新"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.text("Up to date", zhHans: "已就绪"))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.green)
                    }
                }
                Spacer()
                Button(copiedToolId == tool.id ? L10n.text("Copied", zhHans: "已复制") : L10n.text("Copy install command", zhHans: "复制安装命令")) {
                    cliTools.copyInstallCommand(tool)
                    copiedToolId = tool.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if copiedToolId == tool.id { copiedToolId = nil }
                    }
                }
                .controlSize(.small)
                // 仅在确有新版本时显示「更新」（semver：latest > local），在可见 Terminal 里跑
                if CLIToolsService.hasUpdate(tool), !tool.updateCommand.isEmpty {
                    Button(L10n.text("Update", zhHans: "更新")) { cliTools.updateTool(tool) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                }
            }
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    private func statusIcon(_ tool: CLIToolsService.Tool) -> some View {
        Image(systemName: tool.localVersion != nil
            ? "checkmark.circle.fill" : "exclamationmark.circle")
            .font(.system(size: 12))
            .foregroundStyle(tool.localVersion != nil ? .green : .orange)
    }

    private func versionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(.system(size: 10.5).monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 手动安装命令

    private var installCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showInstallCommands.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showInstallCommands ? 90 : 0))
                    Text(L10n.text("Manual install commands", zhHans: "手动安装命令"))
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showInstallCommands {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cliTools.tools) { tool in
                        Text(tool.displayInstallCommand)
                            .font(.system(size: 10).monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
        }
    }
}
