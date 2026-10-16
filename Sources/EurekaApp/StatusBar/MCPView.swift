import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// MCP 页签：跨源 server 管理（查看 / 新建 / 跨 agent 安装 / 删除）。
///
/// 结构与其它知识页签逐条对齐：header（搜索+＋菜单+扫描状态+刷新+布局切换）→
/// `StatOverviewCard` → `SourceFilterBar` → `KnowledgeRow`/`KnowledgeCard` → 滑入详情/表单。
/// 一行 = 一处配置（与 Skills 同构：同名 server 配置在 2 个源就是 2 行），
/// 详情页按名聚合并给出跨源安装矩阵。
/// 密钥红线：列表/详情只显示 env/headers 的**键名**；完整值只在安装/传播时于
/// 两个本地配置文件间内存中转（见 MCPService / MCPServerEditor 头注释）。
struct MCPView: View {
    @ObservedObject var service: MCPService
    /// MCP 调用统计（kind='mcp' 的 tool_calls 按 server 聚合；闲置检测用）
    @ObservedObject var usageService: UsageService

    /// 滑入详情（按 server 名聚合）
    @State private var detailName: String?
    /// 滑入表单（新建 / 粘贴 JSON 导入）
    @State private var formTarget: MCPFormTarget?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// 列表 / 图标网格
    @State private var layout: KnowledgeLayout = .list
    /// 待确认删除的配置处
    @State private var deletingEntry: MCPServerEntry?

    /// 离屏渲染/预览专用：指定初始布局/初始详情/初始表单（交互时由用户操作驱动）
    init(service: MCPService, usageService: UsageService,
         initialLayout: KnowledgeLayout = .list,
         initialDetailName: String? = nil, initialFormTarget: MCPFormTarget? = nil) {
        self._service = ObservedObject(wrappedValue: service)
        self._usageService = ObservedObject(wrappedValue: usageService)
        self._layout = State(initialValue: initialLayout)
        self._detailName = State(initialValue: initialDetailName)
        self._formTarget = State(initialValue: initialFormTarget)
    }

    private let gridColumns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        Group {
            if let target = formTarget {
                MCPServerFormView(
                    service: service, target: target,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { formTarget = nil } })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if let name = detailName {
                MCPDetailView(
                    service: service, usage: usageService, serverName: name,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detailName = nil } },
                    onDeleteEntry: { deletingEntry = $0 },
                    onEdit: { entry in
                        withAnimation(.easeOut(duration: 0.15)) {
                            formTarget = MCPFormTarget(
                                id: "edit:\(entry.id)", mode: .form, editing: entry)
                        }
                    },
                    onEditCredentials: { entry in
                        withAnimation(.easeOut(duration: 0.15)) {
                            formTarget = MCPFormTarget(
                                id: "edit:\(entry.id)", mode: .form, editing: entry,
                                expandCredentials: true)
                        }
                    })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    content
                }
            }
        }
        .onAppear {
            service.refresh()
            usageService.loadMCPStats()
        }
        .confirmationDialog(
            deletingEntry.map {
                L10n.format("From %@, remove server “%@”? A .bak.eureka backup is kept before writing.", zhHans: "从 %@ 移除 server「%@」？写前会留 .bak.eureka 备份。", String($0.source.displayName), String($0.name))
            } ?? "",
            isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Remove", zhHans: "移除"), role: .destructive) {
                if let entry = deletingEntry { service.remove(entry) }
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    // MARK: - 顶部栏（与家族逐字节一致）

    private var header: some View {
        HStack(spacing: 12) {
            Text("MCP").font(Theme.font.themed(15, .bold))
            SearchField(
                placeholder: L10n.text("Search MCP servers", zhHans: "搜索 MCP server"), text: $service.searchText,
                scanning: service.scanning, resultCount: totalCount)
            Spacer(minLength: 12)
            createButton
            ScanStatusLabel(
                scanning: service.scanning, phase: nil,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: L10n.text("Force rescan of MCP config", zhHans: "强制重扫 MCP 配置")) { service.refresh(force: true) }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// 家族标准的裸 ＋ 圆钮：点击**直达**添加页（页内再分 快速安装/手动配置/JSON 三页签），
    /// 不再弹二级菜单 —— 少一跳，风格也与其它知识页签一致。
    private var createButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) {
                formTarget = MCPFormTarget(id: "new", mode: .quick)
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.brandFill(0.10)))
                .overlay(Circle().strokeBorder(Theme.brand.opacity(0.35), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
        .help(L10n.text("Add MCP server", zhHans: "添加 MCP server"))
    }

    // MARK: - 数据口径

    private var totalCount: Int { service.servers.count }

    private func count(for source: AgentSource) -> Int {
        service.servers.lazy.filter { $0.source == source }.count
    }

    private var availableSources: [AgentSource] {
        var seen = Set<AgentSource>()
        let distinct = service.servers.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
        return distinct.sorted { count(for: $0) > count(for: $1) }
    }

    private var filteredEntries: [MCPServerEntry] {
        service.servers.filter { selectedSource == nil || $0.source == selectedSource }
    }

    /// 去重后的 server 名数（统计卡主数字）
    private var dedupedCount: Int {
        Set(service.servers.map { $0.name.lowercased() }).count
    }

    /// 已实测 server 的能力合计（总览卡角注）：让"全局有多少工具可用"一眼可见
    private var measuredCapabilityNote: String? {
        let names = Set(service.servers.map { $0.name.lowercased() })
        let measured = names.compactMap { service.toolCache[$0] }
        guard !measured.isEmpty else { return nil }
        var parts = [L10n.format("Probed %@ · tools %@", zhHans: "实测 %@ 个 · 工具 %@", String(measured.count), String(measured.reduce(0) { $0 + $1.toolCount }))]
        let prompts = measured.reduce(0) { $0 + ($1.promptCount ?? 0) }
        let resources = measured.reduce(0) { $0 + ($1.resourceCount ?? 0) }
        if prompts > 0 { parts.append(L10n.format("prompts %@", zhHans: "提示词 %@", String(prompts))) }
        if resources > 0 { parts.append(L10n.format("resources %@", zhHans: "资源 %@", String(resources))) }
        return parts.joined(separator: " · ")
    }

    /// 传输方式分布（brand 渐变段，照 Agents 页的模型分布做法）
    private var transportSegments: [StatOverviewCard.Segment] {
        var counts: [String: Int] = [:]
        for entry in service.servers { counts[entry.transport, default: 0] += 1 }
        let shades: [Double] = [1.0, 0.78, 0.6, 0.45]
        return counts.sorted { $0.value > $1.value }.enumerated().map { index, pair in
            StatOverviewCard.Segment(
                label: pair.key, count: pair.value,
                color: Theme.brand.opacity(shades[min(index, shades.count - 1)]))
        }
    }

    // MARK: - 内容区

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                StatOverviewCard(
                    value: "\(dedupedCount)", unit: "MCP server",
                    subtitle: L10n.format("%@ configs · %@ sources", zhHans: "%@ 处配置 · %@ 个源", String(totalCount), String(availableSources.count)),
                    distributionTitle: L10n.text("Transport", zhHans: "传输方式"),
                    segments: transportSegments,
                    trailingNote: measuredCapabilityNote)
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: ToolKind.mcp.icon,
                    totalCount: totalCount,
                    sources: availableSources,
                    count: { count(for: $0) })
                probeBar
                if filteredEntries.isEmpty {
                    emptyState.padding(.top, 40)
                } else if layout == .cards {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(filteredEntries) { entry in
                            MCPCard(
                                entry: entry, service: service,
                                toolInfo: toolInfo(for: entry),
                                callStat: callStat(for: entry),
                                onOpen: { open(entry) },
                                onEdit: { edit(entry) },
                                onToggle: { toggle(entry) },
                                onDelete: { deletingEntry = entry })
                        }
                    }
                } else {
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(filteredEntries.enumerated()), id: \.element.id) { index, entry in
                                MCPRow(
                                    entry: entry, service: service,
                                    toolInfo: toolInfo(for: entry),
                                    callStat: callStat(for: entry),
                                    onOpen: { open(entry) },
                                    onEdit: { edit(entry) },
                                    onToggle: { toggle(entry) },
                                    onDelete: { deletingEntry = entry })
                                if index < filteredEntries.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
                if let error = service.lastError {
                    Text(error).font(Theme.font.themed(10)).foregroundStyle(.orange)
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    private func open(_ entry: MCPServerEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detailName = entry.name }
    }

    /// 批量检测操作行：串行逐处、可取消；stdio 深探只在此类显式动作下发生
    @ViewBuilder
    private var probeBar: some View {
        HStack(spacing: 8) {
            if let progress = service.probeProgress {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text(L10n.format("Probing %@/%@", zhHans: "检测中 %@/%@", String(progress.done), String(progress.total)))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                Button(L10n.text("Cancel", zhHans: "取消")) { service.cancelProbe() }
                    .font(Theme.font.themed(10))
            } else {
                Button {
                    service.probe(filteredEntries)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 9))
                        Text(selectedSource == nil ? L10n.text("Probe all", zhHans: "检测全部") : L10n.text("Probe this source", zhHans: "检测当前源"))
                            .font(Theme.font.themed(10))
                    }
                }
                .disabled(filteredEntries.isEmpty)
                .help(L10n.format("Probe each config (%@): remote does an MCP handshake; stdio briefly starts the configured command and exits after reading", zhHans: "逐处发起连接检测（%@ 处）：remote 走 MCP 握手；stdio 会短暂启动配置的命令，读完即退出", String(filteredEntries.count)))
            }
            Spacer()
        }
    }

    private func toolInfo(for entry: MCPServerEntry) -> MCPToolCacheEntry? {
        service.toolCache[entry.name.lowercased()]
    }

    private func callStat(for entry: MCPServerEntry) -> UsageService.MCPServerCallStat? {
        usageService.mcpServerStats[entry.name.lowercased()]
    }

    private func toggle(_ entry: MCPServerEntry) {
        service.setEnabled(entry, !(entry.enabled ?? true))
    }

    private func edit(_ entry: MCPServerEntry) {
        withAnimation(.easeOut(duration: 0.15)) {
            formTarget = MCPFormTarget(id: "edit:\(entry.id)", mode: .form, editing: entry)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 8) {
                ProgressView()
                Text(L10n.text("Scanning MCP config…", zhHans: "正在扫描 MCP 配置…")).font(Theme.font.themed(12)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            let filtered = service.isSearching || selectedSource != nil
            EmptyStateView(
                icon: ToolKind.mcp.icon,
                title: filtered ? L10n.text("No matching MCP servers", zhHans: "没有匹配的 MCP server") : L10n.text("No MCP servers configured yet", zhHans: "还没有 MCP server 配置"),
                hint: filtered
                    ? nil : L10n.text("Create one, or paste the mcpServers JSON from a README to install it into several CLIs at once", zhHans: "新建一个，或粘贴 README 里的 mcpServers JSON 一键装到多个 CLI"),
                actionTitle: filtered ? nil : L10n.text("New MCP Server", zhHans: "新建 MCP Server"),
                action: filtered ? nil : {
                    withAnimation(.easeOut(duration: 0.15)) {
                        formTarget = MCPFormTarget(id: "new", mode: .quick)
                    }
                })
        }
    }
}

