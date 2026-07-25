import EurekaInstall
import EurekaKit
import Foundation

/// 设置页的 hooks/notify 装卸（与 CLI 共用 EurekaInstall 纯逻辑 + ConfigFile）。
///
/// 安全约定（用户明确要求「不要乱改用户配置 / 检测到异常要告知」）：
/// - **永不主动安装**用户没点过的集成，且一次只碰一个集成的配置文件（见文件末尾说明）。
/// - 只增删 command 含 `eureka-relay` 的自有条目，他人 hook 逐字不动。
/// - 写前一律经 `ConfigFile.backupThenWrite` 留 `*.bak.eureka.<时间戳>`。
/// - 诊断出 `blocksAutomaticWrite` 的异常（路径被手改 / 配置解析不了 / 他人占用）时，
///   自动更新整体跳过并把原因显示出来 —— 看不懂的配置绝不猜着改。
@MainActor
final class InstallerService: ObservableObject {
    /// 可独立开关的集成项
    enum Integration: String, CaseIterable, Identifiable {
        case claudeHooks
        case codexNotify

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return "Claude Code hooks"
            case .codexNotify: return "Codex notify"
            }
        }

        /// 会被改写的文件（安装前要明确告诉用户）
        var configURL: URL {
            switch self {
            case .claudeHooks: return EurekaCLI.claudeSettingsURL
            case .codexNotify: return EurekaCLI.codexConfigURL
            }
        }

        var source: AgentSource {
            switch self {
            case .claudeHooks: return .claude
            case .codexNotify: return .codex
            }
        }

        /// 装上之后多了什么能力
        var benefit: String {
            switch self {
            case .claudeHooks:
                return "实时任务卡、等待授权提醒、工具调用审计、会话所在终端"
            case .codexNotify:
                return "回合完成通知、会话所在终端"
            }
        }
    }

    @Published private(set) var diagnoses: [Integration: HookDiagnosis] = [:]
    /// 同一份配置里他人的 hook（只告知，不据此改动）
    @Published private(set) var foreignHooks = ForeignHookReport()
    @Published private(set) var message: String?
    /// 最近一次自动更新是否因异常被跳过（跳过原因要让用户看见，不能静悄悄）
    @Published private(set) var autoUpdateSkipped: [Integration] = []

    /// 兼容旧调用点（AuditView 判断 Claude hooks 是否可用）
    var claudeStatus: InstallStatus {
        switch diagnoses[.claudeHooks] {
        case .installed: return .installed
        case .stale, .driftedPath, .relayMissing: return .partial
        case .foreignOccupied: return .foreign
        case .notInstalled, .unparseable, .none: return .none
        }
    }

    var claudeSettingsURL: URL { EurekaCLI.claudeSettingsURL }
    var codexConfigURL: URL { EurekaCLI.codexConfigURL }

    /// relay 稳定路径。hooks/notify 配置永远只该引用这里。
    var stableRelayPath: String { RelaySyncer.stableRelayURL.path }

    /// relay 是否真的可执行 —— 诊断 `.relayMissing` 的依据
    private func relayIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func refresh() {
        let relay = stableRelayPath
        let claudeJSON = ConfigFile.read(claudeSettingsURL)
        diagnoses[.claudeHooks] = ClaudeHooksInstaller.diagnose(
            json: claudeJSON, expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
        diagnoses[.codexNotify] = CodexNotifyInstaller.diagnose(
            toml: ConfigFile.read(codexConfigURL), expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
        foreignHooks = ClaudeHooksInstaller.foreignHooks(in: claudeJSON)
    }

    func diagnosis(for integration: Integration) -> HookDiagnosis {
        diagnoses[integration] ?? .notInstalled
    }

    // MARK: - 逐项装卸（设置页唯一入口）

    /// 安装/更新单项。调用方须已向用户展示「会改哪个文件 + 会先备份」。
    ///
    /// `repairDriftedPath` 只由「改为稳定路径」那个按钮传 true：路径被手改过时默认**拒绝**改写，
    /// 否则任何一个"安装"按钮都会静默覆盖用户自己编辑过的路径。
    func install(_ integration: Integration, repairDriftedPath: Bool = false) {
        guard let relay = RelaySyncer.sync() else {
            message = "找不到 eureka-relay（应与应用同目录），未做任何改动"
            return
        }
        // 解析不了 / 他人占用 / 路径被手改 → 拒绝写入，把原因告诉用户
        let diagnosis = diagnosis(for: integration)
        if case .unparseable = diagnosis {
            message = "\(integration.title)：\(diagnosis.detail ?? "配置无法解析")"
            return
        }
        if case .foreignOccupied = diagnosis {
            message = "\(integration.title)：\(diagnosis.detail ?? "已被他人占用")"
            return
        }
        if case .driftedPath = diagnosis, !repairDriftedPath {
            message = "\(integration.title)：配置里的路径被改过，未做改动。"
                + "确认要改回稳定路径请点该项的「改为稳定路径」。"
            return
        }
        do {
            try write(integration, relayPath: relay.path)
            message = "\(integration.title) 已安装/更新（原配置已备份到 "
                + "\(integration.configURL.lastPathComponent).bak.eureka.*）"
        } catch {
            message = "\(integration.title) 失败：\(error)（未改动原文件）"
        }
        refresh()
    }

    func uninstall(_ integration: Integration) {
        do {
            let url = integration.configURL
            let original = ConfigFile.read(url)
            guard !original.isEmpty else {
                message = "\(integration.title)：配置文件为空，无需卸载"
                return
            }
            let updated: String
            switch integration {
            case .claudeHooks: updated = try ClaudeHooksInstaller.uninstall(from: original)
            case .codexNotify: updated = CodexNotifyInstaller.uninstall(from: original)
            }
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            message = "\(integration.title) 已卸载（只移除了我们自己的条目）"
        } catch {
            message = "\(integration.title) 卸载失败：\(error)（未改动原文件）"
        }
        refresh()
    }

    private func write(_ integration: Integration, relayPath: String) throws {
        let url = integration.configURL
        let original = ConfigFile.read(url)
        let updated: String
        switch integration {
        case .claudeHooks:
            updated = try ClaudeHooksInstaller.install(into: original, relayPath: relayPath)
        case .codexNotify:
            updated = try CodexNotifyInstaller.install(into: original, relayPath: relayPath)
        }
        try ConfigFile.backupThenWrite(path: url, newContent: updated)
    }

    // MARK: - 自动更新（只碰已经装过的）

    /// app 升级后把**已安装**的集成刷到当前版本。
    ///
    /// 三条硬约束：
    /// 1. 只处理 `isInstalledInSomeForm` 的项 —— 绝不因为"顺手"就装上用户没同意的；
    /// 2. `blocksAutomaticWrite` 的异常整体跳过并记进 `autoUpdateSkipped`（UI 要显示出来）；
    /// 3. 已经 `.installed` 的不重复写盘，免得每次启动都生成一份备份文件。
    func autoUpdateInstalled(enabled: Bool) {
        guard enabled else { return }
        refresh()
        var updated: [String] = []
        var skipped: [Integration] = []
        for integration in Integration.allCases {
            let diagnosis = diagnosis(for: integration)
            guard diagnosis.isInstalledInSomeForm else { continue }
            if diagnosis.blocksAutomaticWrite {
                skipped.append(integration)
                continue
            }
            guard !diagnosis.isHealthy else { continue }
            guard let relay = RelaySyncer.sync() else { continue }
            if (try? write(integration, relayPath: relay.path)) != nil {
                updated.append(integration.title)
            }
        }
        autoUpdateSkipped = skipped
        if !updated.isEmpty {
            message = "已自动更新：\(updated.joined(separator: "、"))（原配置已备份）"
        }
        if !updated.isEmpty || !skipped.isEmpty { refresh() }
    }

}

// 刻意不提供 installAll()/uninstallAll()：一个按钮同时改写多个 agent 的配置文件，
// 必然会给「只用其中一个」的用户凭空造出别的 agent 的配置（审计页那个横幅就这样
// 给纯 Claude 用户建过 ~/.codex/config.toml）。要装哪项就调哪项。
