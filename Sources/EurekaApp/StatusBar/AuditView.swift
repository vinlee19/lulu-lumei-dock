import EurekaIngest
import EurekaInstall
import EurekaKit
import EurekaStore
import SwiftUI

/// Audit tab: security audit log of agent operations.
/// Filters (source / kind / risk only / keyword) + pagination + expand full text + CSV export.
///
/// The skeleton deliberately mirrors the Skills/Memory/Plans/Agents pages (`PlansView.content` is
/// the template):
/// `header + Divider + ScrollView{ overview card / source chips / kind chips / list container }.background(surfaceSecondary)`.
/// Previously this page used none of the shared components in `Styles.swift`: it hand-copied the
/// empty state and search field, source badges were text-only `Color.orange`/`Color.cyan` capsules instead of a real `SourceBadge`, and the
/// source filter was a hardcoded `Picker` — listing only 7 of the 12 sources, which was a missing
/// feature, not just a cosmetic issue.
///
/// ⚠️ This page was promoted from Settings → Audit to a top-level tab and **no longer inherits**
/// the `.toggleStyle(.switch)` / `.controlSize(.small)` / `.font(11.5)` injected by the Settings
/// subtree, so the settings popover must declare all three itself, or control sizes and font sizes
/// jump.
struct AuditView: View {
    @ObservedObject var service: AuditService
    @ObservedObject var installer: InstallerService
    /// The four capture / alert / retention toggles used to live in a card under Settings → Audit;
    /// they are now in the header's gear popover
    @ObservedObject var settings: AppSettings
    /// Only for the "system notifications unavailable" degraded hint (dev build / permission
    /// denied)
    @ObservedObject var notificationService: NotificationService
    /// Data source for the cross-source config consistency card (it holds skills / instructions /
    /// memory library)
    @ObservedObject var skillMemory: SkillMemoryService
    /// MCP entry snapshot (for the same-name-different-meaning drift check; the caller passes the
    /// latest value on every render, and the empty default doesn't affect offscreen rendering)
    var mcpServers: [MCPServerEntry] = []

    @State private var sourceFilter: AgentSource?
    @State private var kindFilter: ToolKind?
    @State private var riskOnly = false
    @State private var keyword = ""
    @State private var page = 1
    @State private var pageInput = ""
    @State private var expanded: Set<String> = []
    @State private var showSettings = false
    @State private var showExportConfirm = false
    @State private var showClearConfirm = false

    private let pageSize = 100

    /// Offscreen rendering / previews only: sets the initial filters (chips / search field change
    /// them during interaction). Follows `PlansView(initialLayout:)` — otherwise the empty state
    /// and the risk-only state can't be rendered automatically for checking.
    init(
        service: AuditService, installer: InstallerService, settings: AppSettings,
        notificationService: NotificationService, skillMemory: SkillMemoryService,
        mcpServers: [MCPServerEntry] = [],
        initialRiskOnly: Bool = false, initialKeyword: String = ""
    ) {
        self._service = ObservedObject(wrappedValue: service)
        self._installer = ObservedObject(wrappedValue: installer)
        self._settings = ObservedObject(wrappedValue: settings)
        self._notificationService = ObservedObject(wrappedValue: notificationService)
        self._skillMemory = ObservedObject(wrappedValue: skillMemory)
        self.mcpServers = mcpServers
        self._riskOnly = State(initialValue: initialRiskOnly)
        self._keyword = State(initialValue: initialKeyword)
    }

