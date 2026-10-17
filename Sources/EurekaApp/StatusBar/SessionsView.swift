import EurekaIngest
import EurekaKit
import SwiftUI

/// Two-pane session manager: left = session list (search/source chips/sort: three flat modes +
/// project-grouped view/multi-select/refresh), right = session detail (transcript + outline, see
/// SessionDetailView).
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService
    @ObservedObject var settings: AppSettings
    /// Dependency of the session "produced in this session" section: only PopoverRootView
    /// constructs this; non-optional so the view refreshes once scanning finishes
    @ObservedObject var skillMemory: SkillMemoryService
    @ObservedObject var plans: PlansService
    /// Groups manually collapsed in the project view (all expanded by default)
    @State private var collapsed: Set<String> = []
    /// Multi-select mode and the selected set (session ids)
    @State private var multiSelect = false
    @State private var checkedIds: Set<String> = []
    @State private var confirmingBatchDelete = false
    /// Search field focus state (drives the purple-gold gradient stroke)
    @FocusState private var searchFocused: Bool
    /// Source picker popover toggle
    @State private var showSourcePicker = false

    /// Lineage drill-down target
    enum LineageRoute: Equatable {
        case list
        case graph(turn: Int)
    }

    /// Lineage drill-down (nil = the original two panes). It **replaces the whole content area**
    /// instead of nesting in the right pane: the right pane can be as narrow as ~423pt, too small
    /// for the graph. Modeled on `PlansView`'s detail drill-down.
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
        // Leave the drill-down on session switch: the new session's turns don't match the old ones
        .onChange(of: service.selected?.id) { _, _ in lineage = nil }
        .onChange(of: service.transcriptLoading) { _, loading in
            // Cross-page jump to "turn N of a session": turns only exist once the transcript has
            // loaded
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
            sessionName: service.selected?.displayName ?? L10n.text("Session", zhHans: "会话"),
            turns: TurnSlicer.slice(service.transcript),
            onBack: { withAnimation(.easeOut(duration: 0.15)) { lineage = nil } },
            onJumpToMessage: { messageId in
                // Dismiss the drill-down first so the message stream's LazyVStack remounts, then
                // post the notification a beat later -- reuse the 0.15 already proven in
                // SessionDetailView rather than inventing a new value
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
            // maxWidth sets how far the divider can be dragged: at 420 there was only 170pt, barely
            // noticeable in a wide window (reported as "can't resize"); 620 opens it up while
            // keeping the detail pane's 380 floor
            listPane
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 620)
            SessionDetailView(
                service: service,
                skillMemory: skillMemory,
                plans: plans,
                onOpenLineage: { pane in
                    withAnimation(.easeOut(duration: 0.15)) {
                        lineage = pane == .graph ? .graph(turn: 0) : .list
                    }
                })
                .frame(minWidth: 380, maxWidth: .infinity)
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
            L10n.format(
                "Delete the %@ selected sessions? Transcript files move to the Trash and can be restored.",
                zhHans: "删除选中的 %@ 个会话？transcript 文件会移入废纸篓，可恢复。",
                String(deletableChecked.count)),
            isPresented: $confirmingBatchDelete, titleVisibility: .visible
        ) {
            Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) {
                service.deleteSessions(deletableChecked)
                checkedIds = []
                multiSelect = false
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    /// Sessions that are selected and deletable (shared-database opencode / hermes can't be
    /// deleted)
    private var deletableChecked: [AgentSessionInfo] {
        allVisibleSessions.filter {
            checkedIds.contains($0.id) && $0.source.supportsSessionDeletion
        }
    }

    private var allVisibleSessions: [AgentSessionInfo] {
        service.flatSessions + service.groups.flatMap(\.sessions)
    }

    // MARK: - Left pane

    private var listPane: some View {
        VStack(spacing: 0) {
            // Ledger overview (index status pinned at the right: visible while scanning, so a
            // rescan no longer looks "unresponsive")
            HStack(spacing: 6) {
                Text(L10n.format("%@ sessions", zhHans: "共 %@ 个会话", String(service.summary.sessionCount)))
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
                if service.scanning {
                    HStack(spacing: 4) {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.55)
                        Text(L10n.text("Indexing", zhHans: "索引中"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .fixedSize()
                    }
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 3)
            .animation(.easeOut(duration: 0.15), value: service.scanning)

            // Search panel (source filter embedded at the right; purple-gold gradient stroke when
            // focused) + round tool buttons
            HStack(spacing: 6) {
                searchPanel
                toolButton(
                    icon: "checkmark",
                    tint: .green,
                    active: multiSelect,
                    help: L10n.text("Multi-select (batch delete)", zhHans: "多选模式（批量删除）")
                ) {
                    multiSelect.toggle()
                    if !multiSelect { checkedIds = [] }
                }
                toolButton(icon: "arrow.clockwise", tint: .teal, help: L10n.text("Reindex sessions", zhHans: "重新索引会话")) {
                    service.refresh()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // Time range (last 30 days / all time); capsule tabs in the same style as the sort
            // modes below, selected = purple fill + white text
            CapsuleTabTray {
                CapsuleTabButton(
                    title: L10n.text("Last 30 days", zhHans: "近 30 天"), icon: "clock",
                    isSelected: !settings.sessionRangeAll
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        settings.sessionRangeAll = false
                    }
                }
                CapsuleTabButton(
                    title: L10n.text("All time", zhHans: "全部时间"), icon: "infinity",
                    isSelected: settings.sessionRangeAll
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        settings.sessionRangeAll = true
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            .accessibilityLabel(L10n.text("Session time range", zhHans: "会话时间范围"))

            // Sort / view (first three modes are flat lists, "Project" groups by project); capsule
            // tabs, selected = purple fill + white text
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
                        ProgressView(L10n.text("Indexing sessions…", zhHans: "正在索引会话…"))
                        Text(L10n.text("Scanning 14 sources one by one. This takes a moment.", zhHans: "14 个来源逐个扫描，稍等片刻"))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    } else {
                        Image(systemName: "archivebox")
                            .font(.system(size: 26))
                            .foregroundStyle(Theme.brandFg.opacity(0.4))
                        Text(service.isSearching
                            ? L10n.text("No matching sessions", zhHans: "没有匹配的会话")
                            : (settings.sessionRangeAll
                                ? L10n.text("No sessions", zhHans: "没有会话")
                                : L10n.text("No sessions in the last 30 days", zhHans: "近 30 天没有会话")))
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        if !service.isSearching && !settings.sessionRangeAll {
                            Text(L10n.text("Older records are under All time", zhHans: "更早的记录在「全部时间」里"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Flat list (recently active / size / duration): no project attribute
                        ForEach(service.flatSessions) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 12).opacity(0.4)
                        }
                        // Project view: group header + sessions in the group (all expanded by
                        // default; collapsing isn't animated, structural withAnimation inside
                        // LazyVStack leaves ghost blank space)
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
                        Text(L10n.format("%@ selected", zhHans: "已选 %@ 个", String(checkedIds.count)))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.text("Delete Selected", zhHans: "批量删除")) { confirmingBatchDelete = true }
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

    /// Search panel: the search field and source filter fused into one (filter embedded at the
    /// right, split by a thin divider); a permanent faint purple-gold gradient stroke separates
    /// layers; focusing lights the stroke + brand-colored magnifier
    private var searchPanel: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(searchFocused ? AnyShapeStyle(Theme.brandFg) : AnyShapeStyle(.tertiary))
            TextField(L10n.text("Search sessions / projects / id", zhHans: "搜索会话 / 项目 / id"), text: $service.searchText)
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
                .help(L10n.text("Clear search", zhHans: "清空搜索"))
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

    /// Colored tool button: sidebar-style colored rounded icon tile; active (multi-select on) = lit
    /// brand-color stroke
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

    /// Source filter entry (embedded at the right of the search panel): colored filter icon tile /
    /// the selected CLI's real logo + name. Opens a custom popover (not an NSMenu), so its style is
    /// controllable and it doesn't cross the left pane's divider.
    private var sourcePickerButton: some View {
        Button {
            showSourcePicker.toggle()
        } label: {
            HStack(spacing: 4) {
                if let filter = service.sourceFilter {
                    SourceBadge(source: filter, size: 12)
                    Text(filter.displayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.brandFg)
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
                    Text(L10n.text("All sources", zhHans: "全部来源"))
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
        .help(L10n.text("Filter sessions by CLI source", zhHans: "按 CLI 来源筛选会话"))
    }

    /// Source picker popover: real logo + name + count, selected row gets brand fill + checkmark;
    /// faint purple-gold gradient wash
    private var sourcePickerPopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            sourcePickerRow(nil, name: L10n.text("All sources", zhHans: "全部来源"), count: service.summary.sessionCount)
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

    // MARK: - Full-text hits (transcript-level search results, click to jump to the message)

    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.goldFg)
                Text(L10n.text("Matches in conversations", zhHans: "对话内容命中"))
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
                            Text(hit.sessionName ?? L10n.format("Session %@", zhHans: "会话 %@", String(hit.sessionId.prefix(8))))
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(hit.role == "user" ? L10n.text("User", zhHans: "用户") : L10n.text("Assistant", zhHans: "助手"))
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

/// Project row: click to expand/collapse the sessions under this project
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
                Text(L10n.format("%@ sessions", zhHans: "%@ 个", String(group.sessions.count)))
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

/// Session row: click to select (the detail pane loads the transcript); has a checkbox in
/// multi-select mode
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
                    ? "" : L10n.format("%@ sessions can't be deleted", zhHans: "%@ 会话不支持删除", session.source.displayName))
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
                        Text(L10n.format("%@ prompts", zhHans: "%@ 段", String(promptCount)))
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
            .help(L10n.text("Copy resume command", zhHans: "拷贝恢复命令"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.brandFill(0.08))
                    // Brand-colored indicator bar on the left (Activity Monitor-style selection)
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
