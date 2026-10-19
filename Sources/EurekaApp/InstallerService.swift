import EurekaInstall
import EurekaKit
import Foundation

/// 设置页的 hooks/notify 装卸（与 CLI 共用 EurekaInstall 纯逻辑 + ConfigFile）。
///
/// 安全约定（用户明确要求「不要乱改用户配置 / 检测到异常要告知」）：
/// - **永不主动安装**用户没点过的集成，且一次只碰一个集成的配置文件（见文件末尾说明）。
/// - 只增删 command 含 `lululumei-relay`（或旧名 `eureka-relay`）的自有条目，他人 hook 逐字不动。
/// - Codex 的顶层 notify 只能有一个：被他人占用时串联（relay 先转发给原程序再记录），
///   卸载时恢复原值；解析不了的值仍然拒绝改写。
/// - 写前一律经 `ConfigFile.backupThenWrite` 留 `*.bak.eureka.<时间戳>`。
/// - 诊断出 `blocksAutomaticWrite` 的异常（路径被手改 / 配置解析不了 / 他人占用）时，
///   自动更新整体跳过并把原因显示出来 —— 看不懂的配置绝不猜着改。
@MainActor
final class InstallerService: ObservableObject {
    /// 可独立开关的集成项
    enum Integration: String, CaseIterable, Identifiable {
        case claudeHooks
        case codexNotify
        case codexHooks
        case traeHooks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return "Claude Code hooks"
            case .codexNotify: return "Codex notify"
            case .codexHooks: return "Codex hooks"
            case .traeHooks: return "Trae hooks"
            }
        }

        /// 会被改写的文件（安装前要明确告诉用户）
        var configURL: URL {
            switch self {
            case .claudeHooks: return EurekaCLI.claudeSettingsURL
            case .codexNotify: return EurekaCLI.codexConfigURL
            case .codexHooks: return EurekaCLI.codexHooksURL
            // 只有 CN 版有 hooks（国际版的 ai-agent 里没有 hooks 模块）
            case .traeHooks: return EurekaCLI.traeHooksURL
            }
        }

        var source: AgentSource {
            switch self {
            case .claudeHooks: return .claude
            case .codexNotify: return .codex
            case .codexHooks: return .codex
            case .traeHooks: return .trae
            }
        }

        /// 装上之后多了什么能力
        var benefit: String {
            switch self {
            case .claudeHooks:
                return "实时任务卡、等待授权提醒、工具调用审计、会话所在终端、在灵动岛上回答提问"
            case .codexNotify:
                return "回合完成通知、会话所在终端"
            case .codexHooks:
                // 装它的主要理由就是等待授权：Codex 的 rollout 不落授权事件，
                // 不装 hooks 这个状态对 Codex 永远不可见
                return "等待授权提醒、实时任务卡、精确的会话所在终端"
            case .traeHooks:
                // Trae 的会话库是 SQLCipher 加密的、也没有明文转录 → **不装 hooks，
                // 灵动岛就完全看不见 Trae**（这是唯一破了「不装 hooks 也能看见」惯例的源）。
                // 刻意不写"等待授权提醒"：Trae 没有权限请求类 hook 事件。
                //
                // ⚠️ Trae 的 hooks 是**按账号灰度**的服务端开关（见 `TraeHooksInstaller` 的说明），
                // 没放开时装了也不会触发 —— 文案必须把这件事说在前面，否则用户会以为是我们坏了。
                return "实时任务卡（Trae 唯一的实时通道）、工具调用审计、会话所在终端"
                    + "；需 Trae 已对你的账号开放 hooks（设置里能看到 Hooks 页即已开放）"
            }
        }
    }

    @Published private(set) var diagnoses: [Integration: HookDiagnosis] = [:]
    /// 同一份配置里他人的 hook（只告知，不据此改动）
    @Published private(set) var foreignHooks = ForeignHookReport()
    /// Short name of the program our Codex notify forwards to, when it is chained.
    @Published private(set) var codexNotifyChainedTo: String?
    @Published private(set) var message: String?
    /// settings.json 里灵动岛答题 hook 是否装着且指向稳定路径
    @Published private(set) var askHookInstalled = false
    /// 设置里「在灵动岛上回答 Claude 的提问」的当前值（AppDelegate 接到 AppSettings）。
    /// 装 / 更新 Claude hooks 时据此带上或去掉答题 hook
    var askHookEnabled: () -> Bool = { true }
    /// 最近一次自动更新是否因异常被跳过（跳过原因要让用户看见，不能静悄悄）
    @Published private(set) var autoUpdateSkipped: [Integration] = []

    /// 兼容旧调用点（AuditView 判断 Claude hooks 是否可用）
    var claudeStatus: InstallStatus {
        switch diagnoses[.claudeHooks] {
        case .installed: return .installed
        case .stale, .legacyRelayName, .driftedPath, .relayMissing: return .partial
        case .foreignOccupied, .chainable: return .foreign
        case .notInstalled, .unparseable, .none: return .none
        }
    }

    var claudeSettingsURL: URL { EurekaCLI.claudeSettingsURL }
    var codexConfigURL: URL { EurekaCLI.codexConfigURL }
    var codexHooksURL: URL { EurekaCLI.codexHooksURL }
    var traeHooksURL: URL { EurekaCLI.traeHooksURL }

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
        askHookInstalled = ClaudeAskHookInstaller.isInstalled(
            in: claudeJSON, askPath: RelaySyncer.stableAskURL.path)
            && FileManager.default.isExecutableFile(atPath: RelaySyncer.stableAskURL.path)
        let codexToml = ConfigFile.read(codexConfigURL)
        diagnoses[.codexNotify] = CodexNotifyInstaller.diagnose(
            toml: codexToml, expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
        codexNotifyChainedTo = CodexNotifyInstaller.chainedCommand(in: codexToml)?.first
            .map { URL(fileURLWithPath: $0).lastPathComponent }
        let codexHooksJSON = ConfigFile.read(codexHooksURL)
        diagnoses[.codexHooks] = CodexHooksInstaller.diagnose(
            json: codexHooksJSON, expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
        let traeHooksJSON = ConfigFile.read(traeHooksURL)
        diagnoses[.traeHooks] = TraeHooksInstaller.diagnose(
            json: traeHooksJSON, expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
        // 三份配置里他人的条目合并展示（本机 ~/.codex/hooks.json 正被 Otty 占用）
        foreignHooks = ClaudeHooksInstaller.foreignHooks(in: claudeJSON)
            .merging(CodexHooksInstaller.foreignHooks(in: codexHooksJSON))
            .merging(TraeHooksInstaller.foreignHooks(in: traeHooksJSON))
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
            let chainNote: String
            if case .chainable(let owner) = diagnosis {
                chainNote = "，已与 \(owner) 串联"
            } else {
                chainNote = ""
            }
            message = "\(integration.title) 已安装/更新\(chainNote)（原配置已备份到 "
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
            case .codexHooks: updated = try CodexHooksInstaller.uninstall(from: original)
            case .traeHooks: updated = try TraeHooksInstaller.uninstall(from: original)
            }
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            let restored = integration == .codexNotify && codexNotifyChainedTo != nil
            message = "\(integration.title) 已卸载（只移除了我们自己的条目"
                + (restored ? "，已恢复原来的 notify）" : "）")
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
            let relayHooks = try ClaudeHooksInstaller.install(into: original, relayPath: relayPath)
            updated = try applyAskHook(to: relayHooks)
        case .codexNotify:
            updated = try CodexNotifyInstaller.install(into: original, relayPath: relayPath)
        case .codexHooks:
            updated = try CodexHooksInstaller.install(into: original, relayPath: relayPath)
        case .traeHooks:
            updated = try TraeHooksInstaller.install(into: original, relayPath: relayPath)
        }
        try ConfigFile.backupThenWrite(path: url, newContent: updated)
    }

    // MARK: - 灵动岛答题 hook（随 Claude hooks 装卸，设置里单独开关）

    /// 按开关给 settings.json 内容带上或去掉答题 hook。
    /// 开着却找不到 eureka-ask（开发环境没构建它）时抛错，不装一条指向不存在文件的 hook
    private func applyAskHook(to json: String) throws -> String {
        guard askHookEnabled() else { return try ClaudeAskHookInstaller.uninstall(from: json) }
        guard let ask = RelaySyncer.syncAsk() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey: "找不到 eureka-ask（应与应用同目录）",
            ])
        }
        return try ClaudeAskHookInstaller.install(into: json, askPath: ask.path)
    }

    /// 设置里切换「在灵动岛上回答 Claude 的提问」时调用，只增删答题那一条：
    /// - Claude hooks 已装好：按开关装上或卸掉；
    /// - 没装 Claude hooks、但答题那条单独装着：关掉时照样卸掉（不然开关关了 hook 还在）；
    /// - 两样都没有：什么都不写（等用户装 hooks 时一并带上）
    func applyAskHookSetting() {
        refresh()
        let diagnosis = diagnosis(for: .claudeHooks)
        let askEntryPresent = ClaudeAskHookInstaller.hasAnyEntry(
            in: ConfigFile.read(EurekaCLI.claudeSettingsURL))
        guard diagnosis.isInstalledInSomeForm || askEntryPresent else { return }
        guard !diagnosis.blocksAutomaticWrite else {
            message = "Claude Code hooks：\(diagnosis.detail ?? "配置异常")，未改动答题 hook"
            return
        }
        let url = EurekaCLI.claudeSettingsURL
        do {
            let original = ConfigFile.read(url)
            let updated = try applyAskHook(to: original)
            guard updated != original else { return }
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            message = askHookEnabled()
                ? "已开启在灵动岛上回答 Claude 的提问（原配置已备份）"
                : "已关闭在灵动岛上回答 Claude 的提问，提问回到终端（原配置已备份）"
        } catch {
            message = "答题 hook 更新失败：\(error)（未改动原文件）"
        }
        refresh()
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
            // Claude hooks 健康但答题 hook 与开关不一致（升级后首次带上它 / 二进制路径变了）也要重写
            let askOutOfSync = integration == .claudeHooks && askHookInstalled != askHookEnabled()
            guard !diagnosis.isHealthy || askOutOfSync else { continue }
            guard let relay = RelaySyncer.sync() else { continue }
            if (try? write(integration, relayPath: relay.path)) != nil {
                updated.append(integration.title)
            }
        }
        if syncStandaloneAskEntry() {
            updated.append("灵动岛答题 hook")
        }
        autoUpdateSkipped = skipped
        if !updated.isEmpty {
            message = "已自动更新：\(updated.joined(separator: "、"))（原配置已备份）"
        }
        if !updated.isEmpty || !skipped.isEmpty { refresh() }
    }

    /// 没装 Claude hooks、settings.json 里却单独装着答题那一条（上面的循环会跳过它）：
    /// 与开关不一致或不是当前写法（路径变了 / 挂错事件）就按开关重写这一条。写了盘返回 true
    private func syncStandaloneAskEntry() -> Bool {
        let diagnosis = diagnosis(for: .claudeHooks)
        guard !diagnosis.isInstalledInSomeForm, !diagnosis.blocksAutomaticWrite,
              askHookInstalled != askHookEnabled() else { return false }
        let url = claudeSettingsURL
        let original = ConfigFile.read(url)
        guard ClaudeAskHookInstaller.hasAnyEntry(in: original),
              let updated = try? applyAskHook(to: original), updated != original,
              (try? ConfigFile.backupThenWrite(path: url, newContent: updated)) != nil
        else { return false }
        return true
    }

}

// 刻意不提供 installAll()/uninstallAll()：一个按钮同时改写多个 agent 的配置文件，
// 必然会给「只用其中一个」的用户凭空造出别的 agent 的配置（审计页那个横幅就这样
// 给纯 Claude 用户建过 ~/.codex/config.toml）。要装哪项就调哪项。