    /// Rule id → rule title (for badges; only the id is stored, the title is looked up in the
    /// built-in rules)
    private static let ruleTitles: [String: String] = Dictionary(
        RiskRuleEngine.builtinRules.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })

    private var query: AuditRepo.Query {
        AuditRepo.Query(
            source: sourceFilter, kind: kindFilter, riskOnly: riskOnly,
            keyword: keyword.trimmingCharacters(in: .whitespaces).isEmpty ? nil : keyword)
    }

    private var totalPages: Int {
        max(1, (service.total + pageSize - 1) / pageSize)
    }

    private var filtering: Bool {
        sourceFilter != nil || kindFilter != nil || riskOnly
            || !keyword.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear {
            installer.refresh()
            notificationService.refresh()
            reload()
        }
        .onChange(of: sourceFilter) { _, _ in resetAndReload() }
        .onChange(of: kindFilter) { _, _ in resetAndReload() }
        .onChange(of: riskOnly) { _, _ in resetAndReload() }
        .onChange(of: keyword) { _, _ in resetAndReload() }
        .confirmationDialog(
            L10n.text("The exported CSV contains full command text (it may include secrets). Export it to Downloads?", zhHans: "导出的 CSV 含完整命令文本（可能包含敏感信息），确认导出到下载目录？"),
            isPresented: $showExportConfirm, titleVisibility: .visible
        ) {
            Button(L10n.text("Export", zhHans: "导出")) { service.exportCSV(query: query) }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
        .confirmationDialog(
            L10n.text("Clear all audit data? This cannot be undone.", zhHans: "确认清空全部审计数据？此操作不可撤销。"),
            isPresented: $showClearConfirm, titleVisibility: .visible
        ) {
            Button(L10n.text("Clear", zhHans: "清空"), role: .destructive) { service.clearAll() }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        }
    }

    // MARK: - Header (title 15/bold + search + gear / export / clear / refresh)

    private var header: some View {
        HStack(spacing: 12) {
            Text(L10n.text("Audit", zhHans: "审计")).font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: L10n.text("Search commands / paths / tool names", zhHans: "搜索命令 / 文件路径 / 工具名"),
                text: $keyword, resultCount: service.total)
            Spacer(minLength: 12)
            if let message = service.exportMessage {
                Text(message)
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            CardActionButton(icon: "gearshape", help: L10n.text("Capture and retention", zhHans: "采集与保留策略")) {
                showSettings.toggle()
            }
            .popover(isPresented: $showSettings, arrowEdge: .bottom) { settingsPopover }
            CardActionButton(icon: "square.and.arrow.up", help: L10n.text("Export the current filter as CSV", zhHans: "导出当前筛选结果为 CSV")) {
                showExportConfirm = true
            }
            CardActionButton(icon: "trash", color: Theme.failureRed, help: L10n.text("Clear all audit data", zhHans: "清空全部审计数据")) {
                showClearConfirm = true
            }
            RefreshButton(help: L10n.text("Reload the audit log", zhHans: "重新读取审计流水")) { reload() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Capture toggles and retention policy. A popover rather than a `Menu`: there are three
    /// explanatory texts that must stay (privacy scope / heuristic disclaimer / notification
    /// fallback), and NSMenu items truncate long text.
    ///
    /// Not private so `PreviewRenderer` can render it on its own — a popover needs a real window,
    /// so it isn't rasterized when the whole page is rendered offscreen; only rendering this
    /// content view alone lets us check the layout.
    var settingsPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.text("Record an audit log of agent actions", zhHans: "记录 agent 操作审计流水"), isOn: $settings.auditEnabled)
            Text(L10n.text("Records the full commands agents run and the file paths they read or write, so you can look back later;", zhHans: "记录 agent 执行的完整命令与读写的文件路径，用于事后回溯；")
                + L10n.text(" it does not record command output. Command text is already stored in plain text in local session logs.", zhHans: "不记录任何执行输出内容。命令文本本就明文存于本地会话记录中。"))
                .font(Theme.font.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.auditEnabled {
                Divider()
                Toggle(L10n.text("Red card on the island for high-risk actions", zhHans: "高危操作岛内红卡告警"), isOn: $settings.auditRiskAlertsEnabled)
                Toggle(L10n.text("System notification for high-risk actions (visible on the lock screen and other desktops)", zhHans: "高危操作系统通知（锁屏 / 其他桌面可见）"), isOn: $settings.auditSystemNotifyEnabled)
                if let hint = notificationHint, settings.auditSystemNotifyEnabled {
                    Text(hint)
                        .font(Theme.font.caption)
                        .foregroundStyle(Theme.goldFg)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text(L10n.text("Retention", zhHans: "保留时长"))
                    Spacer(minLength: 8)
                    Picker("", selection: $settings.auditRetentionDays) {
                        Text(L10n.text("30 days", zhHans: "30 天")).tag(30)
                        Text(L10n.text("90 days", zhHans: "90 天")).tag(90)
                        Text(L10n.text("180 days", zhHans: "180 天")).tag(180)
                        Text(L10n.text("365 days", zhHans: "365 天")).tag(365)
                        Text(L10n.text("Forever", zhHans: "永久")).tag(0)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 110)
                }
                if settings.auditArchiveEnabled {
                    Text(archiveLine)
                        .font(Theme.font.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(L10n.text("High-risk rules are hints (sudo, rm -rf of an absolute path, piping a downloaded script into a shell, reading or writing secrets, and similar),", zhHans: "高危规则为启发式提示（sudo / rm -rf 绝对路径 / 管道执行下载脚本 / 读写密钥等），")
                    + L10n.text(" not a sandbox. Matches are deduped and throttled.", zhHans: "非沙箱拦截；命中会去重节流。"))
                    .font(Theme.font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // A top-level tab doesn't inherit the Settings subtree's style injection, so these three
        // lines must be declared here
        .toggleStyle(.themedSwitch)
        .controlSize(.small)
        .font(.system(size: 11.5))
        .padding(Theme.spacing.card)
        .frame(width: 320)
    }

    /// Audit archive status line (shown only when archiving is on)
    private var archiveLine: String {
        guard settings.cloudBackupEnabled else {
            return L10n.text("Audit archive is on, but cloud backup is off: nothing is uploaded, and cleanup follows the retention period.", zhHans: "审计归档已开启，但云端备份未开启：不会上传，清理按原保留时长执行。")
        }
        guard let status = service.archiveStatus else { return L10n.text("Audit archive: waiting for the first backup…", zhHans: "审计归档：等待第一轮备份…") }
        var text = L10n.format("Audit archive: %@ days uploaded", zhHans: "审计归档：已上传 %@ 天", String(status.uploadedDays))
        if let day = status.latestUploadedDay { text += L10n.format(" (latest %@)", zhHans: "（最近 %@）", String(day)) }
        if status.pendingDays > 0 { text += L10n.format(", %@ days waiting to upload", zhHans: "，%@ 天待上传", String(status.pendingDays)) }
        return text + L10n.text(". Only days that have been uploaded are pruned.", zhHans: "。只清理已上传的日期。")
    }

    /// System notification fallback hint: reflects the real authorization state (unavailable in dev
    /// builds / denied / normal)
    private var notificationHint: String? {
        switch notificationService.availability {
        case .unavailableNotBundled:
            return L10n.text("Running in dev mode (swift run): system notifications are unavailable, so only the island red card alerts. They work after you install the .app.", zhHans: "当前为开发模式（swift run）运行，系统通知不可用，仅岛内红卡告警；安装为 .app 后生效。")
        case .denied:
            return L10n.text("System notification permission was denied, so only the island red card alerts. Turn it on in System Settings > Notifications > lulu-lumei-dock.", zhHans: "系统通知权限已被拒绝，仅岛内红卡告警。可在 系统设置 > 通知 > lulu-lumei-dock 中开启。")
        case .authorized, .unknown:
            return nil
        }
    }

    // MARK: - Body

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                // Config consistency sits on the same page as the audit log because both answer the
                // same kind of question: "what state are all my CLI configs actually in". It needs
                // no audit toggle and ignores the filters.
                ConsistencyCard(service: skillMemory, mcpDrifts: ConsistencyChecker.mcpDrifts(mcpServers))
                sourceBar
                kindBar
                if !settings.auditEnabled {
                    captureOffHint
                } else if installer.claudeStatus != .installed {
                    hooksHint
                }
                // A failed DB read used to be published but not rendered — on error the whole page
                // was silently blank, with no way to tell
                if let error = service.lastError {
                    noticeCard(
                        icon: "exclamationmark.octagon.fill", tint: Theme.failureRed,
                        text: error)
                }
                if service.events.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.shield",
                        title: filtering ? L10n.text("Nothing matches this filter", zhHans: "当前筛选无匹配记录") : L10n.text("No audit records yet", zhHans: "暂无审计记录"),
                        hint: filtering
                            ? L10n.text("Try another source or type, or clear the keyword", zhHans: "换个来源 / 类型，或清空关键词")
                            : L10n.text("Commands and file reads or writes show up here. Only the full command and the path are recorded, not the output.", zhHans: "agent 执行命令、读写文件后会出现在这里；只记录命令全文与文件路径，不含执行输出"))
                        .padding(.top, 40)
                } else {
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(service.events.enumerated()), id: \.element.opId) {
                                index, event in
                                row(event)
                                if index < service.events.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 50)
                                }
                            }
                            Divider().opacity(0.4)
                            paginationBar
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    // MARK: - Overview card

    private var statsCard: some View {
        StatOverviewCard(
            value: "\(service.total)",
            unit: L10n.text("audit events", zhHans: "审计事件"),
            subtitle: subtitle,
            distributionTitle: L10n.text("By type", zhHans: "类型分布"),
            segments: kindSegments,
            trailingNote: filtering ? L10n.text("Filtered", zhHans: "已筛选") : nil)
    }

    private var subtitle: String {
        let retention = settings.auditRetentionDays == 0
            ? L10n.text("Kept forever", zhHans: "永久保留") : L10n.format("Keep %@ days", zhHans: "保留 %@ 天", String(settings.auditRetentionDays))
        // `riskTotal` is the risk count for the **whole DB** (ignores filters); while filtered it
        // has a different base than the big number next to it, and side by side it reads as "123
        // risky out of 0" → when filtering show only the retention policy and leave the risk count
        // to the risk-only chip.
        guard service.riskTotal > 0, !filtering else { return retention }
        return L10n.format("Risk %@ · %@", zhHans: "风险 %@ · %@", String(service.riskTotal), String(retention))
    }

    /// Kind distribution: top 4 + "other", same approach and color ramp as
    /// `AgentsView.modelSegments`. **Must be capped**: `ToolKind` has 9 cases, and 9 legend items
    /// at the 780pt minimum content width would fold labels like the zhHans "Command" and "16,911"
    /// into vertical one-character columns. Exact counts for all 9 kinds come from the kind chips
    /// below.
    private var kindSegments: [StatOverviewCard.Segment] {
        let shades: [Double] = [1.0, 0.78, 0.6, 0.45]
        var segments: [StatOverviewCard.Segment] = []
        var other = 0
        for (index, entry) in sortedKinds.enumerated() {
            if index < shades.count {
                segments.append(.init(label: entry.key.label, count: entry.value,
                                      color: Theme.brand.opacity(shades[index])))
            } else {
                other += entry.value
            }
        }
        if other > 0 {
            segments.append(.init(label: L10n.text("Other", zhHans: "其他"), count: other, color: Theme.brand.opacity(0.3)))
        }
        return segments
    }

    /// Kinds that have data, most first (chips and distribution share the same order)
    private var sortedKinds: [(key: ToolKind, value: Int)] {
        service.kindCounts.filter { $0.value > 0 }
            .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
            .map { (key: $0.key, value: $0.value) }
    }

    // MARK: - Filters

    /// Source filter: switched to `SourceFilterBar`, which automatically covers **every source with
    /// data** (the old hardcoded `Picker` missed opencode/antigravity/kimi/gemini/hermes)
    private var sourceBar: some View {
        SourceFilterBar(
            selected: $sourceFilter,
            allLabel: L10n.text("All", zhHans: "全部"), allIcon: "checkmark.shield",
            totalCount: service.sourceCounts.values.reduce(0, +),
            sources: service.sourceCounts.filter { $0.value > 0 }
                .sorted { ($0.value, $0.key.rawValue) > ($1.value, $1.key.rawValue) }
                .map(\.key),
            count: { service.sourceCounts[$0] ?? 0 })
    }

    /// Kind chips + risk only (wrapping flow layout, same visual language as `SourceFilterBar`, one
    /// size smaller)
    private var kindBar: some View {
        FlowLayout(spacing: 8, lineSpacing: 8) {
            kindChip(nil, label: L10n.text("All types", zhHans: "全部类型"), icon: "square.grid.2x2",
                     count: service.kindCounts.values.reduce(0, +))
            ForEach(sortedKinds, id: \.key) { entry in
                kindChip(entry.key, label: entry.key.label, icon: entry.key.icon,
                         count: entry.value)
            }
            riskChip
        }
    }

    private func kindChip(
        _ kind: ToolKind?, label: String, icon: String, count: Int
    ) -> some View {
        let isSelected = kindFilter == kind
        return Button {
            kindFilter = (kind != nil && kindFilter == kind) ? nil : kind
        } label: {
            chipLabel(
                icon: icon, label: label, count: count,
                isSelected: isSelected, tint: Theme.brand)
        }
        .buttonStyle(.plain)
    }

    private var riskChip: some View {
        Button { riskOnly.toggle() } label: {
            chipLabel(
                icon: "exclamationmark.shield.fill", label: L10n.text("Risk only", zhHans: "仅风险"),
                count: service.riskTotal, isSelected: riskOnly, tint: Theme.failureRed)
        }
        .buttonStyle(.plain)
        .help(L10n.text("Show only actions that hit a high-risk or warning rule", zhHans: "只看命中高危 / 提醒规则的操作"))
    }

    private func chipLabel(
        icon: String, label: String, count: Int, isSelected: Bool, tint: Color
    ) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10, weight: .medium))
            Text(label).font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            Text("\(count)")
                .font(.system(size: 10, weight: .medium).monospacedDigit())
                .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85))
                                            : AnyShapeStyle(.tertiary))
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(isSelected ? AnyShapeStyle(tint) : AnyShapeStyle(Theme.surface)))
        .overlay(
            Capsule().strokeBorder(
                isSelected ? Color.clear : Theme.cardBorder, lineWidth: 0.8))
        .contentShape(Capsule())
    }

    // MARK: - Notice cards (capture off / hooks not installed / DB read failure share one rounded card)

    private var captureOffHint: some View {
        noticeCard(
            icon: "pause.circle.fill", tint: Theme.gold,
            text: L10n.text("Capture is off, so new actions are not recorded (history already stored is still below).", zhHans: "审计采集已关闭，不会再记录新操作（下方仍是已入库的历史）。")
        ) {
            Button(L10n.text("Turn on", zhHans: "开启")) { settings.auditEnabled = true }
                .controlSize(.small)
        }
    }

    /// Claude hooks not installed notice. Used to be a full-width, square-cornered
    /// `Color.orange.opacity(0.08)` rectangle, done nowhere else in the app.
    private var hooksHint: some View {
        noticeCard(
            icon: "exclamationmark.triangle.fill", tint: Theme.gold,
            text: L10n.text("Claude hooks are not installed, so Claude actions are not being audited yet", zhHans: "Claude hooks 未安装，Claude 的操作暂未被审计采集")
                + L10n.text(" (Codex / CodeBuddy / Qoder / Cursor / Grok / Qwen are unaffected;", zhHans: "（Codex / CodeBuddy / Qoder / Cursor / Grok / Qwen 不受影响；")
                + L10n.text(" Trae also depends on hooks — see Settings → Integrations).", zhHans: "Trae 同样依赖 hooks，见 设置 → 集成）。"),
            // The install / uninstall result must be echoed back: otherwise a refusal (unparseable
            // config / hand-edited path) gives no feedback
            detail: installer.message
        ) {
            // Install Claude hooks only. Never call installAll() — it would also write
            // ~/.codex/config.toml, conjuring up another agent's config file for someone who only
            // uses Claude.
            Button(L10n.text("Install", zhHans: "安装")) { installer.install(.claudeHooks) }
                .controlSize(.small)
        }
    }

    private func noticeCard<Action: View>(
        icon: String, tint: Color, text: String, detail: String? = nil,
        @ViewBuilder action: () -> Action = { EmptyView() }
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(Theme.font.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            action()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(tint.opacity(0.10)))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
    }

    // MARK: - Row (KnowledgeRow: brand-tinted hover + 3pt leading bar + context menu, same as the four knowledge pages)

    @ViewBuilder
    private func row(_ event: AuditEvent) -> some View {
        let isExpanded = expanded.contains(event.opId)
        KnowledgeRow(onOpen: { toggle(event.opId) }) {
            HStack(alignment: .top, spacing: 10) {
                kindTile(event.kind)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(event.tool)
                            .font(Theme.font.monoSkillName(12, weight: .semibold))
                            .lineLimit(1)
                        SourceBadge(source: event.source, size: 12)
                        if let level = event.riskLevel {
                            TagChip(
                                event.riskRule.flatMap { Self.ruleTitles[$0] } ?? level.label,
                                tint: Theme.riskColor(level))
                        }
                        if event.isError {
                            TagChip(
                                event.exitCode.map { L10n.format("Exit %@", zhHans: "退出码 %@", String($0)) } ?? L10n.text("Failed", zhHans: "失败"),
                                tint: Theme.failureRed)
                        }
                        // cwd was always stored but never shown, wasted
                        if let project = projectName(event.cwd) {
                            TagChip(project, neutral: true)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(isExpanded ? event.detail : firstLine(event.detail))
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        // The expanded state must lock its vertical intrinsic height, or multi-line
                        // commands get squashed back to one line (the old version had this line
                        // too)
                        .fixedSize(horizontal: false, vertical: isExpanded)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(event.timestamp, format: .dateTime.month().day().hour().minute())
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
        } menu: {
            Button(isExpanded ? L10n.text("Collapse", zhHans: "收起") : L10n.text("Expand", zhHans: "展开全文")) { toggle(event.opId) }
            Button(L10n.text("Copy full arguments", zhHans: "复制参数全文")) { copy(event.detail) }
            if let cwd = event.cwd, !cwd.isEmpty {
                Button(L10n.text("Copy working directory", zhHans: "复制工作目录")) { copy(cwd) }
            }
            Divider()
            Button(L10n.format("Only %@", zhHans: "只看 %@", String(event.source.displayName))) { sourceFilter = event.source }
            Button(L10n.format("Only “%@”", zhHans: "只看「%@」", String(event.kind.label))) { kindFilter = event.kind }
        }
    }

    /// Kind icon tile: reuses `TileSpec` + `ToolKind.icon`, positioned like `SourceLogoTile` on the
    /// four knowledge pages
    private func kindTile(_ kind: ToolKind) -> some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(28), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: 28, height: 28)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(28), style: .continuous)
                    .strokeBorder(TileSpec.border(Theme.brand), lineWidth: 0.5))
            .overlay(
                Image(systemName: kind.icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.brandFg))
            .help(kind.label)
    }

    // MARK: - Pagination (after UsageDashboardView.paginationBar, including the previously missing "Go to")

    private var paginationBar: some View {
        HStack(spacing: 8) {
            Text(L10n.format("%@ total", zhHans: "共 %@ 条", String(service.total)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            // Same as subtitle: the whole-DB risk count and the filtered "N total" have different
            // bases, so don't show them side by side
            if service.riskTotal > 0, !filtering {
                Text(L10n.format("· Risk %@", zhHans: "· 风险 %@", String(service.riskTotal)))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Theme.failureRed)
            }
            Spacer()
            Button { goTo(page - 1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page <= 1)
            Text("\(page) / \(totalPages)")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
            Button { goTo(page + 1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .buttonStyle(.borderless)
            .disabled(page >= totalPages)
            Text(L10n.text("Go to", zhHans: "跳至")).font(.system(size: 10)).foregroundStyle(.tertiary)
            TextField("", text: $pageInput)
                .textFieldStyle(.roundedBorder)
                .frame(width: 40)
                .font(.system(size: 10).monospacedDigit())
                .multilineTextAlignment(.center)
                .onSubmit {
                    if let target = Int(pageInput.trimmingCharacters(in: .whitespaces)) {
                        goTo(target)
                    }
                    pageInput = ""
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private func toggle(_ opId: String) {
        if expanded.contains(opId) { expanded.remove(opId) } else { expanded.insert(opId) }
    }

    private func goTo(_ target: Int) {
        page = min(max(1, target), totalPages)
        reload()
    }

    private func reload() {
        service.load(query: query, page: page, pageSize: pageSize)
    }

    private func resetAndReload() {
        page = 1
        expanded.removeAll()
        reload()
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func firstLine(_ text: String) -> String {
        guard !text.isEmpty else { return "—" }
        return text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }

    /// cwd → project name (the last path component is enough; not worth pulling in EurekaUsage's
    /// ProjectResolver for a display string)
    private func projectName(_ cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
