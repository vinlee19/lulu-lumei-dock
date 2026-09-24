import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import EurekaUsage
import SwiftUI

/// 设置→高级：折叠卡片组（仿参考设计：图标+标题+描述+chevron）
/// 接入状态 / 配置文件目录 / 数据管理 / 数据健康
struct AdvancedSettingsView: View {
    @ObservedObject var installer: InstallerService
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacing.module) {
            CollapsibleCard(
                icon: "folder.badge.gearshape", tint: Theme.brand,
                title: "配置文件目录",
                subtitle: "Claude、Codex、OpenCode 与 lulu-lumei-dock 的数据存储路径"
            ) {
                pathsContent
            }
            CollapsibleCard(
                icon: "externaldrive", tint: Theme.brand,
                title: "数据管理",
                subtitle: "导出用量 CSV、查看本地数据库"
            ) {
                dataContent
            }
            CollapsibleCard(
                icon: "dollarsign.circle", tint: Theme.brand,
                title: "模型价格",
                subtitle: "价格来源、联网更新与未定价模型"
            ) {
                PricingSection(usageService: usageService, settings: settings)
            }
            CollapsibleCard(
                icon: "waveform.path.ecg", tint: Theme.brand,
                title: "数据健康",
                subtitle: "各数据源心跳 / 产出 / 失败一览"
            ) {
                HealthSection()
            }
        }
        .onAppear { installer.refresh() }
    }

    // MARK: - 配置文件目录

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
        // Trae 是两个独立应用：CN 版与国际版各自一套目录，数据不互通
        pathRow("Trae", home.appendingPathComponent(".trae-cn"))
        pathRow("Trae（国际版）", home.appendingPathComponent(".trae"))
        pathRow("lulu-lumei-dock 数据", SpoolPaths.root())
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
            .help("在 Finder 中显示")
        }
    }

    // MARK: - 数据管理

    @ViewBuilder
    private var dataContent: some View {
        HStack {
            Button("导出近 30 天用量 CSV") { usageService.exportCSV() }
                .controlSize(.small)
            if let message = usageService.exportMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        HStack {
            Button("显示数据库文件") {
                NSWorkspace.shared.activateFileViewerSelecting([EurekaStore.defaultURL()])
            }
            .controlSize(.small)
            Text("可直接 sqlite3 查询 eureka.sqlite")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
        }
        Text("relay 稳定路径：~/Library/Application Support/Eureka/bin/eureka-relay（升级 app 自动重同步，hooks 不断链）")
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        Divider()
        Toggle("跨会话全文搜索索引", isOn: $settings.fullTextSearchEnabled)
        Text("在本地为 Claude / Codex / Grok / Kimi / CodeBuddy / Qoder 的对话内容建索引，会话页搜索时可直达消息；"
            + "索引随用量扫描增量更新，全程本地。关闭后索引冻结不再更新。"
            + "共享单库的来源（OpenCode / Hermes / Cursor）与 Antigravity 不入索引：索引以转录文件路径为主键，"
            + "而它们所有会话共用同一个 .db。")
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)
        Button("清空全文索引") { usageService.clearSearchIndex() }
            .controlSize(.small)
    }
}

// MARK: - 模型价格

/// 价格目录状态 + 联网开关 + 未定价/估算模型清单（一键复制覆盖模板）
private struct PricingSection: View {
    @ObservedObject var usageService: UsageService
    @ObservedObject var settings: AppSettings
    @ObservedObject private var pricing = PricingCatalogService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("联网更新模型价格（LiteLLM / models.dev）", isOn: $settings.remotePricingEnabled)
            Text("每天拉取一次公开价格表，不发送任何用户数据；失败时继续用本地缓存或随包快照。"
                + "订阅套餐（Kimi Code、智谱 / 火山 Coding Plan 等）按厂商按量价折算 API 等价费用；"
                + "只有转售平台报价的模型不计价。")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            statusLine
            HStack(spacing: 8) {
                Button(pricing.status.refreshing ? "更新中…" : "立即更新") { pricing.refreshNow() }
                    .disabled(pricing.status.refreshing)
                Button("打开 pricing.json 所在目录") {
                    NSWorkspace.shared.open(SpoolPaths.root())
                }
                Button("重新载入自定义价格") { pricing.reloadOverride() }
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
            date.map { formatter.localizedString(for: $0, relativeTo: Date()) } ?? "无"
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text("当前来源：\(status.origin.rawValue) · LiteLLM \(status.litellmCount) 条（\(age(status.litellmFetchedAt))）"
                + " · models.dev \(status.modelsDevCount) 条（\(age(status.modelsDevFetchedAt))）")
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
            Text("所有模型都已定价").font(.system(size: 10)).foregroundStyle(.secondary)
        } else {
            HStack {
                Text("未定价 / 估算（\(rows.count)）").font(.system(size: 10.5, weight: .semibold))
                Spacer()
                Button("复制覆盖模板") { copyTemplate(rows) }.controlSize(.small)
            }
            ForEach(rows.prefix(30)) { row in
                HStack(spacing: 6) {
                    Text(row.source.displayName).frame(width: 64, alignment: .leading)
                    Text(row.provider.map { "\(row.model) @\($0)" } ?? row.model)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(row.resolution.estimated ? row.resolution.summary : "未定价")
                        .foregroundStyle(.secondary)
                    Text(formatTokens(row.tokens)).monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
                .font(.system(size: 10))
            }
            Text("把模板里的价格（USD / 百万 token）填好后保存为 ~/Library/Application Support/Eureka/pricing.json，"
                + "再点「重新载入自定义价格」。自定义价格优先级最高。")
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

// MARK: - 数据健康（自 SettingsView 迁入）

/// 各数据源的心跳/产出/失败一览（每 5 秒刷新）。
/// 轮询型数据源停摆（定时器死掉）会直接红灯，不用再"感觉不对"。
private struct HealthSection: View {
    @State private var rows: [(name: String, entry: HealthRegistry.Entry)] = []
    private let timer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if rows.isEmpty {
                Text("数据源尚未启动")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.name) { row in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.healthColor(row.entry.status()))
                        .frame(width: 7, height: 7)
                    Text(row.name)
                        .font(.system(size: 10.5))
                    Spacer()
                    Text(detail(for: row.entry))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if row.entry.failureCount > 0, let note = row.entry.lastFailureNote {
                    Text("失败 \(row.entry.failureCount) 次 · 最近：\(note)")
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
            parts.append("心跳 \(ago(beat))")
        }
        if let event = entry.lastEventAt {
            parts.append("产出 \(ago(event))")
        }
        if entry.status() == .stalled {
            parts.append("已停摆")
        }
        return parts.isEmpty ? "等待中" : parts.joined(separator: " · ")
    }

    private func ago(_ date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        switch seconds {
        case ..<5: return "刚刚"
        case ..<60: return "\(seconds)秒前"
        case ..<3600: return "\(seconds / 60)分钟前"
        default: return "\(seconds / 3600)小时前"
        }
    }
}

// MARK: - 折叠卡片组件

/// 高级页折叠卡：图标 + 标题 + 描述 + chevron，点击展开内容（默认收起）
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
