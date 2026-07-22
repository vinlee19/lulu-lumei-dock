import EurekaIngest
import EurekaKit
import SwiftUI

/// 会话管理两栏：左 = 会话列表（搜索/来源 chips/排序：扁平三档 + 项目分组视图/多选/刷新），
/// 右 = 会话详情（对话记录 + 对话目录，见 SessionDetailView）。
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService
    @ObservedObject var settings: AppSettings
    /// 项目视图中手动收起的分组（默认全展开）
    @State private var collapsed: Set<String> = []
    /// 多选模式与选中集合（存 session id）
    @State private var multiSelect = false
    @State private var checkedIds: Set<String> = []
    @State private var confirmingBatchDelete = false
    /// 搜索框聚焦态（驱动紫金渐变描边）
    @FocusState private var searchFocused: Bool
    /// 来源选择 popover 开关
    @State private var showSourcePicker = false

    private var limitLabel: String {
        settings.sessionDisplayLimit == 0 ? "全部" : "最近 \(settings.sessionDisplayLimit)"
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            SessionDetailView(service: service)
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear {
            service.displayLimit = settings.sessionDisplayLimit
            if let mode = SessionBrowserService.SortMode(rawValue: settings.sessionSortMode) {
                service.sortMode = mode
            }
            service.refresh()
        }
        .onChange(of: settings.sessionDisplayLimit) { _, newValue in
            service.displayLimit = newValue
        }
        .onChange(of: service.sortMode) { _, newValue in
            settings.sessionSortMode = newValue.rawValue
        }
        .confirmationDialog(
            "删除选中的 \(deletableChecked.count) 个会话？transcript 文件会移入废纸篓，可恢复。",
            isPresented: $confirmingBatchDelete, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                service.deleteSessions(deletableChecked)
                checkedIds = []
                multiSelect = false
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 选中且可删（opencode 不可删）的会话
    private var deletableChecked: [AgentSessionInfo] {
        allVisibleSessions.filter {
            checkedIds.contains($0.id) && $0.source != .opencode
        }
    }

    private var allVisibleSessions: [AgentSessionInfo] {
        service.flatSessions + service.groups.flatMap(\.sessions)
    }

    // MARK: - 左栏

    private var listPane: some View {
        VStack(spacing: 0) {
            // 账本总览 + 展示数量
            HStack(spacing: 6) {
                Text("共 \(service.summary.sessionCount) 个会话")
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
                Text("·").foregroundStyle(.tertiary)
                Text(formatBytes(service.summary.totalBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if let cost = service.summary.totalCostUSD {
                    Text("·").foregroundStyle(.tertiary)
                    Text("≈\(formatCost(cost))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.cost)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                // 展示数量下拉（胶囊盒，同来源下拉风格）
                Menu {
                    ForEach([10, 20, 50], id: \.self) { n in
                        Button("最近 \(n) 个") { settings.sessionDisplayLimit = n }
                    }
                    Button("全部") { settings.sessionDisplayLimit = 0 }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text(limitLabel)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("最多展示多少个会话")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            // 搜索面板（来源筛选内嵌右端；聚焦时紫金渐变描边）+ 圆形工具按钮
            HStack(spacing: 6) {
                searchPanel
                toolButton(
                    icon: "checkmark",
                    tint: .green,
                    active: multiSelect,
                    help: "多选模式（批量删除）"
                ) {
                    multiSelect.toggle()
                    if !multiSelect { checkedIds = [] }
                }
                toolButton(icon: "arrow.clockwise", tint: .teal, help: "重新索引会话") {
                    service.refresh()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // 排序 / 视图（前三档扁平列表，「项目」按项目分组）；胶囊页签 + 侧边栏式彩色图标块
            CapsuleTabTray {
                ForEach(SessionBrowserService.SortMode.allCases, id: \.self) { mode in
                    CapsuleTabButton(
                        title: mode.label,
                        icon: mode.icon,
                        tileColor: sortTileColor(mode),
                        isSelected: service.sortMode == mode
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            service.sortMode = mode
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            if service.flatSessions.isEmpty && service.groups.isEmpty
                && service.fullTextHits.isEmpty {
                VStack(spacing: 8) {
                    if service.scanning {
                        ProgressView("正在索引会话…")
                    } else {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.brand.opacity(0.45))
                        Text(service.isSearching ? "没有匹配的会话" : "近 30 天没有会话")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // 扁平列表（最近活跃 / 大小 / 时长）：无项目属性
                        ForEach(service.flatSessions) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 12).opacity(0.4)
                        }
                        // 项目视图：分组头 + 组内会话（默认全展开；折叠不做结构动画，
                        // LazyVStack 内结构性 withAnimation 会残留幽灵空白）
                        ForEach(service.groups) { group in
                            let isOpen = service.isSearching || !collapsed.contains(group.id)
                            ProjectHeaderRow(group: group, isExpanded: isOpen) {
                                if collapsed.contains(group.id) {
                                    collapsed.remove(group.id)
                                } else {
                                    collapsed.insert(group.id)
                                }
                            }
                            if isOpen {
                                ForEach(group.sessions) { session in
                                    sessionRow(session)
                                        .padding(.leading, 10)
                                }
                                Divider().padding(.leading, 12)
                            }
                        }
                        if service.isSearching && !service.fullTextHits.isEmpty {
                            fullTextSection
                        }
                    }
                }
                if multiSelect {
                    Divider()
                    HStack {
                        Text("已选 \(checkedIds.count) 个")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("批量删除") { confirmingBatchDelete = true }
                            .controlSize(.small)
                            .tint(.red)
                            .disabled(deletableChecked.isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.surfaceSecondary)
                }
            }
        }
    }

    /// 排序页签图标块底色（同侧边栏调色板）
    private func sortTileColor(_ mode: SessionBrowserService.SortMode) -> Color {
        switch mode {
        case .time: return .blue
        case .size: return .orange
        case .duration: return .indigo
        case .project: return Theme.gold
        }
    }

    /// 搜索面板：搜索框与来源筛选融合为一体（筛选内嵌右端，细分隔线隔开）；
    /// 常驻淡紫金渐变描边区分层次，聚焦时描边点亮 + 品牌色放大镜
    private var searchPanel: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(searchFocused ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
            TextField("搜索会话 / 项目 / id", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($searchFocused)
            if !service.searchText.isEmpty {
                Button {
                    service.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
            Divider().frame(height: 12)
            sourcePickerButton
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4.5)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.brand.opacity(searchFocused ? 1 : 0.45),
                                 Theme.gold.opacity(searchFocused ? 1 : 0.45)],
                        startPoint: .leading, endPoint: .trailing),
                    lineWidth: searchFocused ? 1.2 : 0.8))
        .shadow(color: searchFocused ? Theme.brand.opacity(0.12) : .clear, radius: 4, y: 1)
        .animation(.easeOut(duration: 0.15), value: searchFocused)
        .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) {
            sourcePickerPopover
        }
    }

    /// 彩色工具按钮：侧边栏式彩色圆角图标块；active（多选开启）= 品牌色描边点亮
    private func toolButton(
        icon: String, tint: Color, active: Bool = false,
        help: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 22, height: 22)
                .overlay(
                    Image(systemName: icon)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            active ? Theme.brand : .clear, lineWidth: 1.5))
                .shadow(color: active ? Theme.brand.opacity(0.3) : .clear, radius: 3)
                .opacity(active ? 1 : 0.88)
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// 来源筛选入口（内嵌在搜索面板右端）：彩色筛选图标块 / 选中 CLI 的真实徽标 + 名称。
    /// 点开的是自定义 popover（非 NSMenu），可控样式且不越过左栏分隔线。
    private var sourcePickerButton: some View {
        Button {
            showSourcePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                if let filter = service.sourceFilter {
                    SourceBadge(source: filter, size: 12)
                    Text(filter.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.brand)
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Theme.brand.gradient)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.white))
                    Text("全部来源")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("按 CLI 来源筛选会话")
    }

    /// 来源选择 popover：真实徽标 + 名称 + 计数，选中行品牌底 + 对勾；淡紫金渐变洗底
    private var sourcePickerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourcePickerRow(nil, name: "全部来源", count: service.summary.sessionCount)
            Divider().padding(.vertical, 2)
            ForEach(AgentSource.allCases, id: \.self) { source in
                if let count = service.sourceCounts[source], count > 0 {
                    sourcePickerRow(source, name: source.displayName, count: count)
                }
            }
        }
        .padding(8)
        .frame(width: 210)
        .background(
            LinearGradient(
                colors: [Theme.brand.opacity(0.06), Theme.gold.opacity(0.05)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private func sourcePickerRow(
        _ source: AgentSource?, name: String, count: Int
    ) -> some View {
        let selected = service.sourceFilter == source
        return Button {
            service.sourceFilter = source
            showSourcePicker = false
        } label: {
            HStack(spacing: 7) {
                if let source {
                    SourceBadge(source: source, size: 14)
                } else {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .fill(Theme.brand.gradient)
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(.white))
                }
                Text(name)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.brand)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.brandFill(0.12) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sessionRow(_ session: AgentSessionInfo) -> some View {
        SessionRow(
            session: session,
            cost: service.costs[session.id],
            promptCount: service.promptCounts[session.id],
            service: service,
            isSelected: service.selected?.id == session.id,
            multiSelect: multiSelect,
            isChecked: checkedIds.contains(session.id),
            onToggleCheck: { toggleCheck(session) })
    }

    private func toggleCheck(_ session: AgentSessionInfo) {
        if checkedIds.contains(session.id) {
            checkedIds.remove(session.id)
        } else {
            checkedIds.insert(session.id)
        }
    }

    // MARK: - 全文命中区（对话内容级搜索结果，点击直达消息）

    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.gold)
                Text("对话内容命中")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(service.fullTextHits.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.surfaceSecondary)
            ForEach(service.fullTextHits) { hit in
                Button {
                    service.revealMessage(sessionId: hit.sessionId, messageIdx: hit.messageIdx)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            SourceBadge(source: hit.source, size: 10)
                            Text(hit.sessionName ?? "会话 \(hit.sessionId.prefix(8))")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(hit.role == "user" ? "用户" : "助手")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            if let ts = hit.ts {
                                Text(relativeFormatter.localizedString(for: ts, relativeTo: Date()))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(hit.snippet)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 12).opacity(0.5)
            }
        }
    }
}

/// 项目行：点击展开/收起该项目下的会话
private struct ProjectHeaderRow: View {
    let group: SessionBrowserService.ProjectGroup
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brand.opacity(0.8))
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let cost = group.totalCostUSD {
                    Text("≈\(formatCost(cost))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.cost)
                }
                Text("\(group.sessions.count) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(formatBytes(group.totalBytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Theme.surfaceSecondary : .clear)
    }
}

/// 会话行：点击选中（详情栏加载 transcript）；多选模式带复选框
private struct SessionRow: View {
    let session: AgentSessionInfo
    let cost: SessionBrowserService.SessionCost?
    var promptCount: Int?
    let service: SessionBrowserService
    let isSelected: Bool
    let multiSelect: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if multiSelect {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(session.source == .opencode
                            ? AnyShapeStyle(.tertiary)
                            : (isChecked ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary)))
                }
                .buttonStyle(.borderless)
                .disabled(session.source == .opencode)
                .help(session.source == .opencode ? "OpenCode 会话不支持删除" : "")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    SourceBadge(source: session.source, size: 11)
                    Text(session.displayName)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(relativeFormatter.localizedString(
                        for: session.lastActiveAt, relativeTo: Date()))
                    Text("·")
                    Text(formatBytes(session.sizeBytes))
                    if let promptCount, promptCount > 0 {
                        Text("·")
                        Text("\(promptCount) 段")
                    }
                    if let cost, let usd = cost.costUSD {
                        Text("·")
                        Text(formatCost(usd))
                            .foregroundStyle(Theme.cost)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                service.copyResumeCommand(session)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("拷贝恢复命令")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.brandFill(0.08))
                    // 左侧品牌色指示条（Activity Monitor 式选中态）
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.brand)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            })
        .contentShape(Rectangle())
        .onTapGesture {
            if multiSelect {
                if session.source != .opencode { onToggleCheck() }
            } else {
                service.select(session)
            }
        }
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    switch bytes {
    case ..<1024: return "\(bytes) B"
    case ..<(1024 * 1024): return String(format: "%.0f KB", Double(bytes) / 1024)
    default: return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
