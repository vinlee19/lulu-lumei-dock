import EurekaInstall
import Foundation

/// 命令行模式（不起 GUI）：hooks 安装/卸载/状态。
/// M7 会在设置 UI 里提供同样能力，CLI 先行便于里程碑验证与脚本化。
enum EurekaCLI {
    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    /// 返回 true 表示已按 CLI 处理，调用方应直接退出
    static func runIfNeeded() -> Bool {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { return false }
        switch first {
        case "--install-claude-hooks":
            installClaudeHooks()
        case "--uninstall-claude-hooks":
            uninstallClaudeHooks()
        case "--hooks-status":
            printStatus()
        case "--render-previews":
            let dir = args.count > 1 ? args[1] : "/tmp/eureka-previews"
            MainActor.assumeIsolated {
                PreviewRenderer.renderAll(to: dir)
            }
        case "--help", "-h":
            printUsage()
        default:
            return false
        }
        return true
    }

    private static func installClaudeHooks() {
        guard let relay = RelaySyncer.sync() else {
            print("错误：找不到 eureka-relay 二进制（应与本程序同目录）")
            exit(1)
        }
        let url = claudeSettingsURL
        do {
            let original = ConfigFile.read(url)
            let updated = try ClaudeHooksInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print("✓ Claude hooks 已安装到 \(url.path)")
            print("  relay: \(relay.path)")
            if let backup = ConfigFile.backups(for: url).first {
                print("  备份: \(backup.lastPathComponent)")
            }
        } catch {
            print("安装失败: \(error)")
            exit(1)
        }
    }

    private static func uninstallClaudeHooks() {
        let url = claudeSettingsURL
        do {
            let original = ConfigFile.read(url)
            guard !original.isEmpty else {
                print("settings.json 不存在，无需卸载")
                return
            }
            let updated = try ClaudeHooksInstaller.uninstall(from: original)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print("✓ Claude hooks 已卸载")
        } catch {
            print("卸载失败: \(error)")
            exit(1)
        }
    }

    private static func printStatus() {
        let claude = ClaudeHooksInstaller.status(of: ConfigFile.read(claudeSettingsURL))
        print("Claude hooks: \(claude.rawValue)")
        print("relay 稳定路径: \(RelaySyncer.stableRelayURL.path)")
    }

    private static func printUsage() {
        print("""
        eureka [选项]
          （无参数）                 启动菜单栏应用
          --install-claude-hooks    安装 Claude Code hooks（写前备份）
          --uninstall-claude-hooks  卸载 Claude Code hooks
          --hooks-status            查看安装状态
        """)
    }
}
