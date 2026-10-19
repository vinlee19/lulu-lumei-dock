import EurekaInstall
import EurekaKit
import Foundation

/// Settings-page install/uninstall of hooks/notify (shares EurekaInstall's pure logic + ConfigFile
/// with the CLI).
///
/// Safety contract (the user explicitly asked: "don't mess with user configs / report anomalies when detected"):
/// - **Never proactively install** an integration the user hasn't clicked, and touch only one
///   integration's config file at a time (see the note at the end of the file).
/// - Only add/remove our own entries whose command contains `lululumei-relay` (or the legacy
///   `eureka-relay`); others' hooks stay byte-for-byte.
/// - Codex allows only one top-level notify: when someone else holds it, chain (the relay forwards
///   to the original program first, then records), and restore the original value on uninstall; a
///   value that can't be parsed is still never rewritten.
/// - Every write goes through `ConfigFile.backupThenWrite`, leaving `*.bak.eureka.<timestamp>`.
/// - When diagnostics find a `blocksAutomaticWrite` anomaly (path hand-edited / config unparseable
///   / held by someone else), auto-update is skipped entirely and the reason is shown; a config we
///   don't understand is never edited on a guess.
@MainActor
final class InstallerService: ObservableObject {
    /// Integrations that can be toggled independently
    enum Integration: String, CaseIterable, Identifiable {
        case claudeHooks
        case codexNotify
        case codexHooks
        case traeHooks

        var id: String { rawValue }

        var title: String {
            switch self {
            case .claudeHooks: return L10n.text("Claude Code hooks", zhHans: "Claude Code 钩子")
            case .codexNotify: return L10n.text("Codex notify", zhHans: "Codex 通知")
            case .codexHooks: return L10n.text("Codex hooks", zhHans: "Codex 钩子")
            case .traeHooks: return L10n.text("Trae hooks", zhHans: "Trae 钩子")
            }
        }