/// 探测快照色调 → 主题色（列表状态点与详情 chip 共用）
func mcpToneColor(_ tone: String) -> Color {
    switch tone {
    case "ok": return Theme.enabledGreen
    case "warning": return Theme.goldFg
    default: return Theme.failureRed
    }
}

/// NSOpenPanel 选项目根（项目级 .mcp.json 安装的 repo 选择兜底；表单与详情矩阵共用）
private func mcpPickProjectRoot() -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = false
    panel.message = L10n.text("Choose the project root to write .mcp.json into", zhHans: "选择要写入 .mcp.json 的项目根目录")
    return panel.runModal() == .OK ? panel.url?.path : nil
}

/// 快照过期阈值：超过 7 天视为过期（列表灰点 + 详情提示，建议重新检测）
private let mcpProbeStaleThreshold: TimeInterval = 7 * 86_400

private func mcpSnapshotStale(_ snapshot: MCPProbeSnapshot) -> Bool {
    Date().timeIntervalSince(snapshot.checkedAt) > mcpProbeStaleThreshold
}

/// 总览行/卡的能力计数摘要："30 工具 · 5 提示词 · 2 资源"（实测过才有；0 略去不占位）
func mcpCapabilitySummary(_ info: MCPToolCacheEntry?) -> String? {
    guard let info else { return nil }
    var parts = [L10n.format("%@ tools", zhHans: "%@ 工具", String(info.toolCount))]
    if let prompts = info.promptCount, prompts > 0 { parts.append(L10n.format("%@ prompts", zhHans: "%@ 提示词", String(prompts))) }
    if let resources = info.resourceCount, resources > 0 { parts.append(L10n.format("%@ resources", zhHans: "%@ 资源", String(resources))) }
    return parts.joined(separator: " · ")
}

/// 折叠态描述：换行/连续空白压成单空格。`lineLimit` 按渲染行计数，MCP server 的
/// description 普遍带 `\n\n` 段落分隔——不压平的话第二"行"是一个看不见的空行，
/// 每行工具被无端撑高 ~12pt，文字贴上分隔线、底下留说不清来由的空白，行距节奏全乱。
/// （展开态仍显示原文段落，完整保真。）
func mcpFlatDescription(_ text: String) -> String {
    text.components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
}

// MARK: - 能力清单的行组件（主题化：brutal = 墨线/硬角，classic = 细线/圆角）

/// 行分隔线：brutal = **实心墨线 2px**（粗野主义的表格线不打折扣，30% 透明的
/// hairline 在奶油底上读作"柔和派"）；classic / 配色主题 = hairline 一像素。
struct MCPRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(ThemeStyle.current.isHardEdged ? Theme.cardBorder : Theme.hairline)
            .frame(height: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 1)
    }
}

/// 能力清单的**表格井**：外框 + 行线成套才是完整的表格框线
/// （brutal = 直角 + 2px 墨边；classic = 圆角 8 + hairline 的 macOS 分组表）。
/// 底色用 surfaceSecondary，让表格从卡面上"凹"下去一层。
struct MCPListWell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        let radius: CGFloat = ThemeStyle.current.isHardEdged ? 0 : 8
        VStack(alignment: .leading, spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: radius).fill(Theme.surfaceSecondary))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged ? Theme.cardBorder : Theme.hairline,
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

/// 工具行（Claude Desktop 式）：名称等宽 + 注解 chips，描述做副标题；
/// 悬停整行轻染，点击展开全文与参数清单（必填带 *）。
/// 行距节奏：brutal 用 `Theme.spacing.row`（9pt）垂直内边距——2pt 墨线表格线
/// 要配足呼吸感才读作粗野主义的"格"；classic 保持原 7pt 紧凑分组表观感。
struct MCPToolRowView: View {
    let tool: MCPToolSummary
    let expanded: Bool
    let onToggle: () -> Void

    @State private var hovering = false

    var body: some View {
        let params = tool.params ?? []
        let expandable = !params.isEmpty || (tool.description?.count ?? 0) > 120
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(tool.name)
                    .font(Theme.font.monoSkillName(11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let title = tool.title, !title.isEmpty, title != tool.name {
                    Text(title)
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if tool.readOnly == true { TagChip(L10n.text("Read-only", zhHans: "只读"), neutral: true) }
                if tool.destructive == true { TagChip(L10n.text("Destructive", zhHans: "破坏性"), tint: mcpToneColor("bad")) }
                if tool.hasOutputSchema == true { TagChip(L10n.text("Structured output", zhHans: "结构化输出"), neutral: true) }
                Spacer(minLength: 0)
                if expandable {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(hovering ? .secondary : .tertiary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
            }
            if let desc = tool.description, !desc.isEmpty {
                Text(expanded ? desc : mcpFlatDescription(desc))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 2)
                    .fixedSize(horizontal: false, vertical: expanded)
            }
            if expanded, !params.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.text("Parameters", zhHans: "参数"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 4, lineSpacing: 4) {
                        ForEach(params, id: \.self) { TagChip($0, neutral: true) }
                    }
                    Text(L10n.text("* required", zhHans: "* 必填"))
                        .font(Theme.font.themed(9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, ThemeStyle.current.isHardEdged ? 10 : 8)
        .padding(.vertical, ThemeStyle.current.isHardEdged ? Theme.spacing.row : 7)
        .background(
            RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 6)
                .fill(hovering ? Theme.brandFill(0.05) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            guard expandable else { return }
            onToggle()
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: expanded)
    }
}

/// 提示词/资源行：名字等宽 + 描述副标题，悬停轻染（无展开语义）。
/// 描述同样压平换行（`mcpFlatDescription` 见其注释）；行距随 brutal 加档。
struct MCPNamedRowView: View {
    let item: MCPNamedSummary

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name)
                .font(Theme.font.monoSkillName(11, weight: .medium))
                .foregroundStyle(.primary)
            if let desc = item.description, !desc.isEmpty {
                Text(mcpFlatDescription(desc))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, ThemeStyle.current.isHardEdged ? 10 : 8)
        .padding(.vertical, ThemeStyle.current.isHardEdged ? 8 : 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 6)
                .fill(hovering ? Theme.brandFill(0.05) : Color.clear))
        .onHover { hovering = $0 }
    }
}

/// 能力分组页签（工具/提示词/资源）：与 SourceFilterChip 同一套选中/悬停/描边规格
/// （选中 = 品牌实底白字 + brutal 墨边硬影；未选 = 灰底细边、悬停轻染）
struct MCPCapabilitySegment: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Text(label)
                    .font(Theme.font.themed(10.5, isSelected ? .semibold : .medium))
                Text("\(count)")
                    .font(Theme.font.themedMono(10, .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(hovering ? Theme.brandFill(0.06) : Theme.surfaceSecondary))
                    // 硬影只能画在纯形状层：画到含文字的合成视图上，文字会在偏移处留下重影
                    .themeControlShadow(active: isSelected))
            .overlay(
                Capsule().strokeBorder(
                    ThemeStyle.current.isHardEdged
                        ? Theme.cardBorder
                        : (isSelected ? Color.clear : Theme.cardBorder),
                    lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 图标瓦片（照 PlanIconTile / AuditView.kindTile 的 TileSpec 模板）

struct MCPIconTile: View {
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        ThemeStyle.current.isHardEdged ? Theme.cardBorder : TileSpec.border(Theme.brand),
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
            .overlay(
                Image(systemName: ToolKind.mcp.icon)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(Theme.brandFg))
    }
}

// MARK: - 行 / 卡 共用的动作与菜单

private func mcpEntryActions(
    _ entry: MCPServerEntry, service: MCPService,
    onEdit: @escaping () -> Void, onDelete: @escaping () -> Void
) -> [CardAction] {
    [
        // 铅笔 = 应用内编辑表单（外部编辑器入口在右键菜单——直接弹整份配置文件太吓人）
        CardAction(icon: "square.and.pencil", help: L10n.text("Edit this definition", zhHans: "编辑该处定义")) {
            onEdit()
        },
        CardAction(icon: "folder", help: L10n.text("Show the config file in Finder", zhHans: "在 Finder 中显示配置文件")) {
            service.reveal(path: entry.configPath)
        },
        CardAction(icon: "trash", destructive: true, help: L10n.text("Remove from this config (backup before writing)", zhHans: "从该配置移除（写前留备份）")) {
            onDelete()
        },
    ]
}

@ViewBuilder
private func mcpEntryMenu(
    _ entry: MCPServerEntry, service: MCPService,
    onOpen: @escaping () -> Void, onEdit: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(L10n.text("View details / install into another agent", zhHans: "查看详情 / 安装到其他 agent")) { onOpen() }
    Button(L10n.text("Edit this definition", zhHans: "编辑该处定义")) { onEdit() }
    Button(L10n.text("Open the config file in the default editor", zhHans: "用默认编辑器打开配置文件")) { service.openInEditor(path: entry.configPath) }
    Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: entry.configPath) }
    Divider()
    Button(L10n.text("Remove from this config", zhHans: "从该配置移除"), role: .destructive) { onDelete() }
}

// MARK: - 列表行

private struct MCPRow: View {
    let entry: MCPServerEntry
    let service: MCPService
    let toolInfo: MCPToolCacheEntry?
    let callStat: UsageService.MCPServerCallStat?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeRow(
            enabled: entry.enabled != false,
            actions: mcpEntryActions(entry, service: service, onEdit: onEdit, onDelete: onDelete),
            onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                SourceLogoTile(source: entry.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        // 上次检测的健康点（持久快照；无快照不显示）——扫一眼列表即知全局状态；
                        // 超过 7 天转灰点（过期，结果未必仍成立）
                        if let snapshot = service.probeSnapshots[entry.id] {
                            let stale = mcpSnapshotStale(snapshot)
                            Circle()
                                .fill(stale
                                    ? Color.secondary.opacity(0.45)
                                    : mcpToneColor(snapshot.tone))
                                .frame(width: 6, height: 6)
                                .help(stale
                                    ? L10n.format("Last probe: %@ (over 7 days ago — probe again)", zhHans: "上次检测：%@（已超过 7 天，建议重新检测）", String(snapshot.label))
                                    : L10n.format("Last probe: %@", zhHans: "上次检测：%@", String(snapshot.label)))
                        }
                        Text(entry.name)
                            .font(Theme.font.monoSkillName(13, weight: .medium))
                            .foregroundStyle(entry.enabled != false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        TagChip(entry.transport, neutral: true)
                        if let project = entry.projectName {
                            TagChip(project)
                        }
                        if entry.enabled == false {
                            TagChip(L10n.text("Disabled", zhHans: "已停用"), tint: Theme.failureRed)
                        }
                    }
                    if let summary = entry.commandSummary ?? entry.urlSummary {
                        Text(summary)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    if let summary = mcpCapabilitySummary(toolInfo) {
                        Text(summary)
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let callStat, callStat.calls > 0 {
                        Text(L10n.format("%@ calls", zhHans: "%@ 次调用", String(callStat.calls)))
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.tertiary)
                    } else if toolInfo == nil, !entry.envKeys.isEmpty {
                        Text(L10n.format("%@ secret keys", zhHans: "%@ 个密钥键", String(entry.envKeys.count)))
                            .font(Theme.font.themedMono(10.5))
                            .foregroundStyle(.tertiary)
                    }
                    if MCPService.supportsEnableToggle(entry.source) {
                        MiniSwitch(isOn: entry.enabled ?? true) { onToggle() }
                    }
                }
                .fixedSize()
            }
        } menu: {
            mcpEntryMenu(entry, service: service, onOpen: onOpen, onEdit: onEdit,
                         onDelete: onDelete)
        }
    }
}

