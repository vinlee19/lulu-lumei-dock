import EurekaInstall
import EurekaKit
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
            SectionCard(L10n.text("Why integrate", zhHans: "为什么需要集成")) { intro }
            ForEach(InstallerService.Integration.allCases) { integration in
                SectionCard(integration.title) { card(integration) }
            }
            SectionCard(L10n.text("Update policy", zhHans: "更新策略")) { updatePolicy }
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
            Text(L10n.text(
                "It works with no hooks installed: the app reads local transcripts, rollouts, and databases, and events show up on the next scan. With hooks, task cards are live and the app can record which terminal a session is running in.",
                zhHans: "不装任何 hook 也能用：应用会直接读本地的 transcript / rollout / 数据库，只是事件要等下一轮扫描才出现。装上 hook 后任务卡是实时的，并且能记录会话跑在哪个终端。"))
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
            noticeLine("doc.on.doc", L10n.text("A *.bak.eureka.<timestamp> backup is written first (the latest 5 are kept)", zhHans: "写入前自动备份为 *.bak.eureka.<时间戳>（保留最近 5 份）"))
            noticeLine("scissors", L10n.text("Only entries whose command contains lululumei-relay (or the old name eureka-relay) are added or removed. Other tools' config is left byte-for-byte.", zhHans: "只增删 command 含 lululumei-relay（及旧名 eureka-relay）的条目，其它工具的配置逐字不动"))
            noticeLine("link", L10n.text("Codex notify has a single slot: if it is taken, events are forwarded to the original program first and both keep working. Turning this off restores the original value.", zhHans: "Codex notify 只能有一个：被占用时串联转发给原程序，两者都生效，关闭即恢复原值"))
            noticeLine("arrow.uturn.backward", L10n.text("You can turn the switch off at any time. Uninstalling also removes only our own entries.", zhHans: "随时可关闭开关，卸载同样只移除我们自己的条目"))
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
            Text(L10n.format(
                "Other tools' hooks detected: %@ (%@ events). They stay alongside ours and will not be changed.",
                zhHans: "检测到其它工具的 hook：%@（%@ 个事件）。它们与我们并存，不会被改动。",
                report.tools.joined(separator: L10n.text(", ", zhHans: "、")),
                String(report.events.count)))
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
                        .help(L10n.text("Installing rewrites this file (a backup is written first)", zhHans: "安装会改写这个文件（写前备份）"))
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
            if integration == .codexNotify, diagnosis.isInstalledInSomeForm,
               let chained = installer.codexNotifyChainedTo {
                Text(L10n.format(
                    "Chained: each notification is forwarded unchanged to %@, then recorded",
                    zhHans: "已串联：每次通知先原样转给 %@，再记录事件",
                    chained))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
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
        case .stale, .legacyRelayName, .driftedPath, .relayMissing: return true
        default: return false
        }
    }

    private func repairLabel(_ diagnosis: HookDiagnosis) -> String {
        switch diagnosis {
        case .stale, .legacyRelayName: return L10n.text("Update", zhHans: "更新")
        case .driftedPath: return L10n.text("Switch to the stable path", zhHans: "改为稳定路径")
        case .relayMissing: return L10n.text("Rebuild the forwarder", zhHans: "重建转发器")
        default: return L10n.text("Repair", zhHans: "修复")
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
            Toggle(L10n.text("After an app upgrade, automatically update hooks that are already installed", zhHans: "应用升级后自动更新已安装的 hook"), isOn: $settings.hookAutoUpdate)
            Text(L10n.text(
                "Only integrations you already installed are refreshed; one you never turned on is never installed. Config that cannot be rewritten safely (a hand-edited path, a parse failure, or someone else's entry) is skipped entirely and called out here. Entries that still name eureka-relay are switched to lululumei-relay along the way.",
                zhHans: "只会刷新你已经装过的那几项；永远不会安装你没开过的集成。遇到无法安全改写的配置（路径被手改、解析失败、他人占用）会整体跳过并在此提示；仍引用旧名 eureka-relay 的条目会顺带改为 lululumei-relay。"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !installer.autoUpdateSkipped.isEmpty {
                Text(L10n.format(
                    "Last automatic update skipped: %@ — see the notes above.",
                    zhHans: "上次自动更新已跳过：%@ —— 原因见上方各项说明。",
                    installer.autoUpdateSkipped.map(\.title).joined(separator: L10n.text(", ", zhHans: "、"))))
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.goldFg)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
