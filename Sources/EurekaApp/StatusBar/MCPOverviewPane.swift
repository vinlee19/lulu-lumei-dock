import Charts
import EurekaIngest
import EurekaKit
import SwiftUI

/// The MCP module overview: what the right pane shows before a server is picked. Same four
/// blocks as the Skills overview (numbers, one trend, what needs attention, a ranking that
/// opens the item), plus the one number only MCP has: the tool definitions every enabled
/// server injects into each turn's context, whether or not it is called.
struct MCPOverviewPane: View {
    @ObservedObject var service: MCPService
    @ObservedObject var usageService: UsageService
    /// Opens a server's detail (by name).
    let onOpen: (String) -> Void

    private var hard: Bool { ThemeStyle.current.isHardEdged }

    // MARK: - Derived numbers

    /// Config locations grouped by server name (lowercased), in list order.
    private var byName: [(key: String, entries: [MCPServerEntry])] {
        var order: [String] = []
        var groups: [String: [MCPServerEntry]] = [:]
        for entry in service.servers {
            let key = entry.name.lowercased()
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(entry)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    private var enabledKeys: [String] {
        byName.filter { $0.entries.contains { $0.enabled != false } }.map(\.key)
    }

    private func calls30(_ key: String) -> Int { usageService.mcpOverview?.serverCalls[key] ?? 0 }

    private var usedCount: Int { byName.filter { calls30($0.key) > 0 }.count }

    /// Tokens of tool schemas the enabled servers inject per turn (probed servers only).
    private var schemaTokens: Int {
        enabledKeys.reduce(0) { $0 + (service.toolCache[$1]?.schemaTokens ?? 0) }
    }

    private var probedEnabledCount: Int { enabledKeys.filter { service.toolCache[$0] != nil }.count }

    private var totalCalls30d: Int { usageService.mcpOverview?.series.reduce(0) { $0 + $1.count } ?? 0 }

    private func displayName(_ key: String) -> String {
        byName.first { $0.key == key }?.entries.first?.name ?? key
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                numbers
                trendSection
                attentionSection
                topSection
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { usageService.loadMCPOverview() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.text("MCP overview", zhHans: "MCP 概览"))
                .font(Theme.font.themed(17, .semibold))
            Text(L10n.format("%@ servers in %@ config locations · %@ calls in the last 30 days",
                             zhHans: "%@ 个 server，%@ 处配置 · 近 30 天调用 %@ 次",
                             String(byName.count), String(service.servers.count), String(totalCalls30d)))
                .font(Theme.font.themed(11.5))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Numbers

    private var numbers: some View {
        HStack(spacing: 10) {
            numberTile(String(byName.count), L10n.text("Servers", zhHans: "Server"))
            numberTile(String(enabledKeys.count), L10n.text("Enabled", zhHans: "已启用"))
            numberTile(String(usedCount), L10n.text("Used in 30 days", zhHans: "30 天内用过"))
            numberTile(
                schemaTokens > 0 ? formatTokens(schemaTokens) : "—",
                probedEnabledCount < enabledKeys.count && schemaTokens > 0
                    ? L10n.format("Tokens per turn (%@ of %@ probed)", zhHans: "每轮占用 token（已检测 %@/%@）",
                                  String(probedEnabledCount), String(enabledKeys.count))
                    : L10n.text("Tokens per turn", zhHans: "每轮占用 token"))
        }
    }

    private func numberTile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.font.statNumber(20))
            Text(label).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.surfaceSecondary))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: hard ? Theme.cardBorderWidth : 0.5))
    }

    // MARK: - Trend

    private var trendSection: some View {
        section(L10n.text("Calls in the last 30 days", zhHans: "近 30 天调用")) {
            if totalCalls30d == 0 {
                Text(L10n.text("No MCP calls recorded in the last 30 days.", zhHans: "近 30 天没有 MCP 调用记录。"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Chart(usageService.mcpOverview?.series ?? []) { point in
                    BarMark(
                        x: .value(L10n.text("Date", zhHans: "日期"), point.day, unit: .day),
                        y: .value(L10n.text("Calls", zhHans: "次数"), point.count))
                        .foregroundStyle(Theme.brand)
                        .cornerRadius(hard ? 0 : 2)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
                .frame(height: 96)
                HStack {
                    Text(L10n.text("30 days ago", zhHans: "30 天前"))
                    Spacer()
                    Text(L10n.text("calls per day, all servers", zhHans: "所有 server 每天的调用次数"))
                    Spacer()
                    Text(L10n.text("today", zhHans: "今天"))
                }
                .font(Theme.font.themedMono(9.5))
                .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: - Needs attention

    private var failing: [MCPServerEntry] {
        service.servers.filter { service.probeSnapshots[$0.id]?.tone == "bad" }
    }

    /// Enabled servers nobody called in 30 days, heaviest schema first.
    private var idle: [String] {
        enabledKeys
            .filter { calls30($0) == 0 }
            .sorted { (service.toolCache[$0]?.schemaTokens ?? 0) > (service.toolCache[$1]?.schemaTokens ?? 0) }
    }

    /// One config location per server that has never been probed (enough to learn its tools).
    private var unprobed: [MCPServerEntry] {
        byName.filter { service.toolCache[$0.key] == nil }.compactMap(\.entries.first)
    }

    private var attentionSection: some View {
        let failing = failing
        let idle = idle
        let unprobed = unprobed
        let idleTokens = idle.reduce(0) { $0 + (service.toolCache[$1]?.schemaTokens ?? 0) }
        return section(L10n.text("Needs attention", zhHans: "需要处理")) {
            if failing.isEmpty && idle.isEmpty && unprobed.isEmpty {
                HStack(spacing: 7) {
                    Circle().fill(Theme.enabledGreen).frame(width: 8, height: 8)
                    Text(L10n.text("Nothing waiting: every server connects and every enabled one is in use.",
                                   zhHans: "没有待处理的事：所有 server 都能连上，启用的也都在用。"))
                        .font(Theme.font.themed(12))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            if !failing.isEmpty {
                attentionRow(
                    icon: "exclamationmark.triangle.fill",
                    title: L10n.format("%@ config locations failed their last connection check",
                                       zhHans: "%@ 处配置上次检测连不上", String(failing.count)),
                    detail: Set(failing.map(\.name)).sorted().prefix(4).joined(separator: ", "),
                    button: L10n.text("Check again", zhHans: "重新检测"),
                    action: { service.probe(failing) })
            }
            if !idle.isEmpty {
                attentionRow(
                    icon: "moon.zzz",
                    title: idleTokens > 0
                        ? L10n.format("%@ enabled servers unused for 30 days still cost %@ tokens per turn",
                                      zhHans: "%@ 个启用的 server 30 天没被调用，每轮仍占约 %@ token",
                                      String(idle.count), formatTokens(idleTokens))
                        : L10n.format("%@ enabled servers have not been called in 30 days",
                                      zhHans: "%@ 个启用的 server 30 天没被调用", String(idle.count)),
                    detail: L10n.text("Disabling one you don't need frees that context on every turn.",
                                      zhHans: "停用用不上的 server，每轮都能省下这部分上下文。"),
                    button: nil, action: nil)
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(idle.prefix(10), id: \.self) { key in
                        Button { onOpen(displayName(key)) } label: {
                            HStack(spacing: 5) {
                                Text(displayName(key)).font(Theme.font.themed(11))
                                if let tokens = service.toolCache[key]?.schemaTokens, tokens > 0 {
                                    Text(formatTokens(tokens))
                                        .font(Theme.font.themedMono(10))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                            }
                            .foregroundStyle(.primary)
                            .modifier(PopupButtonChrome(height: 24, horizontalPadding: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !unprobed.isEmpty {
                attentionRow(
                    icon: "questionmark.circle",
                    title: L10n.format("%@ servers were never checked, so their tools are unknown",
                                       zhHans: "%@ 个 server 从没检测过，不知道带了哪些工具",
                                       String(unprobed.count)),
                    detail: L10n.text("Checking starts a stdio server briefly and exits after listing its tools.",
                                      zhHans: "检测会短暂启动 stdio server，列完工具就退出。"),
                    button: service.probeProgress == nil
                        ? L10n.text("Check them", zhHans: "检测这些")
                        : L10n.text("Checking…", zhHans: "检测中…"),
                    action: { service.probe(unprobed) })
            }
        }
    }

    private func attentionRow(icon: String, title: String, detail: String, button: String?,
                              action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(Theme.font.themed(12))
                .foregroundStyle(Theme.goldFg)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font.themed(12.5, .medium))
                Text(detail).font(Theme.font.themed(11)).foregroundStyle(Theme.textTertiary).lineLimit(2)
            }
            Spacer(minLength: 8)
            if let button, let action {
                PaneButton(button, small: true, action: action)
                    .disabled(service.probeProgress != nil)
            }
        }
        .padding(.vertical, 6)
    }

    // MARK: - Top 10

    private var topSection: some View {
        let ranked = (usageService.mcpOverview?.serverCalls ?? [:])
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(10)
        let peak = max(1, ranked.first?.value ?? 1)
        let configured = Set(byName.map(\.key))
        return section(L10n.text("Most used in 30 days", zhHans: "近 30 天最常用")) {
            if ranked.isEmpty {
                Text(L10n.text("No calls yet.", zhHans: "还没有调用记录。"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(Array(ranked.enumerated()), id: \.element.key) { index, pair in
                let installed = configured.contains(pair.key)
                let tools = usageService.mcpOverview?.topTools[pair.key]?.map(\.name) ?? []
                Button {
                    if installed { onOpen(displayName(pair.key)) }
                } label: {
                    HStack(spacing: 10) {
                        Text(String(index + 1))
                            .font(Theme.font.themedMono(11))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(width: 18, alignment: .trailing)
                        MCPIconTile(size: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(installed ? displayName(pair.key) : pair.key)
                                .font(Theme.font.themed(12.5, .medium))
                                .lineLimit(1)
                            if !tools.isEmpty {
                                Text(tools.joined(separator: ", "))
                                    .font(Theme.font.themed(10.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                        .frame(width: 210, alignment: .leading)
                        Capsule().fill(Theme.surfaceTertiary)
                            .frame(height: 6)
                            .overlay(alignment: .leading) {
                                GeometryReader { geo in
                                    Capsule().fill(Theme.brand)
                                        .frame(width: max(4, geo.size.width * CGFloat(pair.value) / CGFloat(peak)))
                                }
                            }
                        Text(L10n.format("%@ times", zhHans: "%@ 次", String(pair.value)))
                            .font(Theme.font.themedMono(11.5))
                            .frame(width: 64, alignment: .trailing)
                    }
                    .foregroundStyle(installed ? .primary : Theme.textTertiary)
                    .frame(height: 36)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(installed
                    ? L10n.text("Open this server", zhHans: "打开这个 server")
                    : L10n.text("Called, but no longer in any scanned config", zhHans: "有调用记录，但现在的配置里已经没有它"))
            }
            if ranked.contains(where: { !configured.contains($0.key) }) {
                Text(L10n.text("Grey rows were called but are not in any config file on this Mac: they come from plugins or claude.ai connectors, or were removed.",
                               zhHans: "灰色的有调用记录，但不在本机的配置文件里：来自插件或 claude.ai 连接器，或者已经删掉了。"))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 2)
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            Text(title).font(Theme.font.themed(12.5, .semibold)).padding(.top, 4)
            content()
        }
    }
}

// MARK: - Split-list row

/// One server in the MCP split list, folded across every config location of that name: the
/// same shape as a skill row (logo tile, name, one meta line, a switch or "n/m").
struct MCPServerListRow: View {
    let entries: [MCPServerEntry]
    @ObservedObject var service: MCPService
    let calls30: Int
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var hovering = false
    private var hard: Bool { ThemeStyle.current.isHardEdged }
    private var primary: MCPServerEntry { entries[0] }
    private var sources: [AgentSource] {
        var seen = Set<AgentSource>()
        return entries.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
    }
    private var enabledCount: Int { entries.filter { $0.enabled != false }.count }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                tile
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if let snapshot = service.probeSnapshots[primary.id] {
                            Circle().fill(mcpToneColor(snapshot.tone)).frame(width: 6, height: 6)
                        }
                        Text(primary.name)
                            .font(Theme.font.themed(12.5, .medium))
                            .foregroundStyle(isSelected && hard ? Theme.onBrand : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TagChip(primary.transport, neutral: true)
                    }
                    Text(meta)
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(isSelected && hard ? Theme.onBrand.opacity(0.75) : Theme.textSecondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing
            }
            .opacity(enabledCount == 0 ? 0.55 : 1)
            .padding(.horizontal, 8)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(isSelected ? (hard ? Theme.brand : Theme.brandFill(0.14))
                        : (hovering ? Color.primary.opacity(0.04) : .clear)))
            .overlay(
                Group {
                    if isSelected, let outline = Theme.controlOutline {
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(outline.color, lineWidth: outline.width)
                    }
                })
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var tile: some View {
        ZStack(alignment: .bottomTrailing) {
            SourceLogoTile(source: primary.source, size: 28)
            if sources.count > 1 {
                SourceBadge(source: sources[1], size: 11)
                    .padding(2)
                    .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: hard ? 1.5 : 0.5))
                    .offset(x: 5, y: 5)
            }
        }
        .frame(width: 28, height: 28)
    }

    @ViewBuilder
    private var trailing: some View {
        if entries.count == 1, MCPService.supportsEnableToggle(primary.source) {
            MiniSwitch(isOn: primary.enabled ?? true) {
                service.setEnabled(primary, !(primary.enabled ?? true))
            }
        } else if entries.count > 1 {
            Text("\(enabledCount)/\(entries.count)")
                .font(Theme.font.themedMono(11))
                .foregroundStyle(isSelected && hard ? Theme.onBrand.opacity(0.75) : Theme.textSecondary)
        }
    }

    private var meta: String {
        var parts: [String] = []
        let first = primary.source.displayName
        if sources.count > 1 {
            parts.append(L10n.format("%1$@ + %2$@ more tools", zhHans: "%1$@ 等 %3$@ 个工具",
                                     first, String(sources.count - 1), String(sources.count)))
        } else {
            parts.append(first)
        }
        if let tools = service.toolCache[primary.name.lowercased()] {
            // "Tools" already names the agent CLIs in this line; say MCP tools explicitly.
            parts.append(L10n.format("%@ MCP tools", zhHans: "%@ 个 MCP 工具", String(tools.toolCount)))
        }
        parts.append(calls30 > 0
            ? L10n.format("%@ calls in 30 days", zhHans: "30 天 %@ 次", String(calls30))
            : L10n.text("unused in 30 days", zhHans: "30 天没用过"))
        return parts.joined(separator: " · ")
    }
}
