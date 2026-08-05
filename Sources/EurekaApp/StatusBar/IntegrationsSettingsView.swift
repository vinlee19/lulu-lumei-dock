import EurekaInstall
import SwiftUI

/// 设置→集成：逐项决定是否接入各 agent 的 hook，并把配置异常显式报出来。
///
/// 设计要点（均为用户明确要求）：
/// - **每项独立开关**，而不是一键装全部；默认什么都不装。
/// - 开关前就说清**会改哪个文件**、会先备份、只动我们自己的条目。
/// - 检测到异常（路径被手改 / relay 缺失 / 配置解析不了 / 他人占用）**必须显示出来**，
///   而不是像原来那样一律显示成"未安装"让人以为没装过。
/// - 同一份配置里检测到他人的 hook 时明确告知不会碰它们。
struct IntegrationsSettingsView: View {
    @ObservedObject var installer: InstallerService
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            SectionCard("为什么需要集成") { intro }
            ForEach(InstallerService.Integration.allCases) { integration in
                SectionCard(integration.title) { card(integration) }
            }
            SectionCard("更新策略") { updatePolicy }
            if let message = installer.message {
                Text(message)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { installer.refresh() }
    }

    // MARK: - 说明与风险

    private var intro: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("不装任何 hook 也能用：应用会直接读本地的 transcript / rollout / 数据库，"
                + "只是事件要等下一轮扫描才出现。装上 hook 后任务卡是实时的，"
                + "并且能记录会话跑在哪个终端。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            riskNotice
            if !installer.foreignHooks.isEmpty { foreignNotice }
        }
    }

    /// 写盘前把风险讲明白 —— 改的是用户自己的配置文件，必须先交代清楚
    private var riskNotice: some View {
        VStack(alignment: .leading, spacing: 3) {
            noticeLine("doc.on.doc", "写入前自动备份为 *.bak.eureka.<时间戳>（保留最近 5 份）")
            noticeLine("scissors", "只增删 command 含 eureka-relay 的条目，其它工具的配置逐字不动")
            noticeLine("arrow.uturn.backward", "随时可关闭开关，卸载同样只移除我们自己的条目")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.brand.opacity(0.06)))
    }

    private func noticeLine(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 他人 hook 共存提示（本机实测：`~/.claude/settings.json` 里就有别的工具）
    private var foreignNotice: some View {
        let report = installer.foreignHooks
        return HStack(alignment: .top, spacing: 5) {
            Image(systemName: "person.2")
                .font(.system(size: 9))
                .foregroundStyle(Theme.goldFg)
                .frame(width: 12)
            Text("检测到其它工具的 hook：\(report.tools.joined(separator: "、"))"
                + "（\(report.events.count) 个事件）。它们与我们并存，不会被改动。")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.gold.opacity(0.08)))
    }

    // MARK: - 单项卡片

    @ViewBuilder
    private func card(_ integration: InstallerService.Integration) -> some View {
        let diagnosis = installer.diagnosis(for: integration)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SourceBadge(source: integration.source, size: 13)
                VStack(alignment: .leading, spacing: 1) {
                    Text(integration.benefit)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Text(integration.configURL.path)
                        .font(.system(size: 9.5).monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("安装会改写这个文件（写前备份）")
                }
                Spacer(minLength: 6)
                diagnosisBadge(diagnosis)
                Toggle("", isOn: Binding(
                    get: { diagnosis.isInstalledInSomeForm },
                    set: { wanted in
                        if wanted { installer.install(integration) }
                        else { installer.uninstall(integration) }
                    }))
                    .labelsHidden()
                    // 配置解析不了 / 他人占用时，开关不该给人"点一下就好"的错觉
                    .disabled(blocksToggle(diagnosis))
            }
            if let detail = diagnosis.detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(color(for: diagnosis.severity))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if needsRepair(diagnosis) {
                // 路径漂移只有从这个按钮点进去才允许改写（默认拒绝，见 install(repairDriftedPath:)）
                Button(repairLabel(diagnosis)) {
                    installer.install(integration, repairDriftedPath: true)
                }
                .controlSize(.small)
            }
        }
    }

    /// 需要用户点一下才修的：缺事件（更新）、路径歪了（修复）、relay 没了（重建）。
    /// 路径漂移刻意**不**自动改 —— 那可能是用户手改的，我们无权覆盖。
    private func needsRepair(_ diagnosis: HookDiagnosis) -> Bool {
        switch diagnosis {
        case .stale, .driftedPath, .relayMissing: return true
        default: return false
        }
    }

    private func repairLabel(_ diagnosis: HookDiagnosis) -> String {
        switch diagnosis {
        case .stale: return "更新"
        case .driftedPath: return "改为稳定路径"
        case .relayMissing: return "重建转发器"
        default: return "修复"
        }
    }

    /// 这些异常下点开关也没用，先让用户去处理文件本身
    private func blocksToggle(_ diagnosis: HookDiagnosis) -> Bool {
        switch diagnosis {
        case .unparseable, .foreignOccupied: return true
        default: return false
        }
    }

    private func diagnosisBadge(_ diagnosis: HookDiagnosis) -> some View {
        let tint = color(for: diagnosis.severity)
        return Text(diagnosis.label)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.15)))
            .foregroundStyle(tint)
    }

    private func color(for severity: HookDiagnosis.Severity) -> Color {
        switch severity {
        case .ok: return Theme.enabledGreen
        case .info: return .secondary
        case .warning: return Theme.gold
        case .error: return Theme.failureRed
        }
    }

    // MARK: - 更新策略

    private var updatePolicy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("应用升级后自动更新已安装的 hook", isOn: $settings.hookAutoUpdate)
            Text("只会刷新你已经装过的那几项；永远不会安装你没开过的集成。"
                + "遇到无法安全改写的配置（路径被手改、解析失败、他人占用）会整体跳过并在此提示。")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !installer.autoUpdateSkipped.isEmpty {
                Text("上次自动更新已跳过："
                    + installer.autoUpdateSkipped.map(\.title).joined(separator: "、")
                    + " —— 原因见上方各项说明。")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.goldFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
