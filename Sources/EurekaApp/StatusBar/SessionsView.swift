import EurekaIngest
import EurekaKit
import SwiftUI

/// 会话管理两栏：左 = 会话列表（搜索/来源 chips/排序：扁平三档 + 项目分组视图/多选/刷新），
/// 右 = 会话详情（对话记录 + 对话目录，见 SessionDetailView）。
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService
    @ObservedObject var settings: AppSettings
    /// 会话「本会话产出」区依赖：全仓只有 PopoverRootView 一处构造点，非 optional 让扫描完成后能正常刷新
    @ObservedObject var skillMemory: SkillMemoryService
    @ObservedObject var plans: PlansService
    /// 项目视图中手动收起的分组（默认全展开）
    @State private var collapsed: Set<String> = []
    /// 多选模式与选中集合（存 session id）
    @State private var multiSelect = false
    @State private var checkedIds: Set<String> = []
    @State private var confirmingBatchDelete = false
    /// 来源选择 popover 开关
    @State private var showSourcePicker = false

    /// 血缘下钻的目标
    enum LineageRoute: Equatable {
        case list
        case graph(turn: Int)
    }

    /// 血缘下钻（nil = 两栏原状）。**替换整个内容区**而不是嵌进右栏：
    /// 右栏最坏只有 ~423pt，图铺不开。样板照 `PlansView` 的 detail 下钻。
    @State private var lineage: LineageRoute?

    var body: some View {
        Group {
            if let route = lineage {
                lineagePane(route)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                twoPane
            }
        }
        // 切会话时退出下钻：新会话的轮次和旧的对不上
        .onChange(of: service.selected?.id) { _, _ in lineage = nil }
        .onChange(of: service.transcriptLoading) { _, loading in
            // 跨页跳「某会话第 N 轮」：transcript 加载完才有轮次可切
            guard !loading, let turn = service.consumePendingTurn() else { return }
            withAnimation(.easeOut(duration: 0.15)) { lineage = .graph(turn: turn) }
        }
    }

    private func lineagePane(_ route: LineageRoute) -> some View {
        let pane: TurnLineageView.Pane
        let turn: Int
        switch route {
        case .list: (pane, turn) = (.list, 0)
        case .graph(let index): (pane, turn) = (.graph, index)
        }
        return TurnLineageView(
            sessionName: service.selected?.displayName ?? "会话",
            turns: TurnSlicer.slice(service.transcript),
            onBack: { withAnimation(.easeOut(duration: 0.15)) { lineage = nil } },
            onJumpToMessage: { messageId in
                // 先收起下钻页让消息流的 LazyVStack 重新挂载，再延迟一拍发通知 ——
                // 沿用 SessionDetailView 已经验证过的 0.15，不发明新数值
                withAnimation(.easeOut(duration: 0.15)) { lineage = nil }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    NotificationCenter.default.post(
                        name: .eurekaJumpToMessage, object: messageId)
                }
            },
            initialPane: pane, initialTurn: turn)
    }

    private var twoPane: some View {
        HSplitView {
            // maxWidth 决定分隔线的可拖行程：420 时只有 170pt，宽窗下拖起来
            // 几乎无感（被反馈"不能调"）；620 在保住详情区 380 底线的前提下放开
            listPane
                // The list is navigation; the transcript is what people read. With the detail
                // pane holding layoutPriority the split opens the list at its minimum, so that
                // minimum *is* the default width: 300pt (~a quarter of the window, down from the
                // ~40% it used to open at), still enough for the sort tray and a one-line row.
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 480)
            SessionDetailView(
                service: service,
                skillMemory: skillMemory,
                plans: plans,
                onOpenLineage: { pane in
                    withAnimation(.easeOut(duration: 0.15)) {
                        lineage = pane == .graph ? .graph(turn: 0) : .list
                    }
                })
                // 375 + the list's 300 = the 675pt content width of the minimum window
                .frame(minWidth: 375, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .onAppear {
            service.rangeAll = settings.sessionRangeAll
            if let mode = SessionBrowserService.SortMode(rawValue: settings.sessionSortMode) {
                service.sortMode = mode
            }
            service.refresh()
        }
        .onChange(of: settings.sessionRangeAll) { _, newValue in
            service.rangeAll = newValue
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

    /// 选中且可删（共享库的 opencode / hermes 不可删）的会话
    private var deletableChecked: [AgentSessionInfo] {
        allVisibleSessions.filter {
            checkedIds.contains($0.id) && $0.source.supportsSessionDeletion
        }
    }

    private var allVisibleSessions: [AgentSessionInfo] {
        service.flatSessions + service.groups.flatMap(\.sessions)
    }

    // MARK: - 左栏

    private var listPane: some View {
        VStack(spacing: 0) {
            // 账本总览（右端常驻索引状态：扫描中可见，重扫不再"无反应"）
            HStack(spacing: 6) {
                Text("共 \(service.summary.sessionCount.formatted()) 个会话")
                    .font(Theme.font.themed(11.5, .semibold))
                    .lineLimit(1)
                    .fixedSize()
                Text("·").foregroundStyle(.tertiary)
                Text(formatBytes(service.summary.totalBytes))
                    .font(Theme.font.themedMono(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                if let cost = service.summary.totalCostUSD {
                    Text("·").foregroundStyle(.tertiary)
                    Text("≈\(formatCost(cost))")
                        .font(Theme.font.themedMono(11, .semibold))
                        .foregroundStyle(Theme.cost)
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 6)
                if service.scanning {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("索引中")
                            .font(Theme.font.themed(10.5))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)
            .animation(.easeOut(duration: 0.15), value: service.scanning)

            // Two rows from the shared kit. The list opens at 300pt, so the search field gets a
            // row to itself (one row squeezed it to ~100pt and cut the placeholder); the source
            // picker and the two round tool buttons share the row below.
            VStack(spacing: 6) {
                SearchField(placeholder: "搜索会话 / 项目 / id", text: $service.searchText, maxWidth: nil)
                HStack(spacing: 6) {
                    sourcePickerButton
                    Spacer(minLength: 6)
                    RoundGlyphButton(
                        icon: "checkmark", active: multiSelect,
                        help: multiSelect ? "退出多选" : "多选模式（批量删除）"
                    ) {
                        multiSelect.toggle()
                        if !multiSelect { checkedIds = [] }
                    }
                    RefreshButton(help: "重新索引会话") { service.refresh() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // 时间范围（近 30 天 / 全部时间）；胶囊页签，与下方排序档同风格，选中紫底白字
            CapsuleTabTray {
                CapsuleTabButton(
                    title: "近 30 天", icon: "clock",
                    isSelected: !settings.sessionRangeAll
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        settings.sessionRangeAll = false
                    }
                }
                CapsuleTabButton(
                    title: "全部时间", icon: "infinity",
                    isSelected: settings.sessionRangeAll
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        settings.sessionRangeAll = true
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .accessibilityLabel("会话时间范围")

            // 排序 / 视图（前三档扁平列表，「项目」按项目分组）；胶囊页签，选中紫底白字
            CapsuleTabTray {
                ForEach(SessionBrowserService.SortMode.allCases, id: \.self) { mode in
                    CapsuleTabButton(
                        title: mode.label,
                        icon: mode.icon,
                        isSelected: service.sortMode == mode
                    ) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            service.sortMode = mode
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Divider()

            if service.flatSessions.isEmpty && service.groups.isEmpty
                && service.fullTextHits.isEmpty {
                VStack(spacing: 8) {
                    if service.scanning {
                        ProgressView("正在索引会话…")
                        Text("14 个来源逐个扫描，稍等片刻")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "archivebox")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.brandFg.opacity(0.4))
                        Text(service.isSearching
                            ? "没有匹配的会话"
                            : (settings.sessionRangeAll ? "没有会话" : "近 30 天没有会话"))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if !service.isSearching && !settings.sessionRangeAll {
                            Text("更早的记录在「全部时间」里")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
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

    /// Source filter entry: a 26pt capsule styled exactly like the round tool buttons beside it
    /// (RoundGlyphButton: ink outline + flat fill + hard shadow in brutal, light brand tint in
    /// classic; solid brand while a filter is active), showing the chosen CLI's logo + name.
    /// Opens a custom popover (not an NSMenu) so the style is ours and it never crosses the
    /// pane divider.
    private var sourcePickerButton: some View {
        let active = service.sourceFilter != nil
        let hard = ThemeStyle.current.isHardEdged
        let fg: Color = active ? Theme.onBrand : (hard ? Theme.ink : Theme.brandFg)
        let fill: AnyShapeStyle = active
            ? AnyShapeStyle(Theme.brand)
            : AnyShapeStyle(hard ? Theme.surface : Theme.brandFill(0.10))
        let stroke: Color = hard ? Theme.ink : (active ? Theme.brand : Theme.brand.opacity(0.35))
        return Button {
            showSourcePicker.toggle()
        } label: {
            HStack(spacing: 5) {
                if let filter = service.sourceFilter {
                    SourceBadge(source: filter, size: 13)
                    Text(filter.displayName)
                        .font(Theme.font.themed(11, .semibold))
                        .lineLimit(1)
                        .fixedSize()
                } else {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 10, weight: .semibold))
                    Text("全部来源")
                        .font(Theme.font.themed(11, .medium))
                        .fixedSize()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(fill).themeControlShadow(active: hard))
            .overlay(
                Capsule().strokeBorder(stroke, lineWidth: hard ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按 CLI 来源筛选会话")
        .popover(isPresented: $showSourcePicker, arrowEdge: .bottom) {
            sourcePickerPopover
        }
    }

    /// Source popover: logo + name + count per row, brand fill and a check on the chosen one
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
                    .font(Theme.font.themed(11, selected ? .semibold : .regular))
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.brandFg) : AnyShapeStyle(.tertiary))
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.brandFg)
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
                    .foregroundStyle(Theme.goldFg)
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
                    .foregroundStyle(Theme.brandFg.opacity(0.8))
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if multiSelect {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(session.source.supportsSessionDeletion
                            ? (isChecked ? AnyShapeStyle(Theme.brandFg) : AnyShapeStyle(.secondary))
                            : AnyShapeStyle(.tertiary))
                }
                .buttonStyle(.borderless)
                .disabled(!session.source.supportsSessionDeletion)
                .help(session.source.supportsSessionDeletion
                    ? "" : "\(session.source.displayName) 会话不支持删除")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    SourceBadge(source: session.source, size: 11)
                    Text(session.displayName)
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                        .help(session.displayName)
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
                    if let terminal = service.terminal(for: session) {
                        TerminalBadge(
                            binding: terminal,
                            isRunning: TerminalActivator.isRunning(terminal))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                // Truncate rather than wrap: a squeezed row used to break "1分钟前" across lines
                .lineLimit(1)
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
                } else if hovering {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04))
                }
            })
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onTapGesture {
            if multiSelect {
                if session.source.supportsSessionDeletion { onToggleCheck() }
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
