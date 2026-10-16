import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import EurekaSync
import EurekaUsage
import Foundation

/// 命令行模式（不起 GUI）：hooks 安装/卸载/状态。
/// 设置 UI 亦提供同样能力，CLI 便于脚本化与无 GUI 环境使用。
enum EurekaCLI {
    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
    }

    static var codexConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/config.toml")
    }

    /// Codex 的 hooks 配置（与 notify 的 config.toml 是**两个不同文件**）
    static var codexHooksURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/hooks.json")
    }

    /// Trae 的全局 hooks 配置。**只有 CN 版有 hooks**，所以固定指向 `~/.trae-cn`。
    static var traeHooksURL: URL { TraePaths.hooksConfig() }

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
        case "--pricing-resolve":
            pricingResolve(args: Array(args.dropFirst()))
        case "--parquet-inspect":
            // Debug: decode Parquet files written by the audit archive and print rows / schema per file
            let files = Array(args.dropFirst())
            guard !files.isEmpty else {
                print(L10n.text("usage: --parquet-inspect <file.parquet>…", zhHans: "用法：--parquet-inspect <file.parquet>…"))
                exit(2)
            }
            var failed = false
            for path in files {
                do {
                    let table = try ParquetReader.read(contentsOf: URL(fileURLWithPath: path))
                    let schema = table.columns.map { "\($0.name)\($0.required ? "" : "?")" }.joined(separator: ",")
                    print("\(path)\t\(table.rowCount) rows\t\(table.createdBy ?? "-")\t[\(schema)]")
                } catch {
                    failed = true
                    print("\(path)\tERROR: \(error)")
                }
            }
            if failed { exit(1) }
        case "--audit-archive":
            // 调试：把审计记录按 UTC 日物化为 Parquet（已脱敏）到指定目录；不上传、不动台账以外的数据
            let dir = args.count > 1 ? args[1] : "/tmp/eureka-audit-archive"
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                let outcome = AuditArchive.materialize(
                    store: store, outDir: URL(fileURLWithPath: dir, isDirectory: true),
                    host: ProcessInfo.processInfo.hostName, appVersion: Self.appVersion, cutoff: nil)
                print(L10n.format("Wrote %@ days → %@", zhHans: "写入 %@ 天 → %@", String(outcome.writtenDays.count), String(dir)))
                for error in outcome.errors { print("  \(error)") }
            } catch {
                print(L10n.format("Failed to open database: %@", zhHans: "打开数据库失败：%@", String(describing: error)))
                exit(1)
            }
        case "--pricing-refresh":
            let started = Date()
            let outcome = CatalogRefresher.refresh(previous: .empty, fetch: PricingCatalogService.fetch)
            print(L10n.format("Remote pricing catalog fetch: %@, took %@; LiteLLM %@ entries, models.dev %@ providers", zhHans: "联网拉取价格目录：%@，耗时 %@；LiteLLM %@ 条，models.dev %@ 个 provider",
                String(outcome.succeeded ? L10n.text("succeeded", zhHans: "成功") : L10n.text("failed", zhHans: "失败")),
                String(String(format: "%.1fs", Date().timeIntervalSince(started))),
                String(outcome.catalog.litellm.count), String(outcome.catalog.modelsDev.count)))
            for error in outcome.errors { print("  \(error)") }
        case "--build-pricing-catalog":
            buildPricingCatalog(args: Array(args.dropFirst()))
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
        case "--render-knowledge":
            // 与 --render-shell 同款参数解析：--style 的值不是位置参数
            var positional = [String]()
            var styleRaw = "classic"
            var index = 1
            while index < args.count {
                if args[index] == "--style", args.indices.contains(index + 1) {
                    styleRaw = args[index + 1]
                    index += 2
                    continue
                }
                if !args[index].hasPrefix("--") { positional.append(args[index]) }
                index += 1
            }
            let dir = positional.first ?? "/tmp/eureka-knowledge"
            MainActor.assumeIsolated {
                PreviewRenderer.renderKnowledge(to: dir, style: ThemeStyle.resolve(styleRaw))
            }
        case "--render-shell":
            // 参数解析：--style 的值不是位置参数；其余非 flag 参数第一个是输出目录
            var positional = [String]()
            var styleRaw = args.contains("--raft") ? "brutal" : "classic"  // --raft 是旧 flag，兼容
            var i = 1
            while i < args.count {
                if args[i] == "--style", args.indices.contains(i + 1) {
                    styleRaw = args[i + 1]
                    i += 2
                    continue
                }
                if !args[i].hasPrefix("--") { positional.append(args[i]) }
                i += 1
            }
            let dir = positional.first ?? "/tmp/eureka-shell"
            MainActor.assumeIsolated {
                PreviewRenderer.renderShell(to: dir, style: ThemeStyle.resolve(styleRaw))
            }
        case "--render-lineage":
            let dir = args.count > 1 ? args[1] : "/tmp/eureka-lineage"
            MainActor.assumeIsolated {
                PreviewRenderer.renderLineage(to: dir)
            }
        case "--render-pages":
            // Same argument parsing as --render-shell: the value of --style is not positional
            var positional = [String]()
            var styleRaw = "classic"
            var index = 1
            while index < args.count {
                if args[index] == "--style", args.indices.contains(index + 1) {
                    styleRaw = args[index + 1]
                    index += 2
                    continue
                }
                if !args[index].hasPrefix("--") { positional.append(args[index]) }
                index += 1
            }
            let dir = positional.first ?? "/tmp/eureka-pages"
            MainActor.assumeIsolated {
                PreviewRenderer.renderPages(to: dir, style: ThemeStyle.resolve(styleRaw))
            }
        case "--mcp-inspect":
            // 走真实探测路径（remote 握手 / stdio 深探），结果落真缓存——
            // 显式执行本命令等同于在 UI 点「重新检测」（同一次性、同披露）。
            let name = args.count > 1 ? args[1] : ""
            MainActor.assumeIsolated {
                mcpInspect(name: name)
            }
        case "--prep-mascot-assets":
            let src = args.count > 1 ? args[1] : "Sources/EurekaApp/Resources/mascots/lulu"
            let dst = args.count > 2 ? args[2] : "/tmp/lulu-cut"
            MascotAssetPrep.run(srcDir: src, dstDir: dst)
        case "--pack-mascot-v3":
            guard args.count == 3 else {
                print(L10n.text("Usage: eureka --pack-mascot-v3 <12-sheet-directory> <output-PNG>", zhHans: "用法：eureka --pack-mascot-v3 <12张分镜目录> <输出PNG>"))
                exit(2)
            }
            do {
                try MascotAssetPrep.packV3(srcDir: args[1], outputPath: args[2])
            } catch {
                print(L10n.format("Packing failed: %@", zhHans: "打包失败：%@", String(error.localizedDescription)))
                exit(1)
            }
        case "--render-badges":
            let badgesPath = args.count > 1 ? args[1] : "/tmp/eureka-badges.png"
            MainActor.assumeIsolated { BadgeSheetRenderer.render(to: badgesPath) }
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
            print(L10n.text("Error: eureka-relay binary not found (expected beside this program)", zhHans: "错误：找不到 eureka-relay 二进制（应与本程序同目录）"))
            exit(1)
        }
        let url = claudeSettingsURL
        do {
            let original = ConfigFile.read(url)
            let updated = try ClaudeHooksInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print(L10n.format("✓ Claude hooks installed at %@", zhHans: "✓ Claude hooks 已安装到 %@", String(url.path)))
            print("  relay: \(relay.path)")
            if let backup = ConfigFile.backups(for: url).first {
                print(L10n.format("  Backup: %@", zhHans: "  备份: %@", String(backup.lastPathComponent)))
            }
        } catch {
            print(L10n.format("Installation failed: %@", zhHans: "安装失败: %@", String(describing: error)))
            exit(1)
        }
    }

    private static func uninstallClaudeHooks() {
        let url = claudeSettingsURL
        do {
            let original = ConfigFile.read(url)
            guard !original.isEmpty else {
                print(L10n.text("settings.json does not exist; nothing to uninstall", zhHans: "settings.json 不存在，无需卸载"))
                return
            }
            let updated = try ClaudeHooksInstaller.uninstall(from: original)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print(L10n.text("✓ Claude hooks uninstalled", zhHans: "✓ Claude hooks 已卸载"))
        } catch {
            print(L10n.format("Uninstall failed: %@", zhHans: "卸载失败: %@", String(describing: error)))
            exit(1)
        }
    }

    private static func installCodexNotify() {
        guard let relay = RelaySyncer.sync() else {
            print(L10n.text("Error: eureka-relay binary not found (expected beside this program)", zhHans: "错误：找不到 eureka-relay 二进制（应与本程序同目录）"))
            exit(1)
        }
        let url = codexConfigURL
        do {
            let original = ConfigFile.read(url)
            let updated = try CodexNotifyInstaller.install(into: original, relayPath: relay.path)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print(L10n.format("✓ Codex notify installed at %@", zhHans: "✓ Codex notify 已安装到 %@", String(url.path)))
        } catch {
            print(L10n.format("Installation failed: %@", zhHans: "安装失败: %@", String(describing: error)))
            exit(1)
        }
    }

    private static func uninstallCodexNotify() {
        let url = codexConfigURL
        let original = ConfigFile.read(url)
        guard !original.isEmpty else {
            print(L10n.text("config.toml does not exist; nothing to uninstall", zhHans: "config.toml 不存在，无需卸载"))
            return
        }
        do {
            let updated = CodexNotifyInstaller.uninstall(from: original)
            try ConfigFile.backupThenWrite(path: url, newContent: updated)
            print(L10n.text("✓ Codex notify uninstalled", zhHans: "✓ Codex notify 已卸载"))
        } catch {
            print(L10n.format("Uninstall failed: %@", zhHans: "卸载失败: %@", String(describing: error)))
            exit(1)
        }
    }

    private static func printStatus() {
        let claude = ClaudeHooksInstaller.status(of: ConfigFile.read(claudeSettingsURL))
        let codexNotify = CodexNotifyInstaller.status(of: ConfigFile.read(codexConfigURL))
        // Codex hooks 与 Trae hooks 都是独立文件，与上面两项互不相干
        let codexHooks = CodexHooksInstaller.status(of: ConfigFile.read(codexHooksURL))
        let trae = TraeHooksInstaller.status(of: ConfigFile.read(traeHooksURL))
        print("Claude hooks: \(claude.rawValue)")
        print("Codex notify: \(codexNotify.rawValue)")
        print("Codex hooks: \(codexHooks.rawValue)")
        print("Trae hooks: \(trae.rawValue)  (\(traeHooksURL.path))")
        print(L10n.format("relay stable path: %@", zhHans: "relay 稳定路径: %@", String(RelaySyncer.stableRelayURL.path)))
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
            let kimi = KimiUsageScanner(sessionsRoot: KimiPaths.sessionsRoot(), store: store)
            let gemini = GeminiUsageScanner(
                tmpRoot: GeminiPaths.tmpRoot(),
                projectsFile: GeminiPaths.projectsFile(), store: store)
            let qwen = QwenUsageScanner(projectsRoot: QwenPaths.projectsRoot(), store: store)
            let hermes = HermesUsageScanner(
                stateDBs: { HermesPaths.allStateDBs() }, store: store)
            let codebuddy = CodeBuddyUsageScanner(
                projectsRoot: CodeBuddyPaths.projectsRoot(), store: store)
            let cursor = CursorUsageScanner(
                dbPath: CursorPaths.globalStateDB(), store: store,
                workspaceStorageRoot: CursorPaths.workspaceStorageRoot(),
                sessions: { now in
                    CursorSessionIndexer.index(
                        window: CursorSessionIndexer.fullHistoryWindow,
                        maxSessions: 2000, now: now)
                        .map { ($0.id, $0.cwd, $0.lastActiveAt) }
                })
            let zcode = ZcodeUsageScanner(
                rolloutRoot: ZcodePaths.rolloutRoot(),
                dbPath: ZcodePaths.db(), store: store)
            let newClaude = try claude.scanOnce()
            let newCodex = try codex.scanOnce()
            let newOpencode = try opencode.scanOnce()
            let newGrok = try grok.scanOnce()  // 工具调用计数 + updates.jsonl 每轮用量
            let newKimi = try kimi.scanOnce()
            let newGemini = try gemini.scanOnce()
            let newQwen = try qwen.scanOnce()
            let newHermes = try hermes.scanOnce()
            let newCodeBuddy = try codebuddy.scanOnce()  // qoder 无 token（CN 后端全零），不扫描
            let newCursor = try cursor.scanOnce()  // cursor 有 token 无价（成本恒 0）
            let newZcode = try zcode.scanOnce()
            // Antigravity（实验）：CLI 调试入口总是扫（app 里受设置开关门控）
            let newAntigravity = try AntigravityUsageScanner(
                conversationsRoot: AntigravityPaths.conversationsRoot(), store: store,
                cwdResolver: { AntigravityPaths.cwd(dbURL: $0) }).scanOnce()
            try? zcode.recordPromptCounts()
            FileHandle.standardError.write(Data(
                L10n.format("Scan complete: claude +%@ records, codex +%@ records, OpenCode +%@ records, grok tools/usage +%@, kimi +%@ records, gemini +%@ records, qwen +%@ records, hermes +%@ records, codebuddy +%@ records, cursor +%@ records, zcode +%@ records, antigravity +%@ records\n", zhHans: "扫描完成：claude +%@ 条，codex +%@ 条，OpenCode +%@ 条，grok 工具/用量 +%@，kimi +%@ 条，gemini +%@ 条，qwen +%@ 条，hermes +%@ 条，codebuddy +%@ 条，cursor +%@ 条，zcode +%@ 条，antigravity +%@ 条\n",
                    String(newClaude), String(newCodex), String(newOpencode), String(newGrok),
                    String(newKimi), String(newGemini), String(newQwen), String(newHermes),
                    String(newCodeBuddy), String(newCursor), String(newZcode), String(newAntigravity)).utf8))

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
                L10n.format(
                    "Audit scan complete: codex +%@ records, %@ total risks\n",
                    zhHans: "审计扫描完成：codex +%@ 条，累计风险 %@ 条\n",
                    String(newCount), String(riskTotal)).utf8))

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
                guard let snapshot else { return L10n.text("(No data → hidden in UI)", zhHans: "（无数据 → UI 隐藏）") }
                var parts: [String] = []
                if let plan = snapshot.planType { parts.append("plan=\(plan)") }
                if let primary = snapshot.primary {
                    let label = primary.windowMinutes == 10080 ? L10n.text("Week", zhHans: "周")
                        : primary.windowMinutes == 43200 ? L10n.text("Month", zhHans: "月")
                        : "5h"
                    parts.append(String(format: "\(label)=%.1f%%", primary.usedPercent))
                    if let resets = primary.resetsAt {
                        parts.append(L10n.format("%@ reset=%@", zhHans: "%@重置=%@", String(label), String(describing: resets)))
                    }
                }
                if let secondary = snapshot.secondary {
                    parts.append(L10n.format("Week=%@%%", zhHans: "周=%@%%", String(String(format: "%.1f", secondary.usedPercent))))
                }
                if snapshot.isStale { parts.append(L10n.format("(As of %@)", zhHans: "（截至 %@）", String(describing: snapshot.asOf))) }
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
                    print(L10n.format("Claude note: %@", zhHans: "Claude 提示: %@", String(failure)))
                }
            }
            semaphore.signal()
        }
        semaphore.wait()
    }

    /// --pricing-resolve <model…> [--provider p] [--catalog 目录快照]：打印价格解析结果与出处。
    /// 不给模型名时解析本地账本里出现过的全部 (source, model, provider)。
    private static func pricingResolve(args: [String]) {
        var models: [String] = []
        var provider: String?
        var catalogPath: String?
        var index = 0
        while index < args.count {
            switch args[index] {
            case "--provider" where index + 1 < args.count:
                provider = args[index + 1]
                index += 1
            case "--catalog" where index + 1 < args.count:
                catalogPath = args[index + 1]
                index += 1
            default:
                models.append(args[index])
            }
            index += 1
        }
        let store = PricingCatalogStore()
        var paths = PricingPaths.app
        if let catalogPath {
            paths.bundledSnapshot = URL(fileURLWithPath: catalogPath)
            paths.cache = nil
        }
        store.loadIfNeeded(paths: paths)
        let table = store.current
        var pairs: [(source: String, model: String, provider: String?)] = models.map {
            ("-", $0, provider)
        }
        if pairs.isEmpty, let db = try? EurekaStore(path: EurekaStore.defaultURL()) {
            pairs = ((try? db.usage.distinctModels()) ?? []).map {
                ($0.source.rawValue, $0.model, $0.provider)
            }
        }
        print(L10n.format("Pricing catalog source: %@", zhHans: "价格目录来源：%@", String(store.currentOrigin.rawValue)))
        for pair in pairs {
            let resolution = table.resolution(for: pair.model, provider: pair.provider)
            let price = resolution.price.map {
                String(format: "$%g / $%g", $0.inputPerM ?? 0, $0.outputPerM ?? 0)
            } ?? "—"
            let label = pair.provider.map { "\(pair.model) @\($0)" } ?? pair.model
            print("\(pair.source.padding(toLength: 9, withPad: " ", startingAt: 0)) "
                + "\(label.padding(toLength: 48, withPad: " ", startingAt: 0)) "
                + "\(price.padding(toLength: 16, withPad: " ", startingAt: 0)) \(resolution.summary)")
        }
    }

    /// --build-pricing-catalog <litellm.json> <models.dev.json> <输出>：生成随包价格目录快照
    /// （Scripts/update-pricing-catalog.sh 调用；与运行时同一套解析/校验代码）
    private static func buildPricingCatalog(args: [String]) {
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data(
                L10n.text(
                    "Usage: --build-pricing-catalog <litellm.json> <models.dev.json> <output>\n",
                    zhHans: "用法：--build-pricing-catalog <litellm.json> <models.dev.json> <输出>\n").utf8))
            exit(2)
        }
        do {
            let now = Date()
            let litellm = try PriceCatalogParser.parseLiteLLM(
                Data(contentsOf: URL(fileURLWithPath: args[0])))
            let modelsDev = try PriceCatalogParser.parseModelsDev(
                Data(contentsOf: URL(fileURLWithPath: args[1])))
            let catalog = PriceCatalog(
                litellm: litellm, modelsDev: modelsDev,
                litellmMeta: .init(fetchedAt: now, entryCount: litellm.count),
                modelsDevMeta: .init(
                    fetchedAt: now, entryCount: modelsDev.values.reduce(0) { $0 + $1.models.count }))
            let data = try PricingCatalogStore.encode(catalog)
            try data.write(to: URL(fileURLWithPath: args[2]), options: .atomic)
            FileHandle.standardError.write(Data(
                L10n.format("Generated %@: LiteLLM %@ entries, models.dev %@ providers, %@ KB\n", zhHans: "已生成 %@：LiteLLM %@ 条，models.dev %@ 个 provider，%@ KB\n", String(args[2]), String(litellm.count), String(modelsDev.count), String(data.count / 1024)).utf8))
        } catch {
            FileHandle.standardError.write(Data(L10n.format(
                "Generation failed: %@\n",
                zhHans: "生成失败：%@\n",
                String(describing: error)).utf8))
            exit(1)
        }
    }

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    private static func printUsage() {
        print(L10n.text("""
        eureka [options]
          (no arguments)           Launch the menu-bar app
          --install-claude-hooks    Install Claude Code hooks (back up before writing)
          --uninstall-claude-hooks  Uninstall Claude Code hooks
          --install-codex-notify    Install Codex notify (back up before writing)
          --uninstall-codex-notify  Uninstall Codex notify
          --hooks-status            Show installation status
          --audit-snapshot          Scan and print agent audit events (--risk-only for risks / --limit N)
          --parquet-inspect <files…> Decode Parquet archives; print rows and columns per file (read-only)
          --pricing-resolve [models…] Print resolved prices and sources (--provider p; all local ledger models if omitted)
          --build-pricing-catalog <litellm> <models.dev> <output>  Generate the bundled pricing catalog snapshot
          --pricing-refresh         Fetch the pricing catalog with the app’s network code (print only, without caching)
          --mcp-inspect <name>       Inspect an MCP server (remote handshake / deep stdio inspection) and cache results
          --render-previews [dir]    Offscreen-render Dynamic Island states to PNG
          --render-mascot [dir]      Offscreen-render all mascot variants and storyboards to PNG
          --pack-mascot-v3 <dir> <file>  Pack 12 2×2 storyboards into a v3 atlas
          --render-shell [dir]       Offscreen-render the sidebar (including branding) and audit page in light/dark modes
          --render-lineage [dir]     Offscreen-render turn lineage graphs (golden baseline + live data)
        """, zhHans: """
        eureka [选项]
          （无参数）                 启动菜单栏应用
          --install-claude-hooks    安装 Claude Code hooks（写前备份）
          --uninstall-claude-hooks  卸载 Claude Code hooks
          --install-codex-notify    安装 Codex notify（写前备份）
          --uninstall-codex-notify  卸载 Codex notify
          --hooks-status            查看安装状态
          --audit-snapshot          扫描并输出 agent 操作审计流水（--risk-only 仅风险 / --limit N）
          --parquet-inspect <文件…>  解码 Parquet 归档文件，打印每个文件的行数与列（只读）
          --pricing-resolve [模型…]  打印价格解析结果与出处（--provider p；不给模型则解析本地账本全部模型）
          --build-pricing-catalog <litellm> <models.dev> <输出>  生成随包价格目录快照
          --pricing-refresh         用 app 同一套网络代码拉一次价格目录（只打印结果，不写缓存）
          --mcp-inspect <名字>       检测某个 MCP server（remote 握手 / stdio 深探），结果落缓存
          --render-previews [目录]   离屏渲染灵动岛各形态 PNG
          --render-mascot [目录]     离屏渲染全部吉祥物变体与分镜 PNG
          --pack-mascot-v3 <目录> <文件>  将 12 张 2×2 分镜打包为 v3 图集
          --render-shell [目录]      离屏渲染侧栏（含品牌区）与审计页，明/暗两版
          --render-lineage [目录]    离屏渲染轮次血缘图（golden 基准 + 真实数据）
        """))
    }

    /// --mcp-inspect：走 MCPService 的真实探测路径（与 UI「重新检测」同一条代码路径、
    /// 同一份缓存），供无头验证与调试。
    @MainActor
    private static func mcpInspect(name: String) {
        guard !name.isEmpty else {
            print(L10n.text("Usage: eureka --mcp-inspect <server-name>", zhHans: "用法：eureka --mcp-inspect <server名>"))
            return
        }
        let service = MCPService()
        service.refresh()
        var deadline = Date().addingTimeInterval(30)
        while service.scanning, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        let entries = service.entries(named: name)
        guard !entries.isEmpty else {
            let known = Set(service.allEntries().map(\.name)).sorted()
            print(L10n.format("Server “%@” not found. Known servers: %@", zhHans: "未找到 server「%@」。已知：%@", String(name), String(known.joined(separator: ", "))))
            return
        }
        print(L10n.format("Inspecting “%@” across %@ configurations…", zhHans: "检测「%@」的 %@ 处配置…", String(name), String(entries.count)))
        service.probe(entries)
        deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            let allDone = entries.allSatisfy { entry in
                if case .done = service.probeResults[entry.id] { return true }
                return false
            }
            if allDone { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))  // 等 toolCache 回主线程
        for entry in entries {
            guard let snapshot = service.probeSnapshots[entry.id] else {
                print(L10n.format("[%@] Timed out without a result", zhHans: "[%@] 超时未出结果", String(entry.source.displayName)))
                continue
            }
            var line = "[\(entry.source.displayName)] \(snapshot.label)"
            if let detail = snapshot.detail { line += " · \(detail)" }
            if let scheme = snapshot.authScheme { line += L10n.format(" · Authentication=%@", zhHans: " · 鉴权=%@", String(scheme)) }
            print(line)
            if let hint = snapshot.hint { print("  ↳ \(hint)") }
        }
        guard let cache = MCPToolCache.load()[name.lowercased()] else { return }
        print(L10n.format("%@ tools · ~%@ tokens per turn · Protocol %@", zhHans: "工具 %@ 个 · 每轮 ~%@ tokens · 协议 %@", String(cache.toolCount), String(cache.schemaTokens), String(cache.protocolVersion ?? "-")))
        for tool in cache.tools ?? [] {
            let params = (tool.params?.isEmpty == false)
                ? "(\(tool.params!.joined(separator: ", ")))" : ""
            print("  - \(tool.name)\(params)  \(tool.description ?? "")")
        }
        if let prompts = cache.prompts, !prompts.isEmpty {
            print(L10n.format("Prompts %@: %@", zhHans: "提示词 %@：%@", String(prompts.count), String(prompts.map(\.name).joined(separator: ", "))))
        }
        if let resources = cache.resources, !resources.isEmpty {
            print(L10n.format("Resources %@: %@", zhHans: "资源 %@：%@", String(resources.count), String(resources.map(\.name).joined(separator: ", "))))
        }
    }
}
