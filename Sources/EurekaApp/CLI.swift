import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import EurekaUsage
import Foundation

/// 命令行模式（不起 GUI）：hooks 安装/卸载/状态。
/// M7 会在设置 UI 里提供同样能力，CLI 先行便于里程碑验证与脚本化。
enum EurekaCLI {
    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var codexConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
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
        case "--install-codex-notify":
            installCodexNotify()
        case "--uninstall-codex-notify":
            uninstallCodexNotify()
        case "--hooks-status":
            printStatus()
        case "--usage-snapshot":
            usageSnapshot()
        case "--limits-snapshot":
            limitsSnapshot(includeClaude: args.contains("--claude"))
        case "--audit-snapshot":
            auditSnapshot(
                riskOnly: args.contains("--risk-only"),
                limit: args.firstIndex(of: "--limit").flatMap { idx in
                    args.indices.contains(idx + 1) ? Int(args[idx + 1]) : nil
                } ?? 50)
        case "--render-previews":
            let dir = args.count > 1 ? args[1] : "/tmp/eureka-previews"
            MainActor.assumeIsolated {
                PreviewRenderer.renderAll(to: dir)
            }
        case "--render-mascot":
            let dir = args.count > 1 ? args[1] : "/tmp/eureka-mascot"
            MainActor.assumeIsolated {
                PreviewRenderer.renderMascot(to: dir)
            }
        case "--prep-mascot-assets":
            let src = args.count > 1 ? args[1] : "Sources/EurekaApp/Resources/mascots/lulu"
            let dst = args.count > 2 ? args[2] : "/tmp/lulu-cut"
            MascotAssetPrep.run(srcDir: src, dstDir: dst)
        case "--render-icon":
            let path = args.count > 1 ? args[1] : "/tmp/eureka-icon-1024.png"
            MainActor.assumeIsolated {
                IconRenderer.render(to: path)
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

    private static func installCodexNotify() {
        guard let relay = RelaySyncer.sync() else {
            print("错误：找不到 eureka-relay 二进制（应与本程序同目录）")
            exit(1)
        }
        let url = codexConfigURL
        do {
            let original = ConfigFile.read(url)
            let updated = try CodexNotifyInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print("✓ Codex notify 已安装到 \(url.path)")
        } catch {
            print("安装失败: \(error)")
            exit(1)
        }
    }

    private static func uninstallCodexNotify() {
        let url = codexConfigURL
        let original = ConfigFile.read(url)
        guard !original.isEmpty else {
            print("config.toml 不存在，无需卸载")
            return
        }
        do {
            let updated = CodexNotifyInstaller.uninstall(from: original)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print("✓ Codex notify 已卸载")
        } catch {
            print("卸载失败: \(error)")
            exit(1)
        }
    }

    private static func printStatus() {
        let claude = ClaudeHooksInstaller.status(of: ConfigFile.read(claudeSettingsURL))
        let codex = CodexNotifyInstaller.status(of: ConfigFile.read(codexConfigURL))
        print("Claude hooks: \(claude.rawValue)")
        print("Codex notify: \(codex.rawValue)")
        print("relay 稳定路径: \(RelaySyncer.stableRelayURL.path)")
    }

    /// 一次性全量扫描并输出今日/本周聚合（ccusage 对拍脚本用）
    private static func usageSnapshot() {
        do {
            let store = try EurekaStore(path: EurekaStore.defaultURL())
            let claude = ClaudeTranscriptScanner(
                projectsRoot: ClaudeTranscriptScanner.defaultProjectsRoot(), store: store)
            let codex = CodexUsageScanner(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), store: store)
            let opencode = OpencodeUsageScanner(dbPath: OpencodePaths.db(), store: store)
            let grok = GrokUsageScanner(sessionsRoot: GrokPaths.sessionsRoot(), store: store)
            let newClaude = try claude.scanOnce()
            let newCodex = try codex.scanOnce()
            let newOpencode = try opencode.scanOnce()
            let newGrok = try grok.scanOnce()  // grok 无 token，仅入工具调用计数
            FileHandle.standardError.write(Data(
                "扫描完成：claude +\(newClaude) 条，codex +\(newCodex) 条，opencode +\(newOpencode) 条，grok 工具 +\(newGrok)\n".utf8))

            let now = Date()
            let today = try store.usage.totalsByModel(
                from: UsageAggregator.dayStart(of: now), to: now)
            var output: [[String: Any]] = []
            for row in today {
                output.append([
                    "source": row.source.rawValue,
                    "model": row.model,
                    "inputTokens": row.inputTokens,
                    "outputTokens": row.outputTokens,
                    "cacheCreationTokens": row.cacheCreationTokens,
                    "cacheReadTokens": row.cacheReadTokens,
                    "requests": row.requestCount,
                ])
            }
            let json = try JSONSerialization.data(
                withJSONObject: ["today": output],
                options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            print("{\"error\": \"\(error)\"}")
            exit(1)
        }
    }

    /// 审计快照：跑一次 Codex 审计扫描，再输出最近的操作流水（调试/脚本对拍用）
    private static func auditSnapshot(riskOnly: Bool, limit: Int) {
        do {
            let store = try EurekaStore(path: EurekaStore.defaultURL())
            let pipeline = AuditPipeline(store: store)
            let scanner = CodexAuditScanner(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
                store: store, pipeline: pipeline)
            let newCount = try scanner.scanOnce()
            let riskTotal = try store.audit.count(.init(riskOnly: true))
            FileHandle.standardError.write(Data(
                "审计扫描完成：codex +\(newCount) 条，累计风险 \(riskTotal) 条\n".utf8))

            let rows = try store.audit.recent(.init(riskOnly: riskOnly), limit: limit)
            let isoFormatter = ISO8601DateFormatter()
            var output: [[String: Any]] = []
            for row in rows {
                var item: [String: Any] = [
                    "ts": isoFormatter.string(from: row.timestamp),
                    "source": row.source.rawValue,
                    "session": row.sessionId,
                    "kind": row.kind.rawValue,
                    "tool": row.tool,
                    "detail": row.detail,
                    "isError": row.isError,
                ]
                if let exitCode = row.exitCode { item["exitCode"] = exitCode }
                if let level = row.riskLevel { item["riskLevel"] = level.label }
                if let rule = row.riskRule { item["riskRule"] = rule }
                output.append(item)
            }
            let json = try JSONSerialization.data(
                withJSONObject: ["count": rows.count, "riskTotal": riskTotal, "events": output],
                options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: json, as: UTF8.self))
        } catch {
            print("{\"error\": \"\(error)\"}")
            exit(1)
        }
    }

