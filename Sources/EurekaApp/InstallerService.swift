import EurekaInstall
import Foundation

/// 设置页的 hooks/notify 装卸（与 CLI 共用 EurekaInstall 纯逻辑 + ConfigFile）
@MainActor
final class InstallerService: ObservableObject {
    @Published private(set) var claudeStatus: InstallStatus = .none
    @Published private(set) var codexStatus: InstallStatus = .none
    @Published private(set) var message: String?

    var claudeSettingsURL: URL { EurekaCLI.claudeSettingsURL }
    var codexConfigURL: URL { EurekaCLI.codexConfigURL }

    func refresh() {
        claudeStatus = ClaudeHooksInstaller.status(of: ConfigFile.read(claudeSettingsURL))
        codexStatus = CodexNotifyInstaller.status(of: ConfigFile.read(codexConfigURL))
    }

    func installAll() {
        guard let relay = RelaySyncer.sync() else {
            message = "找不到 eureka-relay（应与应用同目录）"
            return
        }
        var results: [String] = []
        do {
            let original = ConfigFile.read(claudeSettingsURL)
            let updated = try ClaudeHooksInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: claudeSettingsURL, newContent: updated)
            results.append("Claude hooks ✓")
        } catch {
            results.append("Claude hooks 失败：\(error)")
        }
        do {
            let original = ConfigFile.read(codexConfigURL)
            let updated = try CodexNotifyInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: codexConfigURL, newContent: updated)
            results.append("Codex notify ✓")
        } catch {
            results.append("Codex notify 失败：\(error)")
        }
        message = results.joined(separator: "；") + "（原配置已自动备份）"
        refresh()
    }

    func uninstallAll() {
        var results: [String] = []
        do {
            let original = ConfigFile.read(claudeSettingsURL)
            if !original.isEmpty {
                let updated = try ClaudeHooksInstaller.uninstall(from: original)
                try ConfigFile.backupThenWrite(path: claudeSettingsURL, newContent: updated)
            }
            results.append("Claude hooks 已卸载")
        } catch {
            results.append("Claude 卸载失败：\(error)")
        }
        do {
            let original = ConfigFile.read(codexConfigURL)
            if !original.isEmpty {
                let updated = CodexNotifyInstaller.uninstall(from: original)
                try ConfigFile.backupThenWrite(path: codexConfigURL, newContent: updated)
            }
            results.append("Codex notify 已卸载")
        } catch {
            results.append("Codex 卸载失败：\(error)")
        }
        message = results.joined(separator: "；")
        refresh()
    }
}
