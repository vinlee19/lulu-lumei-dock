import EurekaIngest
import EurekaKit
import SwiftUI

/// Settings → About: app info + a card grid of CLI tool versions (modeled on the reference design)
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
            cliTools.checkLatest()  // Auto-check the latest version → "Update" shows only if newer
        }
    }

    // MARK: - App card

    private var appCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                LuluLogoTile(size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("lulu-lumei-dock")
                        .font(Theme.font.themed(14, .semibold))
                    Text(L10n.format(
                        "Version %@ · local AI coding activity panel",
                        zhHans: "版本 %@ · 本地 AI 编码活动面板",
                        appVersion))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                    Text(L10n.format(
                        "Data directory: %@",
                        zhHans: "数据目录：%@",
                        SpoolPaths.root().path))
                        .font(Theme.font.monoSkillName(9.5, weight: .regular))
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
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Theme.spacing.card)
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }

    // MARK: - CLI tools

    private var toolsHeader: some View {
        HStack {
            Text(L10n.text("CLI tools", zhHans: "CLI 工具"))
                .font(Theme.font.themed(12, .semibold))
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
                    .font(Theme.font.themed(12, .semibold))
                Text("macOS")
                    .font(Theme.font.themed(8.5))
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
                            .font(Theme.font.themed(9.5, .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text(L10n.text("Up to date", zhHans: "已就绪"))
                            .font(Theme.font.themed(9.5, .medium))
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
                // Show "Update" only when a newer version really exists (semver: latest > local);
                // it runs in a visible Terminal
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
            .font(Theme.font.themed(12))
            .foregroundStyle(tool.localVersion != nil ? .green : .orange)
    }

    private func versionRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
            Spacer()
            Text(value)
                .font(Theme.font.monoSkillName(10.5, weight: .regular))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Manual install commands

    private var installCommands: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showInstallCommands.toggle()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(Theme.font.themed(9, .semibold))
                        .rotationEffect(.degrees(showInstallCommands ? 90 : 0))
                    Text(L10n.text("Manual install commands", zhHans: "手动安装命令"))
                        .font(Theme.font.themed(11, .medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showInstallCommands {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(cliTools.tools) { tool in
                        Text(tool.displayInstallCommand)
                            .font(Theme.font.monoSkillName(10, weight: .regular))
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