    /// 限额快照（默认只读本地 Codex；--claude 同时测非官方接口）
    private static func limitsSnapshot(includeClaude: Bool) {
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            func describe(_ snapshot: RateLimitSnapshot?) -> String {
                guard let snapshot else { return "（无数据 → UI 隐藏）" }
                var parts: [String] = []
                if let plan = snapshot.planType { parts.append("plan=\(plan)") }
                if let primary = snapshot.primary {
                    let label = primary.windowMinutes == 10080 ? "周"
                        : primary.windowMinutes == 43200 ? "月"
                        : "5h"
                    parts.append(String(format: "\(label)=%.1f%%", primary.usedPercent))
                    if let resets = primary.resetsAt {
                        parts.append("\(label)重置=\(resets)")
                    }
                }
                if let secondary = snapshot.secondary {
                    parts.append(String(format: "周=%.1f%%", secondary.usedPercent))
                }
                if snapshot.isStale { parts.append("（截至 \(snapshot.asOf)）") }
                return parts.joined(separator: " ")
            }

            let codex = await CodexRateLimitProvider(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot()).snapshot()
            print("Codex: \(describe(codex))")
            let grok = await GrokRateLimitProvider(logURL: GrokPaths.unifiedLog()).snapshot()
            print("Grok: \(describe(grok))")
            if includeClaude {
                let provider = ClaudeOAuthUsageProvider()
                let claude = await provider.snapshot()
                print("Claude: \(describe(claude))")
                if let failure = provider.lastFailure {
                    print("Claude 提示: \(failure)")
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    private static func printUsage() {
        print("""
        eureka [选项]
          （无参数）                 启动菜单栏应用
          --install-claude-hooks    安装 Claude Code hooks（写前备份）
          --uninstall-claude-hooks  卸载 Claude Code hooks
          --install-codex-notify    安装 Codex notify（写前备份）
          --uninstall-codex-notify  卸载 Codex notify
          --hooks-status            查看安装状态
          --audit-snapshot          扫描并输出 agent 操作审计流水（--risk-only 仅风险 / --limit N）
          --render-previews [目录]   离屏渲染灵动岛各形态 PNG
        """)
    }
}