        /// Files that will be rewritten (the user must be told explicitly before installing)
        var configURL: URL {
            switch self {
            case .claudeHooks: return EurekaCLI.claudeSettingsURL
            case .codexNotify: return EurekaCLI.codexConfigURL
            case .codexHooks: return EurekaCLI.codexHooksURL
            // Only the CN edition has hooks (the international edition's ai-agent has no hooks
            // module)
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

        /// What capabilities installing it adds
        var benefit: String {
            switch self {
            case .claudeHooks:
                return L10n.text("Live task cards, permission reminders, tool-call auditing, and the session terminal", zhHans: "实时任务卡、等待授权提醒、工具调用审计、会话所在终端")
            case .codexNotify:
                return L10n.text("Turn completion notifications and the session terminal", zhHans: "回合完成通知、会话所在终端")
            case .codexHooks:
                // The main reason to install it is waiting-for-permission: Codex's rollout doesn't
                // record permission events, so without hooks this state is never visible for Codex
                return L10n.text("Permission reminders, live task cards, and the exact session terminal", zhHans: "等待授权提醒、实时任务卡、精确的会话所在终端")
            case .traeHooks:
                // Trae's session DB is SQLCipher-encrypted and has no plaintext transcript ->
                // **without hooks the Dynamic Island can't see Trae at all** (the only source that
                // breaks the "visible even without hooks" convention). Deliberately no
                // "waiting-for-permission reminder": Trae has no permission-request hook event.
                //
                // ⚠️ Trae's hooks are a **per-account, gradually rolled out** server-side switch (see `TraeHooksInstaller`'s notes);
                // until it's enabled, installing won't fire anything. The copy must say this up front, or users will think we're broken.
                return L10n.text("Live task cards (Trae’s only live channel), tool-call auditing, and the session terminal; requires hooks to be enabled for your Trae account (a Hooks page in Settings means they are enabled)", zhHans: "实时任务卡（Trae 唯一的实时通道）、工具调用审计、会话所在终端；需 Trae 已对你的账号开放 hooks（设置里能看到 Hooks 页即已开放）")
            }
        }
    }

    @Published private(set) var diagnoses: [Integration: HookDiagnosis] = [:]
    /// Other parties' hooks in the same config (informational only; never acted on)
    @Published private(set) var foreignHooks = ForeignHookReport()
    /// Short name of the program our Codex notify forwards to, when it is chained.
    @Published private(set) var codexNotifyChainedTo: String?
    @Published private(set) var message: String?
    /// Whether the last auto-update was skipped due to an anomaly (the reason must be visible to
    /// the user, not silent)
    @Published private(set) var autoUpdateSkipped: [Integration] = []

    /// Compatibility for an old call site (AuditView checks whether Claude hooks are available)
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

    /// The relay's stable path. hooks/notify configs should only ever reference this.
    var stableRelayPath: String { RelaySyncer.stableRelayURL.path }

    /// Whether the relay is actually executable; the basis for diagnosing `.relayMissing`
    private func relayIsExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    func refresh() {
        let relay = stableRelayPath
        let claudeJSON = ConfigFile.read(claudeSettingsURL)
        diagnoses[.claudeHooks] = ClaudeHooksInstaller.diagnose(
            json: claudeJSON, expectedRelayPath: relay,
            relayIsExecutable: relayIsExecutable)
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
        // Merge others' entries from all three configs for display (locally ~/.codex/hooks.json is
        // held by Otty)
        foreignHooks = ClaudeHooksInstaller.foreignHooks(in: claudeJSON)
            .merging(CodexHooksInstaller.foreignHooks(in: codexHooksJSON))
            .merging(TraeHooksInstaller.foreignHooks(in: traeHooksJSON))
    }

    func diagnosis(for integration: Integration) -> HookDiagnosis {
        diagnoses[integration] ?? .notInstalled
    }

    // MARK: - Per-item install/uninstall (the only entry point is the Settings page)

    /// Installs/updates a single item. The caller must already have shown the user "which file will
    /// change + it is backed up first".
    ///
    /// `repairDriftedPath` is passed true only by the "switch to stable path" button: when the path was hand-edited the default is to **refuse** the rewrite,
    /// otherwise any "Install" button would silently overwrite a path the user edited themselves.
    func install(_ integration: Integration, repairDriftedPath: Bool = false) {
        guard let relay = RelaySyncer.sync() else {
            message = L10n.text("eureka-relay was not found (expected beside the app); no changes made", zhHans: "找不到 eureka-relay（应与应用同目录），未做任何改动")
            return
        }
        // Unparseable / held by someone else / path hand-edited -> refuse to write and tell the
        // user why
        let diagnosis = diagnosis(for: integration)
        if case .unparseable = diagnosis {
            message = L10n.format("%@: %@", zhHans: "%@：%@", String(integration.title), String(diagnosis.detail ?? L10n.text("Unable to parse configuration", zhHans: "配置无法解析")))
            return
        }
        if case .foreignOccupied = diagnosis {
            message = L10n.format("%@: %@", zhHans: "%@：%@", String(integration.title), String(diagnosis.detail ?? L10n.text("Already used by another program", zhHans: "已被他人占用")))
            return
        }
        if case .driftedPath = diagnosis, !repairDriftedPath {
            message = L10n.format("%@: the configured path was changed; no changes made. To restore the stable path, click “Use Stable Path” for this integration.", zhHans: "%@：配置里的路径被改过，未做改动。确认要改回稳定路径请点该项的「改为稳定路径」。", String(integration.title))
            return
        }
        do {
            try write(integration, relayPath: relay.path)
            let chainNote: String
            if case .chainable(let owner) = diagnosis {
                chainNote = L10n.format(", chained to %@", zhHans: "，已与 %@ 串联", String(owner))
            } else {
                chainNote = ""
            }
            message = L10n.format("%@ installed/updated%@ (original configuration backed up to %@.bak.eureka.*)", zhHans: "%@ 已安装/更新%@（原配置已备份到 %@.bak.eureka.*）", String(integration.title), String(chainNote), String(integration.configURL.lastPathComponent))
        } catch {
            message = L10n.format("%@ failed: %@ (original file unchanged)", zhHans: "%@ 失败：%@（未改动原文件）", String(integration.title), String(describing: error))
        }
        refresh()
    }

    func uninstall(_ integration: Integration) {
        do {
            let url = integration.configURL
            let original = ConfigFile.read(url)
            guard !original.isEmpty else {
                message = L10n.format("%@: configuration file is empty; nothing to uninstall", zhHans: "%@：配置文件为空，无需卸载", String(integration.title))
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
            message = L10n.format("%@ uninstalled (only our own entries were removed%@", zhHans: "%@ 已卸载（只移除了我们自己的条目%@", String(integration.title), String(restored ? L10n.text(", original notify restored)", zhHans: "，已恢复原来的 notify）") : L10n.text(")", zhHans: "）")))
        } catch {
            message = L10n.format("Failed to uninstall %@: %@ (original file unchanged)", zhHans: "%@ 卸载失败：%@（未改动原文件）", String(integration.title), String(describing: error))
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
        case .codexHooks:
            updated = try CodexHooksInstaller.install(into: original, relayPath: relayPath)
        case .traeHooks:
            updated = try TraeHooksInstaller.install(into: original, relayPath: relayPath)
        }
        try ConfigFile.backupThenWrite(path: url, newContent: updated)
    }

    // MARK: - Auto-update (only touches what is already installed)

    /// After an app upgrade, refreshes **already installed** integrations to the current version.
    ///
    /// Three hard constraints:
    /// 1. Only handle items that are `isInstalledInSomeForm`; never install something the user
    ///    didn't agree to just "while we're at it";
    /// 2. `blocksAutomaticWrite` anomalies are skipped entirely and recorded in `autoUpdateSkipped`
    ///    (the UI must show them);
    /// 3. Items already `.installed` aren't rewritten, so a backup file isn't generated on every
    ///    launch.
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
            let separator = L10n.text(", ", zhHans: "、")
            message = L10n.format("Automatically updated: %@ (original configuration backed up)", zhHans: "已自动更新：%@（原配置已备份）", String(updated.joined(separator: separator)))
        }
        if !updated.isEmpty || !skipped.isEmpty { refresh() }
    }

}

// Deliberately no installAll()/uninstallAll(): one button rewriting several agents' config files at
// once inevitably conjures up other agents' configs for users who use only one of them (the audit
// page's banner did exactly that, creating ~/.codex/config.toml for a Claude-only user). Call the
// one you want to install.