// MARK: - 网格卡

private struct MCPCard: View {
    let entry: MCPServerEntry
    let service: MCPService
    let toolInfo: MCPToolCacheEntry?
    let callStat: UsageService.MCPServerCallStat?
    let onOpen: () -> Void
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeCard(
            enabled: entry.enabled != false, minHeight: 92,
            actions: mcpEntryActions(entry, service: service, onEdit: onEdit, onDelete: onDelete),
            onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    SourceLogoTile(source: entry.source, size: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.name)
                            .font(Theme.font.monoSkillName(13))
                            .foregroundStyle(entry.enabled != false ? .primary : .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HStack(spacing: 5) {
                            TagChip(entry.transport, neutral: true)
                            if entry.enabled == false {
                                TagChip(L10n.text("Disabled", zhHans: "已停用"), tint: Theme.failureRed)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if MCPService.supportsEnableToggle(entry.source) {
                        MiniSwitch(isOn: entry.enabled ?? true) { onToggle() }
                    }
                }
                Text(entry.commandSummary ?? entry.urlSummary ?? "")
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2, reservesSpace: true)
                    .lineSpacing(1.5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if let project = entry.projectName {
                        TagChip(project)
                    }
                    Spacer(minLength: 0)
                    if let summary = mcpCapabilitySummary(toolInfo) {
                        Text(summary)
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    if let callStat, callStat.calls > 0 {
                        Text(L10n.format("%@ calls", zhHans: "%@ 次调用", String(callStat.calls)))
                            .font(Theme.font.themedMono(10))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } menu: {
            mcpEntryMenu(entry, service: service, onOpen: onOpen, onEdit: onEdit,
                         onDelete: onDelete)
        }
    }
}

// MARK: - 滑入详情（按名聚合：定义 + 跨源矩阵 + 各处配置）

private struct MCPDetailView: View {
    @ObservedObject var service: MCPService
    @ObservedObject var usage: UsageService
    let serverName: String
    let onBack: () -> Void
    let onDeleteEntry: (MCPServerEntry) -> Void
    let onEdit: (MCPServerEntry) -> Void
    /// 「编辑请求头/环境变量」入口：进编辑表单并强制展开对应折叠区
    let onEditCredentials: (MCPServerEntry) -> Void

    /// 待确认的跨源安装目标
    @State private var installTarget: AgentSource?
    /// 项目级安装 sheet（repo 选择）
    @State private var projectSheet = false
    @State private var projectRootPath = ""
    @State private var projectCursorToo = false
    /// 安装结果反馈（矩阵下方短暂显示）
    @State private var installNote: String?
    /// 复制为 JSON 的反馈
    @State private var copyNote: String?
    /// 预注册 client_id 草稿（高级折叠区）
    @State private var clientIDDraft = ""
    @State private var clientIDExpanded = false
    /// 能力卡：当前分组（tools / prompts / resources）、搜索词、展开的工具
    @State private var capabilityTab = "tools"
    @State private var capabilitySearch = ""
    @State private var expandedTools: Set<String> = []
    /// 调用活跃（近 30 天逐日 + top 工具；onAppear 异步加载）
    @State private var activity: UsageService.MCPServerActivity?
    /// 闲置清理（从所有源移除）确认与反馈
    @State private var removeAllConfirm = false
    @State private var removeAllNote: String?

    /// 实时条目：删除/安装后 service 重扫，这里跟着刷新
    private var entries: [MCPServerEntry] { service.entries(named: serverName) }
    private var primary: MCPServerEntry? { entries.first }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if entries.isEmpty {
                EmptyStateView(
                    icon: ToolKind.mcp.icon, title: L10n.text("This server is no longer in any config", zhHans: "该 server 已不在任何配置中"),
                    hint: nil, actionTitle: L10n.text("Back", zhHans: "返回"), action: onBack)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        definitionSection
                        connectionSection
                        runtimeSection
                        activitySection
                        matrixSection
                        occurrencesSection
                    }
                    .padding(Theme.spacing.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { loadActivity() }
            }
        }
    }

    private func loadActivity() {
        usage.loadMCPServerActivity(server: serverName) { activity = $0 }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L10n.text("Back", zhHans: "返回")).font(Theme.font.themed(11))
                }
            }
            .buttonStyle(.borderless)
            MCPIconTile(size: 26)
            Text(serverName)
                .font(Theme.font.monoSkillName(15, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let transport = primary?.transport {
                TagChip(transport, neutral: true)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 定义卡

    @ViewBuilder
    private var definitionSection: some View {
        if let primary {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    sectionTitle(L10n.text("Definition", zhHans: "定义"))
                    CardActionButton(icon: "doc.on.doc", size: 20,
                                     help: L10n.text("Copy as mcpServers JSON (secret values omitted)", zhHans: "复制为 mcpServers JSON（不含密钥值）")) {
                        service.copyDefinitionJSON(primary) { ok in
                            copyNote = ok ? L10n.text("Copied (secret values left blank)", zhHans: "已复制（密钥值以空串占位）") : L10n.text("Copy failed", zhHans: "复制失败")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { copyNote = nil }
                        }
                    }
                    if let note = copyNote {
                        Text(note).font(Theme.font.themed(10)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let command = primary.commandSummary {
                        labeledMono(L10n.text("Command", zhHans: "命令"), command)
                    }
                    if let url = primary.urlSummary {
                        labeledMono(L10n.text("URL", zhHans: "地址"), url)
                    }
                    if !primary.envKeys.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            fieldLabel(L10n.text("Secret keys", zhHans: "密钥键"))
                            FlowLayout(spacing: 5, lineSpacing: 5) {
                                ForEach(primary.envKeys, id: \.self) { TagChip($0, neutral: true) }
                            }
                            Text(L10n.text("(values are not read or shown)", zhHans: "（值不读取、不显示）"))
                                .font(Theme.font.themed(9.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .fill(Theme.surface)
                        .themeCardShadow())
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            }
        }
    }

    private func labeledMono(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            fieldLabel(label)
            Text(value)
                .font(Theme.font.monoSkillName(11, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(10))
            .foregroundStyle(.tertiary)
            .frame(width: 44, alignment: .leading)
    }

    // MARK: 连接与授权（v2.6：状态直显、动作摊开——不藏菜单、不让用户猜）

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("Connection and auth", zhHans: "连接与授权"))
                Spacer(minLength: 8)
                Button {
                    service.probe(entries)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.path.ecg").font(.system(size: 10))
                        Text(L10n.text("Probe again", zhHans: "重新检测")).font(Theme.font.themed(11))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 10) {
                // ① 上次检测（逐处配置直显持久快照；从未检测过 = "尚未检测"）
                ForEach(entries) { entry in
                    probeStatusRow(entry)
                }
                // ② 鉴权动线（v2.7：按识别出的鉴权方式路由——OAuth 才给浏览器授权，
                //    请求头密钥给「编辑请求头」，stdio 给「编辑环境变量」，不再让用户猜）
                MCPRowDivider()
                authRouteSection
                // ③ CLI 侧授权（按已配置的源逐行列出，带文字按钮直接可点）
                cliAuthRows
                Text(L10n.text("The result is the last snapshot. Choose “Probe again” for a fresh one. Probe and auth requests go only to the address this server itself advertises.", zhHans: "检测结果为上次快照，点「重新检测」获取最新；检测与授权请求只发往该 server 自己披露的地址。")
                    + (primary?.transport == "stdio"
                        ? L10n.text(" A stdio probe briefly starts the configured command to read its capabilities, then exits.", zhHans: "stdio 检测会短暂启动配置的命令以读取能力清单，完成即退出。") : ""))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surface)
                    .themeCardShadow())
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
    }

    private func probeStatusRow(_ entry: MCPServerEntry) -> some View {
        HStack(spacing: 8) {
            SourceBadge(source: entry.source, size: 14)
            Text(entry.source.displayName)
                .font(Theme.font.themed(11, .medium))
                .frame(width: 90, alignment: .leading)
            if service.probeResults[entry.id] == .checking {
                ProgressView().controlSize(.small).scaleEffect(0.6)
                Text(L10n.text("Probing…", zhHans: "检测中…")).font(Theme.font.themed(10.5)).foregroundStyle(.secondary)
            } else if let snapshot = service.probeSnapshots[entry.id] {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        TagChip(snapshot.label, tint: mcpToneColor(snapshot.tone))
                        if let detail = snapshot.detail {
                            Text(detail)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Text(relativeFormatter.localizedString(
                            for: snapshot.checkedAt, relativeTo: Date())
                            + (mcpSnapshotStale(snapshot) ? L10n.text(" · expired", zhHans: " · 已过期") : ""))
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if let hint = snapshot.hint {
                        Text(hint)
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(Theme.goldFg)
                    }
                }
            } else {
                Text(L10n.text("Not probed yet", zhHans: "尚未检测")).font(Theme.font.themed(10.5)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    /// 鉴权路由（v2.7）：配置形态 + 持久快照信号，零网络零猜测。
    /// envKeys 在索引层是 env/headers 键名的合集——remote 时按请求头解读，stdio 按环境变量。
    private var authRoute: MCPAuthRoute {
        guard let primary else { return .unknown }
        let schemes = entries.compactMap { service.probeSnapshots[$0.id]?.authScheme }
        let scheme = schemes.contains("oauth") ? "oauth"
            : (schemes.contains("header-or-key") ? "header-or-key" : schemes.first)
        let isStdio = primary.transport == "stdio"
        return MCPAuthRouter.route(
            transport: primary.transport,
            headerKeys: isStdio ? [] : primary.envKeys,
            envKeys: isStdio ? primary.envKeys : [],
            snapshotScheme: scheme,
            hasToken: service.hasToken(for: primary))
    }

    /// 鉴权动线：五路分流（OAuth 浏览器 / 请求头密钥 / 环境变量 / 无鉴权 / 待检测）
    @ViewBuilder
    private var authRouteSection: some View {
        if let primary {
            switch authRoute {
            case .oauthBrowser:
                eurekaTokenRow(prominent: true)
                clientIDDisclosure
            case .staticHeader(let keys):
                authInfoRow(
                    icon: "key.horizontal",
                    title: keys.isEmpty
                        ? L10n.text("Auth: header secret (not set yet)", zhHans: "鉴权方式：请求头密钥（待填入）")
                        : L10n.format("Auth: header secret (%@)", zhHans: "鉴权方式：请求头密钥（%@）", String(keys.joined(separator: ", "))),
                    body: keys.isEmpty
                        ? L10n.text("The last probe returned 401 and published no OAuth metadata — this server uses an API key. Enter it under Headers in the edit form.", zhHans: "上次检测返回 401 且未公布 OAuth 元数据——该 server 走 API key 鉴权，在编辑表单的「请求头」里填入密钥即可。")
                        : L10n.text("This server authenticates with a static header secret and has no OAuth redirect. When the secret expires, update it in the edit form.", zhHans: "该 server 用静态请求头密钥鉴权，无 OAuth 跳转；密钥过期时在编辑表单里更新值。"),
                    buttonTitle: L10n.text("Edit headers", zhHans: "编辑请求头"), prominent: true
                ) { onEditCredentials(primary) }
            case .envKeys(let keys):
                authInfoRow(
                    icon: "key.horizontal",
                    title: L10n.format("Auth: environment variables (%@)", zhHans: "鉴权方式：环境变量（%@）", String(keys.joined(separator: ", "))),
                    body: L10n.text("A stdio server takes credentials from environment variables, per the MCP spec, with no browser auth. When a secret expires, update it under Environment in the edit form.", zhHans: "stdio server 的凭证按 MCP 规范取自环境变量，无浏览器授权；密钥过期时在编辑表单的「环境变量」里更新值。"),
                    buttonTitle: L10n.text("Edit environment", zhHans: "编辑环境变量"), prominent: false
                ) { onEditCredentials(primary) }
            case .open:
                authInfoRow(
                    icon: "lock.open",
                    title: L10n.text("No auth required", zhHans: "无需鉴权"),
                    body: primary.transport == "stdio"
                        ? L10n.text("This stdio server has no secrets configured.", zhHans: "该 stdio server 未配置任何密钥。")
                        : L10n.text("The last probe connected without credentials. No auth is required.", zhHans: "上次检测未携带凭证即连通，无需授权。"),
                    buttonTitle: nil, prominent: false, action: nil)
            case .unknown:
                authInfoRow(
                    icon: "questionmark.circle",
                    title: L10n.text("Auth method not probed yet", zhHans: "鉴权方式待检测"),
                    body: L10n.text("Choose “Probe again” to detect it: a 401 that publishes OAuth metadata means browser auth; otherwise it’s an API key (edit headers).", zhHans: "点「重新检测」自动识别：401 公布 OAuth 元数据 → 浏览器授权；未公布 → API key（编辑请求头）。"),
                    buttonTitle: nil, prominent: false, action: nil)
                eurekaTokenRow(prominent: false)
            }
        }
    }

    /// 鉴权说明行：图标 + 标题 + 说明正文 + 可选动作按钮（正文可见，不用 tooltip）
    private func authInfoRow(
        icon: String, title: String, body bodyText: String,
        buttonTitle: String?, prominent: Bool, action: (() -> Void)?
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.font.themed(11.5, .medium))
                Text(bodyText)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let buttonTitle, let action {
                if prominent {
                    Button(buttonTitle, action: action)
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                } else {
                    Button(buttonTitle, action: action).controlSize(.small)
                }
            }
        }
    }

    /// Eureka 令牌行：状态点 + 说明正文 + 可见按钮（授权/撤销）；OAuth 进度就地显示。
    /// prominent = false 用于「待检测」路由——授权仍可用但降为次要动作。
    @ViewBuilder
    private func eurekaTokenRow(prominent: Bool) -> some View {
        if let primary {
            let holding = service.hasToken(for: primary)
            HStack(alignment: .top, spacing: 8) {
                Circle()
                    .fill(holding ? Theme.enabledGreen : Theme.disabledGray)
                    .frame(width: 7, height: 7)
                    .padding(.top, 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(holding ? L10n.text("Eureka token: held", zhHans: "Eureka 令牌：已持有") : L10n.text("Eureka token: not held", zhHans: "Eureka 令牌：未持有"))
                        .font(Theme.font.themed(11.5, .medium))
                    Text(L10n.text("The token is only for probing and the tool list in this app. Each CLI authorizes its own connection.", zhHans: "令牌只用于本应用的检测与工具清单；CLI 的连接授权在各 CLI 内完成。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                    if let note = entries.compactMap({ service.oauthNotes[$0.id] }).last {
                        Text(note)
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if holding {
                    Button(L10n.text("Revoke", zhHans: "撤销")) { service.revokeToken(for: primary) }
                        .controlSize(.small)
                } else if prominent {
                    Button(L10n.text("Authorize in browser", zhHans: "在浏览器中授权")) { service.authorizeInBrowser(primary) }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.brand)
                } else {
                    Button(L10n.text("Authorize in browser", zhHans: "在浏览器中授权")) { service.authorizeInBrowser(primary) }
                        .controlSize(.small)
                }
            }
        }
    }

    /// 高级：预注册 client_id（AS 不支持动态注册时的规范出口；client_id 非密钥）
    @ViewBuilder
    private var clientIDDisclosure: some View {
        if let primary {
            let saved = service.preRegisteredClientID(for: primary)
            DisclosureGroup(isExpanded: $clientIDExpanded) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        TextField(L10n.text("client_id issued by the authorization server", zhHans: "授权服务器分发的 client_id"), text: $clientIDDraft)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.monoSkillName(10.5, weight: .regular))
                        Button(L10n.text("Save", zhHans: "保存")) {
                            service.setPreRegisteredClientID(clientIDDraft, for: primary)
                        }
                        .controlSize(.small)
                        .disabled(clientIDDraft.trimmingCharacters(in: .whitespaces) == saved)
                    }
                    Text(L10n.text("Use this when the authorization server does not support dynamic client registration (DCR): register a public client in its console", zhHans: "授权服务器不支持动态注册（DCR）时使用：在其控制台注册一个公共客户端")
                        + L10n.text(" (callback URL http://127.0.0.1/callback; OAuth 2.1 allows any port on loopback),", zhHans: "（回调地址 http://127.0.0.1/callback，回环地址按 OAuth 2.1 允许任意端口），")
                        + L10n.text(" paste the client_id here. Saving an empty value clears it.", zhHans: "把 client_id 填在这里；留空保存即清除。"))
                        .font(Theme.font.themed(9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)
            } label: {
                Text(L10n.format("Advanced: pre-registered client_id%@", zhHans: "高级：预注册 client_id%@", String(saved.isEmpty ? "" : L10n.text(" (set)", zhHans: "（已设置）"))))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
            }
            .onAppear { clientIDDraft = saved }
        }
    }

    /// CLI 侧授权（每个已配置的源一行；codex 直跑授权命令，其余打开 CLI 引导）
    @ViewBuilder
    private var cliAuthRows: some View {
        let rows = cliAuthActionRows()
        if !rows.isEmpty {
            MCPRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.text("CLI authorization", zhHans: "CLI 侧授权"))
                    .font(Theme.font.themed(10, .semibold))
                    .foregroundStyle(.secondary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        SourceBadge(source: row.0.source, size: 14)
                        Text(row.1.label)
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        if row.1.isDirect {
                            Button(L10n.text("Copy command", zhHans: "复制命令")) { service.copyToPasteboard(row.1.command) }
                                .buttonStyle(.borderless)
                                .font(Theme.font.themed(10.5))
                        }
                        Button(row.1.isDirect ? L10n.text("Open Terminal", zhHans: "去终端") : L10n.text("Open", zhHans: "打开")) {
                            service.openInTerminal(command: row.1.command)
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private func cliAuthActionRows() -> [(MCPServerEntry, MCPService.AuthAction)] {
        var seen = Set<AgentSource>()
        var rows: [(MCPServerEntry, MCPService.AuthAction)] = []
        for entry in entries where seen.insert(entry.source).inserted {
            if let action = MCPService.authActions(for: entry).first {
                rows.append((entry, action))
            }
        }
        return rows
    }

    // MARK: 能力（工具/提示词/资源；MCP 的核心是它提供什么，这一区常驻——不让用户猜）

    @ViewBuilder
    private var runtimeSection: some View {
        let cache = service.toolCache[serverName.lowercased()]
        let stat = usage.mcpServerStats[serverName.lowercased()]
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("Capabilities", zhHans: "能力"))
                Text(L10n.text("Tools / prompts / resources, from the last “Probe again”", zhHans: "工具 / 提示词 / 资源，来自「重新检测」实测"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let cache {
                    capabilityBody(cache: cache, stat: stat)
                } else {
                    // 从未检测过也常驻本卡：告诉用户能力清单从哪来（可发现性）
                    Text(L10n.text("Not probed yet — choose “Probe again” above for this server’s tools, prompts, and resources.", zhHans: "尚未检测——点上方「重新检测」获取该 server 的工具、提示词与资源清单。")
                        + (primary?.transport == "stdio"
                            ? L10n.text(" (a stdio probe briefly starts the configured command and exits after reading)", zhHans: "（stdio server 检测时会短暂启动配置的命令，读完即退出）") : ""))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let stat, stat.calls > 0 {
                        TagChip(L10n.format("Total calls %@", zhHans: "累计调用 %@ 次", String(stat.calls)), neutral: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surface)
                    .themeCardShadow())
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
    }

    @ViewBuilder
    private func capabilityBody(
        cache: MCPToolCacheEntry, stat: UsageService.MCPServerCallStat?
    ) -> some View {
        // 概览 chips：开销与元信息（数量放进分组页签，不重复）
        HStack(spacing: 6) {
            if cache.schemaTokens > 0 {
                TagChip(L10n.format("~%@ tokens per turn", zhHans: "每轮 ~%@ tokens", String(formatTokens(cache.schemaTokens))))
            }
            if let version = cache.serverVersion {
                TagChip("v\(version)", neutral: true)
            }
            if let proto = cache.protocolVersion {
                TagChip(L10n.format("Protocol %@", zhHans: "协议 %@", String(proto)), neutral: true)
            }
            if let stat, stat.calls > 0 {
                TagChip(L10n.format("Total calls %@", zhHans: "累计调用 %@ 次", String(stat.calls)), neutral: true)
            }
        }
        // 分组页签（只显示有数据的组；工具恒在）
        HStack(spacing: 6) {
            capabilitySegment("tools", L10n.text("Tools", zhHans: "工具"), count: cache.toolCount)
            if let count = cache.promptCount {
                capabilitySegment("prompts", L10n.text("Prompts", zhHans: "提示词"), count: count)
            }
            if let count = cache.resourceCount {
                capabilitySegment("resources", L10n.text("Resources", zhHans: "资源"), count: count)
            }
            Spacer(minLength: 0)
        }
        let activeCount = capabilityTab == "prompts"
            ? (cache.prompts?.count ?? 0)
            : capabilityTab == "resources" ? (cache.resources?.count ?? 0) : cache.toolCount
        if activeCount > 10 {
            SearchField(
                placeholder: L10n.text("Search name or description…", zhHans: "搜索名称或描述…"), text: $capabilitySearch,
                resultCount: capabilitySearch.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil : filteredCount(cache: cache),
                maxWidth: 380)
        }
        capabilityList(cache: cache)
        if let hint = idleHint(cache: cache, stat: stat) {
            HStack(spacing: 10) {
                Text(hint)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(Theme.goldFg)
                Button(L10n.text("Remove from all sources…", zhHans: "从所有源移除…")) { removeAllConfirm = true }
                    .font(Theme.font.themed(10, .semibold))
                    .foregroundStyle(Theme.failureRed)
                    .buttonStyle(.borderless)
                if let note = removeAllNote {
                    Text(note).font(Theme.font.themed(10)).foregroundStyle(.secondary)
                }
            }
            .confirmationDialog(
                L10n.format("Remove “%@” from every config?", zhHans: "从所有配置移除「%@」？", String(serverName)),
                isPresented: $removeAllConfirm,
                titleVisibility: .visible
            ) {
                Button(L10n.format("Remove (%@ places, backup each before writing)", zhHans: "移除（%@ 处，写前各留备份）", String(entries.count)), role: .destructive) {
                    runRemoveEverywhere()
                }
                Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
            } message: {
                Text(L10n.format("Will remove from:\n%@", zhHans: "将从以下位置移除：\n%@", String(entries.map(\.configPath).joined(separator: "\n"))))
            }
        }
        Text(L10n.format("Probed %@", zhHans: "检测于 %@", String(relativeFormatter.localizedString(for: cache.measuredAt, relativeTo: Date()))))
            .font(Theme.font.themed(9))
            .foregroundStyle(.tertiary)
    }

    private func capabilitySegment(_ id: String, _ label: String, count: Int) -> some View {
        MCPCapabilitySegment(label: label, count: count, isSelected: capabilityTab == id) {
            capabilityTab = id
            capabilitySearch = ""
        }
    }

    /// 当前分组在搜索词下的命中数（SearchField 右侧计数胶囊用）
    private func filteredCount(cache: MCPToolCacheEntry) -> Int {
        let query = capabilitySearch.trimmingCharacters(in: .whitespaces).lowercased()
        switch capabilityTab {
        case "prompts":
            return (cache.prompts ?? []).filter { matches($0, query) }.count
        case "resources":
            return (cache.resources ?? []).filter { matches($0, query) }.count
        default:
            return (cache.tools ?? []).filter { tool in
                query.isEmpty
                    || tool.name.lowercased().contains(query)
                    || (tool.title ?? "").lowercased().contains(query)
                    || (tool.description ?? "").lowercased().contains(query)
            }.count
        }
    }

    private func matches(_ item: MCPNamedSummary, _ query: String) -> Bool {
        query.isEmpty || item.name.lowercased().contains(query)
            || (item.description ?? "").lowercased().contains(query)
    }

    @ViewBuilder
    private func capabilityList(cache: MCPToolCacheEntry) -> some View {
        let query = capabilitySearch.trimmingCharacters(in: .whitespaces).lowercased()
        switch capabilityTab {
        case "prompts":
            namedList(cache.prompts ?? [], query: query, empty: L10n.text("This server provides no prompts", zhHans: "该 server 未提供提示词"))
        case "resources":
            namedList(cache.resources ?? [], query: query, empty: L10n.text("This server provides no resources", zhHans: "该 server 未提供资源"))
        default:
            if let tools = cache.tools, !tools.isEmpty {
                let filtered = tools.filter { tool in
                    query.isEmpty
                        || tool.name.lowercased().contains(query)
                        || (tool.title ?? "").lowercased().contains(query)
                        || (tool.description ?? "").lowercased().contains(query)
                }
                if filtered.isEmpty {
                    Text(L10n.format("No tools match “%@”", zhHans: "没有匹配「%@」的工具", String(capabilitySearch)))
                        .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
                } else {
                    // 表格井：外框 + 实心行线（brutal = 2px 墨），工具逐条成格
                    MCPListWell {
                        ForEach(Array(filtered.enumerated()), id: \.element.name) { index, tool in
                            if index > 0 { MCPRowDivider() }
                            MCPToolRowView(
                                tool: tool,
                                expanded: expandedTools.contains(tool.name)
                            ) {
                                if expandedTools.contains(tool.name) {
                                    expandedTools.remove(tool.name)
                                } else {
                                    expandedTools.insert(tool.name)
                                }
                            }
                        }
                    }
                }
            } else if !cache.toolNames.isEmpty {
                // 旧缓存只有名字（重新检测一次即升级为明细）
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(cache.toolNames, id: \.self) { name in
                        Text(name)
                            .font(Theme.font.monoSkillName(9.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Theme.surfaceSecondary))
                    }
                }
            } else {
                Text(L10n.text("This server exposes no tools", zhHans: "该 server 未暴露任何工具"))
                    .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func namedList(
        _ items: [MCPNamedSummary], query: String, empty: String
    ) -> some View {
        let filtered = items.filter { matches($0, query) }
        if filtered.isEmpty {
            Text(items.isEmpty ? empty : L10n.format("No items match “%@”", zhHans: "没有匹配「%@」的条目", String(capabilitySearch)))
                .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
        } else {
            MCPListWell {
                ForEach(Array(filtered.enumerated()), id: \.element.name) { index, item in
                    if index > 0 { MCPRowDivider() }
                    MCPNamedRowView(item: item)
                }
            }
        }
    }

    /// 闲置提示：付着每轮 schema 税却 30 天没被调用 → 建议停用/移除
    private func idleHint(
        cache: MCPToolCacheEntry?, stat: UsageService.MCPServerCallStat?
    ) -> String? {
        guard let cache, cache.schemaTokens > 0 else { return nil }
        let thirtyDaysAgo = Date().timeIntervalSince1970 - 30 * 86_400
        let idle = (stat?.calls ?? 0) == 0 || (stat?.lastTs ?? 0) < thirtyDaysAgo
        guard idle else { return nil }
        return L10n.format("No calls in 30 days, but ~%@ tokens are spent every turn — consider disabling or removing it", zhHans: "30 天内没有调用记录，却每轮消耗 ~%@ tokens —— 建议停用或移除", String(formatTokens(cache.schemaTokens)))
    }

    private func runRemoveEverywhere() {
        removeAllNote = L10n.text("Removing…", zhHans: "正在移除…")
        service.removeEverywhere(named: serverName) { results in
            let failures = results.sorted(by: { $0.key < $1.key })
                .compactMap { label, error in error.map { L10n.format("%@: %@", zhHans: "%@：%@", String(label), String($0)) } }
            removeAllNote = failures.isEmpty
                ? L10n.format("Removed from %@ places", zhHans: "已从 %@ 处移除", String(results.count))
                : L10n.text("Partial failure — ", zhHans: "部分失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { removeAllNote = nil }
        }
    }

    // MARK: 调用活跃（用量下钻：近 30 天逐日 + top 工具）

    /// 近 30 天窗口合计（series 已补零，直接求和）
    private var recentCalls: Int {
        activity?.series.reduce(0) { $0 + $1.count } ?? 0
    }

    @ViewBuilder
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                sectionTitle(L10n.text("Call activity", zhHans: "调用活跃"))
                if let stat = usage.mcpServerStats[serverName.lowercased()], stat.calls > 0 {
                    Text(L10n.format("Last 30 days %@ · total %@ · latest %@", zhHans: "近 30 天 %@ 次 · 累计 %@ 次 · 最近 %@", String(recentCalls), String(stat.calls), String(relativeFormatter.localizedString(for: Date(timeIntervalSince1970: stat.lastTs), relativeTo: Date()))))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                } else {
                    Text(L10n.text("No calls yet (scanners from 5 sources count kind='mcp')", zhHans: "暂无调用记录（5 个源的扫描器计入 kind='mcp'）"))
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            if let activity, activity.series.contains(where: { $0.count > 0 }) {
                activityBars(activity)
                if !activity.topTools.isEmpty {
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(activity.topTools, id: \.name) { tool in
                            Text("\(tool.name) · \(tool.count)")
                                .font(Theme.font.monoSkillName(9.5, weight: .regular))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.surfaceSecondary))
                        }
                    }
                }
            }
        }
    }

    /// 30 根迷你柱（缺 0 画基线灰；有调用按峰值缩放）
    private func activityBars(_ activity: UsageService.MCPServerActivity) -> some View {
        let peak = max(activity.series.map(\.count).max() ?? 1, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(activity.series.enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 1)
                    .fill(point.count > 0
                        ? Theme.brand.opacity(0.45 + 0.55 * Double(point.count) / Double(peak))
                        : Color.secondary.opacity(0.15))
                    .frame(height: point.count > 0
                        ? max(4, 30.0 * Double(point.count) / Double(peak))
                        : 2)
            }
        }
        .frame(height: 30, alignment: .bottom)
        .help(L10n.format("Calls per day over 30 days (peak %@/day)", zhHans: "近 30 天逐日调用（最高 %@ 次/天）", String(peak)))
    }

    // MARK: 跨源矩阵（照 SkillDetailView.matrixSection 模板）

    private var matrixSection: some View {
        let configuredSources = Set(entries.map(\.source))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("Configured in", zhHans: "配置于"))
                Text(L10n.format("%@ tools, %@ configured", zhHans: "%@ 个工具中 %@ 个已配置", String(AgentSource.allCases.count), String(configuredSources.count)))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                Text(L10n.text("· click an installable source to copy it there", zhHans: "· 点可安装的源一键复制过去"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    matrixTile(source, configured: configuredSources.contains(source))
                }
                projectMatrixTile
            }
            if let note = installNote {
                Text(note).font(Theme.font.themed(10)).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $projectSheet) { projectInstallSheet }
        .confirmationDialog(
            L10n.format("Install into %@?", zhHans: "安装到 %@？", String(installTarget?.displayName ?? "")),
            isPresented: Binding(
                get: { installTarget != nil },
                set: { if !$0 { installTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(L10n.text("Write this agent’s MCP config", zhHans: "写入该 agent 的 MCP 配置")) { runInstall() }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        } message: {
            if let target = installTarget,
               let writable = MCPService.writableTarget(for: target) {
                Text(L10n.format("The server definition (including secret values, copied only between files on this Mac) will be written to\n%@\nA .bak.eureka backup is kept first.", zhHans: "将把 server 定义（含密钥值，仅本机文件间复制）写入\n%@\n写前会留 .bak.eureka 备份。", String(writable.configURL.path)))
            }
        }
    }

    @ViewBuilder
    private func matrixTile(_ source: AgentSource, configured: Bool) -> some View {
        let blockReason = configured
            ? nil
            : MCPService.installBlockReason(transport: primary?.transport ?? "stdio", to: source)
        let installable = !configured && blockReason == nil
        VStack(spacing: 4) {
            SourceBadge(source: source, size: 22)
                .opacity(configured ? 1 : (installable ? 0.6 : 0.28))
            Text(source.displayName)
                .font(Theme.font.themed(9))
                .foregroundStyle(configured ? .secondary : .tertiary)
            if configured {
                Text(L10n.text("Configured", zhHans: "已配置"))
                    .font(Theme.font.themed(8, .medium))
                    .foregroundStyle(.green)
            } else if installable {
                Text(L10n.text("Install", zhHans: "安装"))
                    .font(Theme.font.themed(8, .semibold))
                    .foregroundStyle(Theme.brandFg)
            } else {
                Text(L10n.text("Not writable", zhHans: "不可写"))
                    .font(Theme.font.themed(8, .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(configured ? Theme.brandFill(0.08) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    configured ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                    lineWidth: configured ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture {
            guard installable else { return }
            installTarget = source
        }
        .help(configured
            ? L10n.format("%@ already has this server", zhHans: "%@ 已配置该 server", String(source.displayName))
            : (blockReason ?? L10n.format("Write this server into %@’s MCP config", zhHans: "把该 server 写入 %@ 的 MCP 配置", String(source.displayName))))
    }

    private func runInstall() {
        guard let installTo = installTarget, let primary else { return }
        installTarget = nil
        let targetName = installTo.displayName
        installNote = L10n.format("Installing into %@…", zhHans: "正在安装到 %@…", String(targetName))
        service.propagate(primary, to: [installTo]) { results in
            if let failure = results[installTo] ?? nil {
                installNote = L10n.format("Install into %@ failed: %@", zhHans: "安装到 %@ 失败：%@", String(targetName), String(failure))
            } else {
                installNote = L10n.format("Installed into %@ (backup kept before writing)", zhHans: "已安装到 %@（写前留有备份）", String(targetName))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { installNote = nil }
        }
    }

    /// 项目级瓦片：不属于任何单一 agent（claude 的 .mcp.json 是 MCP 官方项目标准，
    /// cursor 有同构约定）；已配置过也允许再装到别的 repo，所以始终可点
    private var projectMatrixTile: some View {
        let projectConfigured = entries.contains { $0.projectName != nil }
        return VStack(spacing: 4) {
            Image(systemName: projectConfigured ? "folder.fill.badge.checkmark" : "folder.badge.plus")
                .font(.system(size: 12))
                .foregroundStyle(projectConfigured ? .secondary : Theme.brandFg.opacity(0.8))
            Text(L10n.text("Project", zhHans: "项目级"))
                .font(Theme.font.themed(9))
                .foregroundStyle(.secondary)
            Text(projectConfigured ? L10n.text("Configured", zhHans: "已配置") : L10n.text("Install", zhHans: "安装"))
                .font(Theme.font.themed(8, projectConfigured ? .medium : .semibold))
                .foregroundStyle(projectConfigured ? .green : Theme.brandFg)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(projectConfigured ? Theme.brandFill(0.08) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(
                    projectConfigured ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                    lineWidth: projectConfigured ? 1 : 0.5))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        .onTapGesture { projectSheet = true }
        .help(projectConfigured
            ? L10n.text("Already in some repos; open to install into another project", zhHans: "已装到某些 repo；点开可再装到其它项目")
            : L10n.text("Write this server into the selected repo’s .mcp.json (shared with the project)", zhHans: "把该 server 写入所选 repo 的 .mcp.json（随项目共享）"))
    }

    /// repo 选择 sheet：最近项目（扫描实勘的根）+ 浏览兜底
    private var projectInstallSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.format("Install “%@” into a project", zhHans: "安装「%@」到项目", String(serverName)))
                .font(Theme.font.themed(13, .semibold))
            HStack(spacing: 6) {
                Menu {
                    ForEach(service.repoRoots, id: \.root) { candidate in
                        Button(candidate.name.isEmpty
                            ? candidate.root.lastPathComponent
                            : L10n.format("%@ (%@)", zhHans: "%@（%@）", String(candidate.name), String(candidate.root.lastPathComponent))) {
                            projectRootPath = candidate.root.path
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(projectRootPath.isEmpty
                            ? L10n.text("Choose a project", zhHans: "选择项目") : String(projectRootPath.split(separator: "/").last ?? ""))
                            .lineLimit(1)
                    }
                    .font(Theme.font.themed(11))
                    .frame(maxWidth: 200)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button(L10n.text("Browse…", zhHans: "浏览…")) {
                    if let picked = mcpPickProjectRoot() { projectRootPath = picked }
                }
                .font(Theme.font.themed(11))
                Spacer()
            }
            if !projectRootPath.isEmpty {
                Text("\(projectRootPath)/.mcp.json")
                    .font(Theme.font.monoSkillName(9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            Toggle(isOn: $projectCursorToo) {
                Text(L10n.text("Also write Cursor’s project config (.cursor/mcp.json)", zhHans: "同时写 cursor 的项目配置（.cursor/mcp.json）"))
                    .font(Theme.font.themed(11))
            }
            .toggleStyle(.checkbox)
            HStack {
                Button(L10n.text("Cancel", zhHans: "取消")) { projectSheet = false }
                    .font(Theme.font.themed(11))
                Spacer()
                Button {
                    runProjectInstall()
                } label: {
                    Text(L10n.text("Write .mcp.json", zhHans: "写入 .mcp.json"))
                        .font(Theme.font.themed(11, .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(projectRootPath.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 400)
    }

    private func runProjectInstall() {
        guard let primary else { return }
        projectSheet = false
        var sources: [AgentSource] = [.claude]
        if projectCursorToo { sources.append(.cursor) }
        let root = URL(fileURLWithPath:
            projectRootPath.trimmingCharacters(in: .whitespaces))
        installNote = L10n.text("Installing at project level…", zhHans: "正在安装到项目级…")
        service.propagateToProject(primary, sources: sources, projectRoot: root) { results in
            let failures = results.sorted(by: { $0.key.rawValue < $1.key.rawValue })
                .compactMap { source, error in
                    error.map { L10n.format("Project %@: %@", zhHans: "项目级 %@：%@", String(source.displayName), String($0)) }
                }
            installNote = failures.isEmpty
                ? L10n.text("Installed into the project (backup kept before writing)", zhHans: "已安装到项目（写前留有备份）")
                : L10n.text("Install failed — ", zhHans: "安装失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { installNote = nil }
        }
    }

    // MARK: 各处配置

    private var occurrencesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("Where it’s configured", zhHans: "各处配置"))
                Text(L10n.text("· click a row to edit that definition", zhHans: "· 点击某行可编辑该处定义"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
            }
            KnowledgeListContainer {
                VStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        occurrenceRow(entry)
                        if index < entries.count - 1 {
                            Divider().opacity(0.4).padding(.leading, 44)
                        }
                    }
                }
            }
        }
    }

    private func occurrenceRow(_ entry: MCPServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                SourceLogoTile(source: entry.source, size: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(entry.source.displayName)
                            .font(Theme.font.themed(12, .medium))
                        TagChip(entry.projectName ?? L10n.text("Global", zhHans: "全局"),
                                neutral: entry.projectName == nil)
                        if entry.enabled == false {
                            TagChip(L10n.text("Disabled", zhHans: "已停用"), tint: Theme.failureRed)
                        }
                        probeChip(for: entry)
                    }
                    Text(entry.configPath)
                        .font(Theme.font.monoSkillName(9, weight: .regular))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                CardActionButton(icon: "square.and.pencil", help: L10n.text("Edit this definition", zhHans: "编辑该处定义")) {
                    onEdit(entry)
                }
                CardActionButton(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) {
                    service.reveal(path: entry.configPath)
                }
                CardActionButton(icon: "trash", color: Theme.failureRed,
                                 help: L10n.text("Remove from this config (backup before writing)", zhHans: "从该配置移除（写前留备份）")) {
                    onDeleteEntry(entry)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onEdit(entry) }
        .help(L10n.text("Click to edit this definition", zhHans: "点击编辑该处定义"))
    }

    /// 状态 chip：检测中 → spinner；否则显示**持久化快照**（重启不丢，v2.6 直显）；
    /// 超过 7 天附「已过期」提示（相对时间本就带"几天前"）
    @ViewBuilder
    private func probeChip(for entry: MCPServerEntry) -> some View {
        if service.probeResults[entry.id] == .checking {
            ProgressView().controlSize(.small).scaleEffect(0.6)
        } else if let snapshot = service.probeSnapshots[entry.id] {
            TagChip(snapshot.label, tint: mcpToneColor(snapshot.tone))
            Text(relativeFormatter.localizedString(for: snapshot.checkedAt, relativeTo: Date())
                + (mcpSnapshotStale(snapshot) ? L10n.text(" · expired", zhHans: " · 已过期") : ""))
                .font(Theme.font.themed(9))
                .foregroundStyle(.tertiary)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(Theme.font.themed(10, .semibold))
            .foregroundStyle(.secondary)
    }
}

// MARK: - 滑入表单（新建 / 粘贴 JSON 导入）

struct MCPFormTarget: Identifiable {
    enum Mode { case quick, form, paste }
    let id: String
    var mode: Mode
    /// 非 nil = 编辑既有配置处（名称与写入位置锁定，字段预填现值）
    var editing: MCPServerEntry? = nil
    /// true = 从「编辑请求头/环境变量」进来：对应折叠区强制展开（即使还没有键）
    var expandCredentials: Bool = false
}

private struct MCPServerFormView: View {
    @ObservedObject var service: MCPService
    let target: MCPFormTarget
    let onBack: () -> Void

    private struct KVRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    @State private var mode: MCPFormTarget.Mode = .form
    @State private var loaded = false

    // 表单模式
    @State private var name = ""
    @State private var isRemote = false
    @State private var command = ""
    @State private var argsText = ""
    @State private var urlText = ""
    @State private var timeoutText = ""
    @State private var envRows: [KVRow] = []
    @State private var headerRows: [KVRow] = []
    @State private var envExpanded = false
    @State private var headersExpanded = false

    // 快速安装：一个输入框通吃 命令 / URL / JSON（自动识别、名称自动派生）
    @State private var quickText = ""

    // JSON 模式（与表单双向同步：切换页签时互相灌值）
    @State private var pasteText = ""

    // 共用
    @State private var selectedTargets: Set<AgentSource> = []
    // 项目级安装（新建模式）：选 repo + 约定（claude .mcp.json 必选、cursor 可选）
    @State private var projectInstall = false
    @State private var projectRootPath = ""
    @State private var projectCursorToo = false
    @State private var resultNote: String?
    @State private var submitting = false

    /// 编辑模式：名称与写入位置锁定，字段预填现值
    private var isEditing: Bool { target.editing != nil }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(isEditing
                        ? L10n.text("Saving rewrites this config in place, keeps fields this form doesn’t model, and backs up first.", zhHans: "修改后保存：原位改写该处配置，未建模字段保留，写前留备份。")
                        : (mode == .quick
                            ? L10n.text("Paste a command, URL, or JSON. It’s recognized and installed into the selected agents.", zhHans: "粘贴命令、URL 或 JSON，自动识别并安装到所选 agent。")
                            : (mode == .form
                                ? L10n.text("Set the name, command/URL, environment, and headers yourself.", zhHans: "手动配置名称、命令/URL、环境变量与请求头。")
                                : L10n.text("Paste or edit mcpServers JSON. Every server in it is written to the selected targets.", zhHans: "粘贴或编辑 mcpServers JSON；多个 server 会全部写入所选目标。"))))
                        .font(Theme.font.themed(11))
                        .foregroundStyle(.secondary)
                    card
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.surfaceSecondary)
        }
        .onAppear { hydrate() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L10n.text("Back", zhHans: "返回")).font(Theme.font.themed(11))
                }
            }
            .buttonStyle(.borderless)
            MCPIconTile(size: 22)
            Text(isEditing
                ? L10n.format("Edit %@", zhHans: "编辑 %@", String(target.editing?.name ?? ""))
                : L10n.text("New MCP Server", zhHans: "新建 MCP Server"))
                .font(Theme.font.themed(13, .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            // 三页签互通（对照 ZCode）：快速安装 / 手动配置 / JSON，切换时互相灌值；
            // 编辑态没有"快速安装"（定义已存在）
            CapsuleTabTray {
                if !isEditing {
                    CapsuleTabButton(
                        title: L10n.text("Quick install", zhHans: "快速安装"), fillWidth: false, isSelected: mode == .quick
                    ) {
                        switchMode(.quick)
                    }
                }
                CapsuleTabButton(title: L10n.text("Manual setup", zhHans: "手动配置"), fillWidth: false, isSelected: mode == .form) {
                    switchMode(.form)
                }
                CapsuleTabButton(title: "JSON", fillWidth: false, isSelected: mode == .paste) {
                    switchMode(.paste)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 卡片（ZCode 式：标签在上、示例占位、可选项折叠）

    private var card: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 快速安装无名称输入（名称自动派生，想改名切「手动配置」）
            if mode != .quick {
                fieldColumn(L10n.text("Name", zhHans: "名称")) {
                    TextField("my-mcp-server", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.font.monoSkillName(12, weight: .regular))
                        .disabled(isEditing)  // 改名 = 删 + 建（同 Codex profile 规矩）
                        .frame(maxWidth: 320)
                }
            }
            if let entry = target.editing { lockedLocationRow(entry) }

            if mode == .quick {
                quickFields
            } else if mode == .form {
                formFields
            } else {
                jsonEditor
            }

            if !isEditing { targetsBlock }

            if let note = resultNote {
                Text(note).font(Theme.font.themed(10.5)).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button(isEditing ? L10n.text("Save changes", zhHans: "保存修改") : L10n.text("Add", zhHans: "添加")) { submit() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .disabled(!canSubmit || submitting)
                Button(L10n.text("Cancel", zhHans: "取消"), action: onBack)
                    .buttonStyle(.borderless)
                Spacer(minLength: 12)
                Text(footerHint)
                    .font(Theme.font.monoSkillName(9, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface)
                .themeCardShadow())
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
    }

    /// 标签在上的字段列（ZCode 式）
    private func fieldColumn<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(Theme.font.themed(11, .medium))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func lockedLocationRow(_ entry: MCPServerEntry) -> some View {
        fieldColumn(L10n.text("Write location (locked)", zhHans: "写入位置（锁定）")) {
            HStack(spacing: 8) {
                SourceLogoTile(source: entry.source, size: 20)
                Text(entry.source.displayName).font(Theme.font.themed(12, .medium))
                TagChip(entry.projectName ?? L10n.text("Global", zhHans: "全局"), neutral: entry.projectName == nil)
                Text(entry.configPath)
                    .font(Theme.font.monoSkillName(9, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var formFields: some View {
        fieldColumn(L10n.text("Type", zhHans: "类型")) {
            Picker("", selection: $isRemote) {
                Text(L10n.text("stdio (local command)", zhHans: "stdio（本地命令）")).tag(false)
                Text(L10n.text("Remote (HTTP/SSE)", zhHans: "远程（HTTP/SSE）")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
        }
        if isRemote {
            fieldColumn("URL") {
                TextField("https://mcp.example.com/mcp", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
            }
            fieldColumn(L10n.text("Timeout ms (optional)", zhHans: "超时时间 MS（可选）")) {
                TextField("30000", text: $timeoutText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
                    .frame(maxWidth: 200)
            }
            kvDisclosure(L10n.text("Headers (optional)", zhHans: "请求头（可选）"), rows: $headerRows, expanded: $headersExpanded,
                         keyPlaceholder: "Authorization", valuePlaceholder: "Bearer …",
                         addLabel: L10n.text("Add header", zhHans: "添加请求头"))
        } else {
            fieldColumn(L10n.text("Command", zhHans: "命令")) {
                TextField("npx", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
                    .frame(maxWidth: 320)
            }
            fieldColumn(L10n.text("Arguments (space-separated)", zhHans: "参数（空格分隔）")) {
                TextField("-y @modelcontextprotocol/server-memory", text: $argsText)
                    .textFieldStyle(.roundedBorder)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
            }
            kvDisclosure(L10n.text("Environment (optional)", zhHans: "环境变量（可选）"), rows: $envRows, expanded: $envExpanded,
                         keyPlaceholder: "API_KEY", valuePlaceholder: L10n.text("Value (written only to the target config; Eureka does not keep it)", zhHans: "值（只写入目标配置，Eureka 不保存）"),
                         addLabel: L10n.text("Add variable", zhHans: "添加环境变量"))
        }
    }

    private func kvDisclosure(
        _ title: String, rows: Binding<[KVRow]>, expanded: Binding<Bool>,
        keyPlaceholder: String, valuePlaceholder: String, addLabel: String
    ) -> some View {
        DisclosureGroup(isExpanded: expanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { $row in
                    HStack(spacing: 8) {
                        TextField(keyPlaceholder, text: $row.key)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.monoSkillName(11.5, weight: .regular))
                            .frame(width: 220)
                        TextField(valuePlaceholder, text: $row.value)
                            .textFieldStyle(.roundedBorder)
                            .font(Theme.font.monoSkillName(11.5, weight: .regular))
                        Button {
                            rows.wrappedValue.removeAll { $0.id == row.id }
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.text("Delete this row", zhHans: "删除该行"))
                    }
                }
                Button {
                    rows.wrappedValue.append(KVRow())
                    expanded.wrappedValue = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle").font(.system(size: 11))
                        Text(addLabel).font(Theme.font.themed(11))
                    }
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.font.themed(11, .medium)).foregroundStyle(.secondary)
                if !rows.wrappedValue.isEmpty {
                    Text("\(rows.wrappedValue.count)")
                        .font(Theme.font.themedMono(9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 快速安装（一框通吃 命令 / URL / JSON）

    private var parsedQuick: [MCPServerDefinition] {
        MCPServerEditor.parseQuickInput(quickText)
    }

    @ViewBuilder
    private var quickFields: some View {
        fieldColumn(L10n.text("Command, URL, or JSON", zhHans: "命令、URL 或 JSON")) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $quickText)
                    .font(Theme.font.monoSkillName(12, weight: .regular))
                    .frame(minHeight: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                if quickText.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(verbatim: "npx -y chrome-devtools-mcp@latest")
                        Text(verbatim: L10n.text("or https://example.com/mcp", zhHans: "或 https://example.com/mcp"))
                        Text(verbatim: L10n.text("or a whole {\"mcpServers\": …} JSON", zhHans: "或整段 {\"mcpServers\": …} JSON"))
                    }
                    .font(Theme.font.monoSkillName(12, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 12)
                    .padding(.leading, 11)
                    .allowsHitTesting(false)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surfaceSecondary))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        let defs = parsedQuick
        Text(quickText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("Paste a command, URL, or JSON to install. For a custom name, environment, or headers, switch to Manual setup.", zhHans: "粘贴命令、URL 或 JSON 即可安装；需要自定义名称、环境变量或请求头时，切到「手动配置」。")
            : (defs.isEmpty
                ? L10n.text("No server parsed — check that the input is complete", zhHans: "没有解析出 server —— 检查输入是否完整")
                : (defs.count == 1
                    ? L10n.format("Will install as “%@” (%@) — the name is derived automatically. Switch to Manual setup to change it.", zhHans: "将安装为「%@」（%@）—— 名称自动派生，可切到「手动配置」调整", String(defs[0].name), String(defs[0].transport == .remote ? L10n.text("remote", zhHans: "远程") : "stdio"))
                    : L10n.format("Parsed %@ servers: %@", zhHans: "解析出 %@ 个 server：%@", String(defs.count), String(defs.map(\.name).joined(separator: L10n.text(", ", zhHans: "、")))))))
            .font(Theme.font.themed(9.5))
            .foregroundStyle(defs.isEmpty && !quickText.isEmpty
                ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        HStack(spacing: 6) {
            TagChip(L10n.text("Transport detected automatically", zhHans: "自动识别传输方式"), neutral: true)
            TagChip(L10n.text("Name derived automatically", zhHans: "名称自动派生"), neutral: true)
            TagChip(L10n.text("Backup before writing", zhHans: "写前自动备份"), neutral: true)
        }
    }

    // MARK: - JSON 模式（与表单同步）

    @ViewBuilder
    private var jsonEditor: some View {
        fieldColumn(L10n.text("JSON (a whole mcpServers object is fine; every server is written to the selected targets)", zhHans: "JSON（支持整段 mcpServers 对象；多个 server 会全部写入所选目标）")) {
            TextEditor(text: $pasteText)
                .font(Theme.font.monoSkillName(11.5, weight: .regular))
                .frame(minHeight: 220)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .fill(Theme.surfaceSecondary))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.container)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
        }
        let defs = parsedDefinitions
        Text(pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? L10n.text("Example: {\"mcpServers\": {\"context7\": {\"command\": \"npx\", \"args\": [\"-y\", \"@upstash/context7-mcp\"]}}}", zhHans: "示例：{\"mcpServers\": {\"context7\": {\"command\": \"npx\", \"args\": [\"-y\", \"@upstash/context7-mcp\"]}}}")
            : (defs.isEmpty
                ? L10n.text("No servers parsed — check that the JSON is complete", zhHans: "没有解析出任何 server —— 检查 JSON 是否完整")
                : L10n.format("Parsed %@ servers: %@", zhHans: "解析出 %@ 个 server：%@", String(defs.count), String(defs.map(\.name).joined(separator: L10n.text(", ", zhHans: "、"))))))
            .font(Theme.font.themed(9.5))
            .foregroundStyle(defs.isEmpty && !pasteText.isEmpty
                ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
    }

    /// 页签互通：快速安装/手动配置/JSON 切换时互相灌值
    /// （多 server 时表单只显示第一个，回原页签提交仍写全部）
    private func switchMode(_ new: MCPFormTarget.Mode) {
        guard new != mode else { return }
        switch new {
        case .paste:
            let trimmedQuick = quickText.trimmingCharacters(in: .whitespacesAndNewlines)
            if mode == .quick, trimmedQuick.hasPrefix("{") {
                pasteText = trimmedQuick  // 快速框里本就是 JSON，原样带过去（多 server 不丢）
            } else {
                if mode == .quick, let first = parsedQuick.first {
                    populate(from: first, keepName: false)
                }
                pasteText = renderCurrentJSON()
            }
        case .form:
            let defs = mode == .quick ? parsedQuick : parsedDefinitions
            if let first = defs.first {
                populate(from: first, keepName: isEditing)
                if defs.count > 1 {
                    resultNote = L10n.format("Parsed %@ servers. The form shows only the first; submit from the original tab to write all of them.", zhHans: "解析出 %@ 个 server，表单只显示第一个；回原页签提交可全部写入", String(defs.count))
                }
            } else if mode == .paste,
                      !pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                resultNote = L10n.text("JSON did not parse into a server; the form was left unchanged", zhHans: "JSON 未解析出 server，保留原表单内容")
            }
        case .quick:
            break  // 快速输入框保持用户原文
        }
        mode = new
    }

    private func renderCurrentJSON() -> String {
        let definition = formDefinition()
        let hasBody = definition.command != nil || definition.url != nil
        guard hasBody || !definition.name.isEmpty else {
            return """
            {
              "mcpServers": {
                "my-mcp-server": {
                  "command": "npx",
                  "args": ["-y", "@modelcontextprotocol/server-memory"]
                }
              }
            }
            """
        }
        let key = definition.name.isEmpty ? "my-mcp-server" : definition.name
        let object: [String: Any] = [
            "mcpServers": [key: MCPServerEditor.encode(definition, style: .typed)]
        ]
        return (try? MCPServerEditor.serialize(object)) ?? "{}"
    }

    private func populate(from definition: MCPServerDefinition, keepName: Bool) {
        if !keepName { name = definition.name }
        isRemote = definition.transport == .remote
        command = definition.command ?? ""
        argsText = definition.args.joined(separator: " ")
        urlText = definition.url ?? ""
        timeoutText = definition.timeout.map(String.init) ?? ""
        envRows = definition.env.keys.sorted().map {
            KVRow(key: $0, value: definition.env[$0] ?? "")
        }
        headerRows = definition.headers.keys.sorted().map {
            KVRow(key: $0, value: definition.headers[$0] ?? "")
        }
        envExpanded = !envRows.isEmpty
        headersExpanded = !headerRows.isEmpty
    }

    private func hydrate() {
        guard !loaded else { return }
        loaded = true
        mode = target.mode
        guard let entry = target.editing else { return }
        name = entry.name
        // 预填现值（含 env/headers）：编辑必须见值——不扩大暴露面（详情页本就有
        // "用默认编辑器打开配置文件"可见整份明文）；值仍不落库、不进日志、不上云。
        service.definition(of: entry) { definition in
            guard let definition else {
                resultNote = L10n.text("Couldn’t read the existing definition", zhHans: "读取现有定义失败")
                return
            }
            populate(from: definition, keepName: true)
            if target.expandCredentials {
                if isRemote { headersExpanded = true } else { envExpanded = true }
            }
        }
    }

    // MARK: - 作用域 / 目标

    private var availableTargets: [AgentSource] { MCPService.writableSources }

    private var targetsBlock: some View {
        fieldColumn(L10n.text("Install into (select one or more)", zhHans: "安装到（可多选）")) {
            VStack(alignment: .leading, spacing: 6) {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(availableTargets, id: \.self) { source in
                        targetChip(source)
                    }
                    projectChip
                }
                if projectInstall { projectPicker }
                if !selectedTargets.isEmpty {
                    Text(selectedTargets
                        .compactMap { MCPService.writableTarget(for: $0)?.configURL.path }
                        .sorted()
                        .joined(separator: "\n"))
                        .font(Theme.font.monoSkillName(9, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 项目级安装开关（随 repo 共享的 .mcp.json，MCP 官方项目标准）
    private var projectChip: some View {
        Button { projectInstall.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 10))
                Text(L10n.text("Project (.mcp.json)", zhHans: "项目级（.mcp.json）"))
                    .font(Theme.font.themed(11, projectInstall ? .semibold : .regular))
                if projectInstall {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(projectInstall ? Theme.brandFill(0.14) : Theme.surface))
            .overlay(Capsule().strokeBorder(
                projectInstall ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                lineWidth: projectInstall ? 1 : 0.5))
        }
        .buttonStyle(.plain)
        .help(L10n.text("Writes .mcp.json at the repo root and shares it with the project (the Claude convention). Cursor’s project config can be written too.", zhHans: "写入仓库根的 .mcp.json，随项目共享（claude 约定）；可一并写 cursor 的项目配置"))
    }

    /// repo 选择：最近项目（扫描实勘的根）+ 浏览兜底；cursor 项目配置可选
    private var projectPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Menu {
                    ForEach(service.repoRoots, id: \.root) { candidate in
                        Button(candidate.name.isEmpty
                            ? candidate.root.lastPathComponent
                            : L10n.format("%@ (%@)", zhHans: "%@（%@）", String(candidate.name), String(candidate.root.lastPathComponent))) {
                            projectRootPath = candidate.root.path
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 9))
                        Text(projectRootPath.isEmpty
                            ? L10n.text("Choose a project", zhHans: "选择项目") : String(projectRootPath.split(separator: "/").last ?? ""))
                            .lineLimit(1)
                    }
                    .font(Theme.font.themed(11))
                    .frame(maxWidth: 180)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button(L10n.text("Browse…", zhHans: "浏览…")) { browseProjectRoot() }
                    .font(Theme.font.themed(11))
                Spacer()
            }
            if !projectRootPath.isEmpty {
                Text("""
                \(projectRootPath)/.mcp.json\(projectCursorToo
                    ? "\n\(projectRootPath)/.cursor/mcp.json" : "")
                """)
                    .font(Theme.font.monoSkillName(9, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            Toggle(isOn: $projectCursorToo) {
                Text(L10n.text("Also write Cursor’s project config (.cursor/mcp.json)", zhHans: "同时写 cursor 的项目配置（.cursor/mcp.json）"))
                    .font(Theme.font.themed(11))
            }
            .toggleStyle(.checkbox)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.radius.container).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius.container)
            .strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }

    private func browseProjectRoot() {
        if let picked = mcpPickProjectRoot() { projectRootPath = picked }
    }

    private func targetChip(_ source: AgentSource) -> some View {
        let isSelected = selectedTargets.contains(source)
        return Button {
            if isSelected {
                selectedTargets.remove(source)
            } else {
                selectedTargets.insert(source)
            }
        } label: {
            HStack(spacing: 5) {
                SourceBadge(source: source, size: 12)
                Text(source.displayName)
                    .font(Theme.font.themed(11, isSelected ? .semibold : .regular))
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.brandFg)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(isSelected ? Theme.brandFill(0.14) : Theme.surface))
            .overlay(Capsule().strokeBorder(
                isSelected ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                lineWidth: isSelected ? 1 : 0.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 提交

    private var footerHint: String {
        if let entry = target.editing {
            return L10n.format("Rewrite in place %@", zhHans: "原位改写 %@", String(entry.configPath))
        }
        let globalCount = selectedTargets.count
        if validProjectInstall {
            return globalCount == 0
                ? L10n.text("Write project .mcp.json (backup before writing)", zhHans: "写入项目级 .mcp.json（写前留备份）")
                : L10n.format("Write global config for %@ agents plus project .mcp.json (backup each before writing)", zhHans: "写入 %@ 个 agent 的全局配置 + 项目级 .mcp.json（写前各留备份）", String(globalCount))
        }
        if selectedTargets.isEmpty { return L10n.text("Select at least one target agent", zhHans: "选择至少一个目标 agent") }
        return L10n.format("Write global config for %@ agents (backup each before writing)", zhHans: "写入 %@ 个 agent 的全局配置（写前各留备份）", String(globalCount))
    }

    /// 项目级安装有效 = 开关开 + repo 根路径非空
    private var validProjectInstall: Bool {
        projectInstall && !projectRootPath.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var canSubmit: Bool {
        if mode == .quick {
            return !parsedQuick.isEmpty && hasAnyTarget
        }
        if mode == .paste {
            guard !parsedDefinitions.isEmpty else { return false }
            return isEditing || hasAnyTarget
        }
        let hasName = !name.trimmingCharacters(in: .whitespaces).isEmpty
        let hasBody = isRemote
            ? !urlText.trimmingCharacters(in: .whitespaces).isEmpty
            : !command.trimmingCharacters(in: .whitespaces).isEmpty
        if isEditing { return hasName && hasBody }
        return hasName && hasBody && hasAnyTarget
    }

    private var hasAnyTarget: Bool { !selectedTargets.isEmpty || validProjectInstall }

    private var parsedDefinitions: [MCPServerDefinition] {
        MCPServerEditor.parsePasted(pasteText)
    }

    private func formDefinition() -> MCPServerDefinition {
        func pairs(_ rows: [KVRow]) -> [String: String] {
            var result: [String: String] = [:]
            for row in rows where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
                result[row.key.trimmingCharacters(in: .whitespaces)] = row.value
            }
            return result
        }
        let args = argsText.split(separator: " ").map(String.init)
        return MCPServerDefinition(
            name: name.trimmingCharacters(in: .whitespaces),
            transport: isRemote ? .remote : .stdio,
            command: isRemote ? nil : command.trimmingCharacters(in: .whitespaces),
            args: isRemote ? [] : args,
            env: isRemote ? [:] : pairs(envRows),
            url: isRemote ? urlText.trimmingCharacters(in: .whitespaces) : nil,
            headers: isRemote ? pairs(headerRows) : [:],
            timeout: isRemote
                ? Int(timeoutText.trimmingCharacters(in: .whitespaces))
                : nil)
    }

    private func submit() {
        submitting = true
        resultNote = L10n.text("Writing…", zhHans: "正在写入…")
        // 编辑：原位改写该条目所在配置（JSON 模式也支持——取首个 server、名称强制回原名）
        if let entry = target.editing {
            var definition = mode == .form
                ? formDefinition()
                : (parsedDefinitions.first ?? formDefinition())
            definition.name = entry.name
            service.update(entry, definition: definition) { failure in
                submitting = false
                if let failure {
                    resultNote = L10n.format("Save failed: %@", zhHans: "保存失败：%@", String(failure))
                } else {
                    onBack()
                }
            }
            return
        }
        let definitions: [MCPServerDefinition]
        switch mode {
        case .form: definitions = [formDefinition()]
        case .quick: definitions = parsedQuick
        case .paste: definitions = parsedDefinitions
        }
        guard !definitions.isEmpty else {
            submitting = false
            return
        }
        // 全局目标 + 项目级目标并行推进，结果统一聚合（项目级单列前缀防同名源混淆）
        var projectSources: [AgentSource] = [.claude]
        if projectCursorToo { projectSources.append(.cursor) }
        let useProject = validProjectInstall
        let projectRoot = URL(fileURLWithPath:
            projectRootPath.trimmingCharacters(in: .whitespaces))
        service.addAll(definitions: definitions, to: Array(selectedTargets)) { global in
            guard useProject else {
                reportInstallResults(global: global, project: nil)
                return
            }
            service.installToProject(
                definitions: definitions, sources: projectSources, projectRoot: projectRoot
            ) { project in
                reportInstallResults(global: global, project: project)
            }
        }
    }

    private func reportInstallResults(
        global: [AgentSource: String?], project: [AgentSource: String?]?
    ) {
        submitting = false
        var failures: [String] = []
        for (source, error) in global.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            if let error { failures.append(L10n.format("%@: %@", zhHans: "%@：%@", String(source.displayName), String(error))) }
        }
        if let project {
            for (source, error) in project.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let error { failures.append(L10n.format("Project %@: %@", zhHans: "项目级 %@：%@", String(source.displayName), String(error))) }
            }
        }
        if failures.isEmpty {
            onBack()
        } else {
            resultNote = L10n.text("Partial failure — ", zhHans: "部分失败 —— ") + failures.joined(separator: L10n.text("; ", zhHans: "；"))
        }
    }
}
