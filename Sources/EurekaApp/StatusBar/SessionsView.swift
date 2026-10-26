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
    /// AI summaries (row status, context menu)
    @ObservedObject var summaries: SessionSummaryService = .shared
    /// Detail tab to start on (offscreen renders of the summary tab)
    var initialDetailTab: SessionDetailView.DetailTab = .conversation
    /// Groups manually collapsed in the project view (all expanded by default)
    @State private var collapsed: Set<String> = []
    /// Multi-select mode and the selected set (session ids)
    @State private var multiSelect = false
    @State private var checkedIds: Set<String> = []
    @State private var confirmingBatchDelete = false
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

    /// Nothing indexed at all (after a finished scan): no detail pane, the list explains it
    private var hasNoSessions: Bool {
        service.summary.sessionCount == 0 && !service.scanning && service.lastIndexedAt != nil
    }

    @ViewBuilder
    private var twoPane: some View {
        if hasNoSessions {
            listPane.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            splitPanes
        }
    }

    private var splitPanes: some View {
        HSplitView {
            // maxWidth sets how far the divider can be dragged: at 420 there was only 170pt, barely
            // noticeable in a wide window (reported as "can't resize"); 620 opens it up while
            // keeping the detail pane's 380 floor
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
                },
                summaries: summaries,
                initialTab: initialDetailTab)
                // 375 + the list's 300 = the 675pt content width of the minimum window
                .frame(minWidth: 375, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .onAppear {
            service.rangeAll = settings.sessionRangeAll
            if let mode = SessionBrowserService.SortMode(rawValue: settings.sessionSortMode) {
                service.sortMode = mode
            }
            service.refreshIfStale()
            summaries.factsProvider = { [weak service] session in
                service?.summaryFacts(for: session) ?? []
            }
            if service.selected == nil, let latest = service.mostRecentSession() {
                service.select(latest)
            }
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
                Text(L10n.format("%@ sessions", zhHans: "共 %@ 个会话", "\(service.summary.sessionCount.formatted())"))
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
                        Text(L10n.text("Indexing", zhHans: "索引中"))
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
            // row to itself; the source picker, compact time-range toggle, and the two round tool
            // buttons share the row below so we save a full vertical tray row.
            VStack(spacing: 6) {
                SearchField(placeholder: L10n.text("Search sessions / projects / id", zhHans: "搜索会话 / 项目 / id"), text: $service.searchText, maxWidth: nil)
                HStack(spacing: 6) {
                    sourcePickerButton
                    Spacer(minLength: 4)
                    CapsuleTabTray {
                        CapsuleTabButton(
                            title: L10n.text("30d", zhHans: "30 天"),
                            fillWidth: false,
                            isSelected: !settings.sessionRangeAll
                        ) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                settings.sessionRangeAll = false
                            }
                        }
                        .help(L10n.text("Last 30 days", zhHans: "近 30 天"))
                        CapsuleTabButton(
                            title: L10n.text("All", zhHans: "全部"),
                            fillWidth: false,
                            isSelected: settings.sessionRangeAll
                        ) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                settings.sessionRangeAll = true
                            }
                        }
                        .help(L10n.text("All time", zhHans: "全部时间"))
                    }
                    .accessibilityLabel(L10n.text("Session time range", zhHans: "会话时间范围"))
                    RoundGlyphButton(
                        icon: "checkmark", active: multiSelect,
                        help: multiSelect ? L10n.text("Exit multi-select", zhHans: "退出多选") : L10n.text("Multi-select (batch delete)", zhHans: "多选模式（批量删除）")
                    ) {
                        multiSelect.toggle()
                        if !multiSelect { checkedIds = [] }
                    }
                    RefreshButton(help: L10n.text("Reindex sessions", zhHans: "重新索引会话")) { service.refresh() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)

            // Sort / view (first three modes are flat lists, "Project" groups by project); capsule
            // tabs, selected = purple fill + white text
            // English labels don't fit four equal tabs in the narrow list, so fall back from
            // icon + title to title only, then to icons only (the title moves into the tooltip).
            // The title-only tray hugs its labels: equal-width tabs would let ViewThatFits accept
            // it on total width and then truncate the longest label.
            ViewThatFits(in: .horizontal) {
                sortTray(showIcon: true, showTitle: true, fill: true)
                sortTray(showIcon: false, showTitle: true, fill: false)
                sortTray(showIcon: true, showTitle: false, fill: true)
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
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                    } else {
                        EmptyStateView(
                            icon: "archivebox",
                            title: service.isSearching
                                ? L10n.text("No matching sessions", zhHans: "没有匹配的会话")
                                : (settings.sessionRangeAll
                                    ? L10n.text("No sessions", zhHans: "没有会话")
                                    : L10n.text("No sessions in the last 30 days", zhHans: "近 30 天没有会话")),
                            hint: !service.isSearching && !settings.sessionRangeAll
                                ? L10n.text("Older records are under All time", zhHans: "更早的记录在「全部时间」里")
                                : nil)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Flat list (recently active / size / duration): no project attribute
                        let flat = sessionLines(service.flatSessions)
                        ForEach(flat.users) { session in
                            sessionRow(session)
                            Divider().padding(.leading, 12).opacity(0.4)
                        }
                        if flat.utilityCount > 0 {
                            HarnessUtilityRow(count: flat.utilityCount, subtitle: Self.utilitySubtitle)
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
                                let lines = sessionLines(group.sessions)
                                ForEach(lines.users) { session in
                                    sessionRow(session)
                                        .padding(.leading, 10)
                                }
                                if lines.utilityCount > 0 {
                                    HarnessUtilityRow(count: lines.utilityCount, subtitle: Self.utilitySubtitle)
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
                            .font(Theme.font.themed(10.5))
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
                        .font(Theme.font.themed(10, .semibold))
                    Text(L10n.text("All sources", zhHans: "全部来源"))
                        .font(Theme.font.themed(11, .medium))
                        .fixedSize()
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(Theme.font.themed(8, .semibold))
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
        .help(L10n.text("Filter sessions by CLI source", zhHans: "按 CLI 来源筛选会话"))
        .themedPopup(isPresented: $showSourcePicker) {
            sourcePickerPopover
        }
    }

    /// Source popover: logo + name + count per row, brand fill and a check on the chosen one
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
        // The themed pop-up draws the surface; no wash of its own.
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
                    RoundedRectangle(cornerRadius: ThemeStyle.current.isHardEdged ? 0 : 3.5, style: .continuous)
                        .fill(ThemeStyle.current.isHardEdged ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(Theme.brand.gradient))
                        .frame(width: 14, height: 14)
                        .overlay(
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(Theme.font.themed(7, .semibold))
                                .foregroundStyle(Theme.onBrand))
                }
                Text(name)
                    .font(Theme.font.themed(11, selected ? .semibold : .regular))
                Spacer(minLength: 8)
                Text("\(count)")
                    .font(Theme.font.themedMono(10.5))
                    .foregroundStyle(selected ? AnyShapeStyle(Theme.brandFg) : AnyShapeStyle(.tertiary))
                if selected {
                    Image(systemName: "checkmark")
                        .font(Theme.font.themed(8, .bold))
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

    private static let utilitySubtitle = L10n.text("Internal prompts such as memory compaction, folded out of the list", zhHans: "记忆压缩等内部提示，已从列表收起")

    /// Splits harness background calls out of a session list. Nothing folds while searching,
    /// otherwise searching for that prompt text itself would come back empty.
    private func sessionLines(
        _ sessions: [AgentSessionInfo]
    ) -> (users: [AgentSessionInfo], utilityCount: Int) {
        guard !service.isSearching else { return (sessions, 0) }
        var users: [AgentSessionInfo] = []
        var utilityCount = 0
        for session in sessions {
            if PromptClassifier.isHarnessUtility(session.displayName) {
                utilityCount += 1
            } else {
                users.append(session)
            }
        }
        return (users, utilityCount)
    }

    private func sortTray(showIcon: Bool, showTitle: Bool, fill: Bool) -> some View {
        CapsuleTabTray {
            ForEach(SessionBrowserService.SortMode.allCases, id: \.self) { mode in
                CapsuleTabButton(
                    title: showTitle ? mode.label : "",
                    icon: showIcon ? mode.icon : nil,
                    fillWidth: fill,
                    isSelected: service.sortMode == mode
                ) {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        service.sortMode = mode
                    }
                }
                .help(mode.label)
            }
        }
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
            onToggleCheck: { toggleCheck(session) },
            summaryStatus: summaries.rowStatus[summaries.key(session)])
            .contextMenu { summaryContextMenu(session) }
    }

    /// Row context menu: summarize with any executor, or open the saved summary
    @ViewBuilder
    private func summaryContextMenu(_ session: AgentSessionInfo) -> some View {
        if let reason = SummarySourceSupport.unsupportedReason(session.source) {
            Text(reason)
        } else {
            Button(L10n.text("Show AI Summary", zhHans: "查看 AI 总结")) {
                service.select(session)
                summaries.revealSummary(for: session)
            }
            Menu(L10n.text("Summarize with", zhHans: "AI 总结")) {
                SummaryExecutorMenuItems(summaries: summaries, session: session) {
                    service.select(session)
                    summaries.revealSummary(for: session)
                }
            }
        }
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
                    .font(Theme.font.themed(10))
                    .foregroundStyle(Theme.goldFg)
                Text(L10n.text("Matches in conversations", zhHans: "对话内容命中"))
                    .font(Theme.font.themed(11, .semibold))
                Text("\(service.fullTextHits.count)")
                    .font(Theme.font.themedMono(10))
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
                                .font(Theme.font.themed(11, .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(hit.role == "user" ? L10n.text("User", zhHans: "用户") : L10n.text("Assistant", zhHans: "助手"))
                                .font(Theme.font.themed(9))
                                .foregroundStyle(.tertiary)
                            if let ts = hit.ts {
                                Text(relativeFormatter.localizedString(for: ts, relativeTo: Date()))
                                    .font(Theme.font.themed(9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(hit.snippet)
                            .font(Theme.font.themed(10.5))
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
                    .font(Theme.font.themed(9, .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "folder.fill")
                    .font(Theme.font.themed(11))
                    .foregroundStyle(Theme.brandFg.opacity(0.8))
                Text(group.name)
                    .font(Theme.font.themed(12, .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let cost = group.totalCostUSD {
                    Text("≈\(formatCost(cost))")
                        .font(Theme.font.themedMono(10, .medium))
                        .foregroundStyle(Theme.cost)
                }
                Text(L10n.format("%@ sessions", zhHans: "%@ 个", String(group.sessions.count)))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.secondary)
                Text(formatBytes(group.totalBytes))
                    .font(Theme.font.themedMono(10))
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
    /// AI summary status (nil = never summarized; renders nothing)
    var summaryStatus: SessionSummaryService.RowStatus?

    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if multiSelect {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(Theme.font.themed(12))
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
                        .font(Theme.font.themed(12.5))
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
                    if let summaryStatus {
                        SummaryRowBadge(status: summaryStatus)
                    }
                }
                .font(Theme.font.themed(10))
                .foregroundStyle(.tertiary)
                // Truncate rather than wrap: a squeezed row used to break a relative time like "1 min ago" across lines
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                service.copyResumeCommand(session)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(Theme.font.themed(11))
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
