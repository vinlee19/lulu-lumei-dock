import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import EurekaUsage
import SwiftUI

/// Settings → Advanced: a group of collapsible cards (modeled on the reference design:
/// icon + title + description + chevron)
/// Integration status / config file directories / data management / data health
struct AdvancedSettingsView: View {
    @ObservedObject var installer: InstallerService
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: AppSettings

    @State private var confirmingClearIndex = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            CollapsibleCard(
                icon: "folder.badge.gearshape", tint: Theme.brand,
                title: L10n.text("Config directories", zhHans: "配置文件目录"),
                subtitle: L10n.text("Where Claude, Codex, OpenCode, and lulu-lumei-dock store their data", zhHans: "Claude、Codex、OpenCode 与 lulu-lumei-dock 的数据存储路径")
            ) {
                pathsContent
            }
            CollapsibleCard(
                icon: "externaldrive", tint: Theme.brand,
                title: L10n.text("Data", zhHans: "数据管理"),
                subtitle: L10n.text("Export a usage CSV and locate the local database", zhHans: "导出用量 CSV、查看本地数据库")
            ) {
                dataContent
            }
            CollapsibleCard(
                icon: "dollarsign.circle", tint: Theme.brand,
                title: L10n.text("Model prices", zhHans: "模型价格"),
                subtitle: L10n.text("Price source, online updates, and unpriced models", zhHans: "价格来源、联网更新与未定价模型")
            ) {
                PricingSection(usageService: usageService, settings: settings)
            }
            CollapsibleCard(
                icon: "waveform.path.ecg", tint: Theme.brand,
                title: L10n.text("Data health", zhHans: "数据健康"),
                subtitle: L10n.text("Heartbeats, output, and failures for each data source", zhHans: "各数据源心跳 / 产出 / 失败一览")
            ) {
                HealthSection()
            }
        }
        .onAppear { installer.refresh() }
    }

    // MARK: - Config file directories

    @ViewBuilder
    private var pathsContent: some View {
        let home = FileManager.default.homeDirectoryForCurrentUser
        pathRow("Claude", home.appendingPathComponent(".claude"))
        pathRow("Codex", home.appendingPathComponent(".codex"))
        pathRow("OpenCode", home.appendingPathComponent(".config/opencode"))
        pathRow("Gemini", home.appendingPathComponent(".gemini"))
        pathRow("Qwen", home.appendingPathComponent(".qwen"))
        pathRow("Hermes", home.appendingPathComponent(".hermes"))
        pathRow("CodeBuddy", home.appendingPathComponent(".codebuddy"))
        pathRow("Qoder", home.appendingPathComponent(".qoder-cn"))
        pathRow("Cursor", home.appendingPathComponent(".cursor"))
        // Trae is two independent apps: the CN and international editions each have their own
        // directories and share no data
        pathRow("Trae", home.appendingPathComponent(".trae-cn"))
        pathRow(L10n.text("Trae (international)", zhHans: "Trae（国际版）"), home.appendingPathComponent(".trae"))
        pathRow(L10n.text("lulu-lumei-dock data", zhHans: "lulu-lumei-dock 数据"), SpoolPaths.root())
    }

    private func pathRow(_ name: String, _ url: URL) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11))
                .frame(width: 76, alignment: .leading)
            Text(url.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                .font(.system(size: 10).monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"))
        }
    }

    // MARK: - Data management

    @ViewBuilder
    private var dataContent: some View {
        HStack {
            Button(L10n.text("Export the last 30 days of usage as CSV", zhHans: "导出近 30 天用量 CSV")) { usageService.exportCSV() }
                .controlSize(.small)
            if let message = usageService.exportMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        HStack {
            Button(L10n.text("Show Database File", zhHans: "显示数据库文件")) {
                NSWorkspace.shared.activateFileViewerSelecting([EurekaStore.defaultURL()])
            }
            .controlSize(.small)
            Text(L10n.text("You can query eureka.sqlite directly with sqlite3", zhHans: "可直接 sqlite3 查询 eureka.sqlite"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        Text(L10n.text("Stable relay path: ~/Library/Application Support/Eureka/bin/lululumei-relay (the app re-syncs it on upgrade so hooks keep working; the old name eureka-relay remains a symlink)", zhHans: "relay 稳定路径：~/Library/Application Support/Eureka/bin/lululumei-relay（升级 app 自动重同步，hooks 不断链；旧名 eureka-relay 保留为软链）"))
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        Divider()
        Toggle(L10n.text("Cross-session full-text index", zhHans: "跨会话全文搜索索引"), isOn: $settings.fullTextSearchEnabled)
        Text(L10n.text(
            "Indexes Claude / Codex / Grok / Kimi / CodeBuddy / Qoder conversations locally so search on the Sessions page can jump to a message. The index updates incrementally with usage scans and never leaves this Mac. Turning it off freezes the index. Sources that share one database (OpenCode / Hermes / Cursor) and Antigravity are excluded: the index is keyed by transcript path, and those sources keep every session in a single .db.",
            zhHans: "在本地为 Claude / Codex / Grok / Kimi / CodeBuddy / Qoder 的对话内容建索引，会话页搜索时可直达消息；索引随用量扫描增量更新，全程本地。关闭后索引冻结不再更新。共享单库的来源（OpenCode / Hermes / Cursor）与 Antigravity 不入索引：索引以转录文件路径为主键，而它们所有会话共用同一个 .db。"))
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        // Destructive and slow to rebuild (a full rescan of every transcript): confirm first,
        // same as the audit page's Clear.
        Button(L10n.text("Clear Full-Text Index", zhHans: "清空全文索引")) { confirmingClearIndex = true }
            .controlSize(.small)
            .confirmationDialog(
                L10n.text("Clear the cross-session full-text index? The next scan rebuilds it, which can take a few minutes when there are many sessions.", zhHans: "确认清空跨会话全文索引？下次扫描会重新建索引，大量会话时需要几分钟。"),
                isPresented: $confirmingClearIndex, titleVisibility: .visible
            ) {
                Button(L10n.text("Clear", zhHans: "清空"), role: .destructive) { usageService.clearSearchIndex() }
                Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
            }
    }
}

// MARK: - Model pricing

/// Price catalog status + network toggle + list of unpriced/estimated models (one-click copy of
/// an override template)
private struct PricingSection: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject private var pricing = PricingCatalogService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(L10n.text("Update model prices online (LiteLLM / models.dev)", zhHans: "联网更新模型价格（LiteLLM / models.dev）"), isOn: $settings.remotePricingEnabled)
            Text(L10n.text(
                "A public price list is fetched once a day and no user data is sent. If the fetch fails, the local cache or the bundled snapshot is kept. Subscription plans (Kimi Code, Zhipu / Volcengine Coding Plan, and similar) are priced at the vendor's pay-as-you-go rate as an API-equivalent cost. Models that only have a reseller quote are not priced.",
                zhHans: "每天拉取一次公开价格表，不发送任何用户数据；失败时继续用本地缓存或随包快照。订阅套餐（Kimi Code、智谱 / 火山 Coding Plan 等）按厂商按量价折算 API 等价费用；只有转售平台报价的模型不计价。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            statusLine
            HStack(spacing: 8) {
                Button(pricing.status.refreshing ? L10n.text("Updating…", zhHans: "更新中…") : L10n.text("Update Now", zhHans: "立即更新")) { pricing.refreshNow() }
                    .disabled(pricing.status.refreshing)
                Button(L10n.text("Open the pricing.json Folder", zhHans: "打开 pricing.json 所在目录")) {
                    NSWorkspace.shared.open(SpoolPaths.root())
                }
                Button(L10n.text("Reload Custom Prices", zhHans: "重新载入自定义价格")) { pricing.reloadOverride() }
            }
            .controlSize(.small)
            Divider()
            unpricedList
        }
        .onAppear { usageService.loadPricingDiagnostics() }
        .onChange(of: usageService.pricingRevision) { _, _ in usageService.loadPricingDiagnostics() }
    }

    private var statusLine: some View {
        let status = pricing.status
        let formatter = RelativeDateTimeFormatter()
        func age(_ date: Date?) -> String {
            date.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? L10n.text("None", zhHans: "无")
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(L10n.format(
                "Source: %@ · LiteLLM %@ entries (%@) · models.dev %@ entries (%@)",
                zhHans: "当前来源：%@ · LiteLLM %@ 条（%@） · models.dev %@ 条（%@）",
                status.origin.rawValue,
                String(status.litellmCount),
                age(status.litellmFetchedAt),
                String(status.modelsDevCount),
                age(status.modelsDevFetchedAt)))
            if let error = status.lastError {
                Text(error).foregroundStyle(.red)
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var unpricedList: some View {
        let rows = usageService.pricingDiagnostics
        if rows.isEmpty {
            Text(L10n.text("Every model has a price", zhHans: "所有模型都已定价")).font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            HStack {
                Text(L10n.format("Unpriced / estimated (%@)", zhHans: "未定价 / 估算（%@）", String(rows.count))).font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Button(L10n.text("Copy Override Template", zhHans: "复制覆盖模板")) { copyTemplate(rows) }.controlSize(.small)
            }
            ForEach(rows.prefix(30)) { row in
                HStack(spacing: 6) {
                    Text(row.source.displayName).frame(width: 64, alignment: .leading)
                    Text(row.provider.map { "\(row.model) @\($0)" } ?? row.model)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(row.resolution.estimated ? row.resolution.summary : L10n.text("Unpriced", zhHans: "未定价"))
                        .foregroundStyle(.secondary)
                    Text(formatTokens(row.tokens)).monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 10))
            }
            Text(L10n.text(
                "Fill in the prices (USD per million tokens) and save the template as ~/Library/Application Support/Eureka/pricing.json, then click Reload Custom Prices. Custom prices win.",
                zhHans: "把模板里的价格（USD / 百万 token）填好后保存为 ~/Library/Application Support/Eureka/pricing.json，再点「重新载入自定义价格」。自定义价格优先级最高。"))
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
    }

    private func copyTemplate(_ rows: [UsageService.PricingDiagnostic]) {
        var seen = Set<String>()
        let models: [[String: Any]] = rows.compactMap { row in
            guard seen.insert(row.model).inserted else { return nil }
            return ["match": row.model, "inputPerM": 0, "outputPerM": 0]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: ["models": models], options: [.prettyPrinted, .sortedKeys])
        else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
    }
}

// MARK: - Data health (moved here from SettingsView)

/// Heartbeat / output / failure overview for each data source (refreshed every 5 seconds).
/// A stalled polling source (dead timer) goes straight to red, so nobody has to "sense something
/// is off" anymore.
private struct HealthSection: View {
    @State private var rows: [(name: String, entry: HealthRegistry.Entry)] = []
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text(L10n.text("Data sources have not started", zhHans: "数据源尚未启动"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.healthColor(row.entry.status()))
                        .frame(width: 7, height: 7)
                    Text(L10n.healthTitle(row.name))
                        .font(.system(size: 10.5))
                    Spacer()
                    Text(detail(for: row.entry))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if row.entry.failureCount > 0, let note = row.entry.lastFailureNote {
                    Text(L10n.format(
                        "Failed %@ times · latest: %@",
                        zhHans: "失败 %@ 次 · 最近：%@",
                        String(row.entry.failureCount), note))
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .padding(.leading, 13)
                }
            }
        }
        .onAppear { rows = HealthRegistry.shared.snapshot() }
        .onReceive(timer) { _ in rows = HealthRegistry.shared.snapshot() }
    }

    private func detail(for entry: HealthRegistry.Entry) -> String {
        var parts: [String] = []
        if let beat = entry.lastBeatAt {
            parts.append(L10n.format("Heartbeat %@", zhHans: "心跳 %@", ago(beat)))
        }
        if let event = entry.lastEventAt {
            parts.append(L10n.format("Output %@", zhHans: "产出 %@", ago(event)))
        }
        if entry.status() == .stalled {
            parts.append(L10n.text("Stalled", zhHans: "已停摆"))
        }
        return parts.isEmpty ? L10n.text("Waiting", zhHans: "等待中") : parts.joined(separator: " · ")
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<5: return L10n.text("Just now", zhHans: "刚刚")
        case ..<60: return L10n.format("%@s ago", zhHans: "%@秒前", String(seconds))
        case ..<3600: return L10n.format("%@m ago", zhHans: "%@分钟前", String(seconds / 60))
        default: return L10n.format("%@h ago", zhHans: "%@小时前", String(seconds / 3600))
        }
    }
}

// MARK: - Collapsible card component

/// Collapsible card for the Advanced page: icon + title + description + chevron; tap to expand
/// the content (collapsed by default)
struct CollapsibleCard<Content: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 7).fill(tint.opacity(0.1)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                Divider()
                    .padding(.horizontal, 11)
                VStack(alignment: .leading, spacing: 7) {
                    content()
                }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.radius.card).fill(Theme.surface))
    }
}
