import Charts
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// Skill detail target: reachable from a skill card (entry set, editable/shows description)
/// or from a stats-only row (entry is nil, read-only with little info).
struct SkillDetailTarget: Identifiable {
    var source: AgentSource
    var name: String
    var entry: SkillEntry?
    var id: String { "\(source.rawValue):\(name)" }
}

/// Inline skill detail page (slides in within the list page, not a modal): Overview = description +
/// cross-tool config matrix + call stats; Preview/Edit = render and rewrite SKILL.md. Call data is
/// only available for Claude (transcripts record Skill calls); other sources show "no per-skill
/// call data".
struct SkillDetailView: View {
    let target: SkillDetailTarget
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    let onBack: () -> Void
    let onDelete: (SkillEntry) -> Void
    /// Used by the "recent sessions" rows to jump; when nil the rows grey out as unreachable
    /// (compatible with existing construction sites)
    var sessionBrowser: SessionBrowserService? = nil

    /// Detail segments: Overview (stats matrix) / Preview (rendered SKILL.md) / Edit (raw text)
    enum Pane: String, CaseIterable {
        case overview = "概览", preview = "预览", edit = "编辑"

        var title: String {
            switch self {
            case .overview: return L10n.text("Overview", zhHans: "概览")
            case .preview: return L10n.text("Preview", zhHans: "预览")
            case .edit: return L10n.text("Edit", zhHans: "编辑")
            }
        }
    }
    @State private var pane: Pane = .overview
    @State private var series: [UsageService.SkillDayCount] = []
    @State private var text = ""
    @State private var textLoaded = false
    @State private var saveNote: String?

    /// This week's rank (gold tile; nil = no calls this week)
    @State private var weeklyRank: Int?
    /// Cross-source install target awaiting confirmation (an unconfigured source clicked in the
    /// matrix)
    @State private var installTarget: AgentSource?
    /// true = the target already has a user-created skill of the same name, so this is an overwrite
    /// update (old version goes to Trash), not a fresh install
    @State private var installOverwrite = false
    /// Install result feedback (shown briefly below the matrix)
    @State private var installNote: String?
    /// Sessions that recently called this skill (the detail page's "recent sessions" card)
    @State private var recentSessions: [(sessionId: String, lastTs: Date, count: Int)] = []
    /// sessionBrowser is a plain optional stored property (not @ObservedObject), so the view
    /// doesn't re-render after the index refreshes; this counter subscribes to its objectWillChange
    /// to rebuild the sub-section manually, so greyed rows heal to clickable once the index is
    /// built.
    @State private var sessionIndexVersion = 0

    /// Live entry: enabling/disabling moves the skill directory (path changes), so look up the
    /// latest entry from the service by source + project + directory name, keeping toggles/edits
    /// always applied to the current path.
    private var entry: SkillEntry? {
        guard let base = target.entry else { return nil }
        let dir = URL(fileURLWithPath: base.directory).lastPathComponent
        return service.skills.first {
            $0.source == base.source
                && $0.scope.projectName == base.scope.projectName
                && URL(fileURLWithPath: $0.directory).lastPathComponent == dir
        } ?? base
    }

    /// Matching call stats (by source + normalized name)
    private var stat: ToolCallsRepo.SkillUsageStat? {
        let key = SkillMemoryService.normalizeSkillName(target.name)
        return usageService.skillStats.first {
            $0.source == target.source
                && SkillMemoryService.normalizeSkillName($0.name) == key
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            switch pane {
            case .overview:
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        descriptionSection
                        matrixSection
                        statsSection
                    }
                    .padding(Theme.spacing.page)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .preview:
                MarkdownDocumentCard(text: text)
            case .edit:
                TextEditor(text: $text)
                    .font(.system(size: 12).monospaced())
                    .padding(8)
            }
            if pane != .overview, let entry {
                Divider()
                documentFooter(entry)
            }
        }
        .onAppear {
            loadSeries()
            loadText()
            usageService.loadSkillWeeklyRank(
                source: target.source, name: stat?.name ?? target.name
            ) { weeklyRank = $0 }
            usageService.loadSkillSessions(
                source: target.source, name: stat?.name ?? target.name
            ) { recentSessions = $0 }
            // On cold start the session index may not exist yet and "recent sessions" would be all
            // grey; build it once, following UsageDashboardView's precedent
            if let sessionBrowser, sessionBrowser.sessionsById.isEmpty {
                sessionBrowser.refresh()
            }
        }
        .onReceive(
            sessionBrowser?.objectWillChange.eraseToAnyPublisher()
                ?? Empty<Void, Never>().eraseToAnyPublisher()
        ) { _ in
            sessionIndexVersion &+= 1
        }
    }

    // MARK: - Top toolbar (back + title + toggle tile + segments)

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text(L10n.text("Back", zhHans: "返回")).font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            SourceLogoTile(source: target.source, size: 26)
            Text(entry?.name ?? target.name)
                .font(Theme.font.monoSkillName(15, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let project = entry?.scope.projectName {
                TagChip(project)
            }
            if let entry {
                EnableToggle(enabled: entry.enabled) {
                    service.setSkillEnabled(entry, !entry.enabled)
                }
            }
            Spacer(minLength: 8)
            if let entry {
                // Segments "Overview / Preview / Edit": selected = purple fill + white text
                CapsuleTabTray {
                    ForEach(Pane.allCases, id: \.self) { item in
                        CapsuleTabButton(
                            title: item.title,
                            fillWidth: false,
                            isSelected: pane == item
                        ) { pane = item }
                    }
                }
                Button { service.openInEditor(path: entry.path) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Open in default editor", zhHans: "用默认编辑器打开"))
                Button { service.reveal(path: entry.path) } label: {
                    Image(systemName: "folder").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"))
                Button(role: .destructive) { onDelete(entry) } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Move to Trash (can be restored)", zhHans: "移入废纸篓（可恢复）"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func documentFooter(_ entry: SkillEntry) -> some View {
        HStack(spacing: 8) {
            Text(entry.path)
                .font(.system(size: 9).monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note = saveNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            if pane == .edit {
                Button(L10n.text("Save", zhHans: "保存")) {
                    service.save(path: entry.path, content: text) { ok in
                        saveNote = ok ? L10n.text("Saved (a backup was kept before writing)", zhHans: "已保存（写前留有备份）") : L10n.text("Couldn't save", zhHans: "保存失败")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - Description

    @ViewBuilder
    private var descriptionSection: some View {
        if let desc = entry?.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                sectionTitle(L10n.text("Description", zhHans: "描述"))
                Text(desc)
                    .font(.system(size: 13.5))
                    .lineSpacing(6)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Cross-tool config matrix

    private var matrixSection: some View {
        let configs = service.configurations(forName: target.name)
        let configured = AgentSource.allCases.filter { configs[$0] != nil }.count
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                sectionTitle(L10n.text("Configured in", zhHans: "配置于"))
                Text(L10n.format(
                    "%2$@ of %1$@ tools available",
                    zhHans: "%1$@ 个工具中 %2$@ 个可用",
                    String(AgentSource.allCases.count), String(configured)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if entry != nil {
                    Text(L10n.text("· Unconfigured sources can be installed in one click · Custom copies can be overwritten", zhHans: "· 未配置可一键安装 · 自建可覆盖更新"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(AgentSource.allCases, id: \.self) { source in
                    let origin = configs[source]
                    // With a real entry (not a stats-only row), unconfigured sources are clickable
                    // to install (copies the skill directory over)
                    let installable = origin == nil && entry != nil
                    // Target already has a **user-created** skill of the same name → can overwrite
                    // it with the current version (version alignment). Bundled ones are left alone
                    // (bundled dirs are read-only by convention); the entry's own source has no
                    // update semantics
                    let updatable = origin == .user && entry != nil && source != entry?.source
                    VStack(spacing: 4) {
                        SourceBadge(source: source, size: 22)
                            .opacity(origin == nil ? 0.28 : 1)
                        Text(source.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(origin == nil ? .tertiary : .secondary)
                        if installable {
                            Text(L10n.text("Install", zhHans: "安装"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.brandFg)
                        } else {
                            Text(originLabel(origin))
                                .font(.system(size: 8, weight: .medium))
                                .foregroundStyle(originColor(origin))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    // Configured = purple stroke + light purple fill; unconfigured = grey border
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container)
                            .fill(origin != nil ? Theme.brandFill(0.08) : Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container)
                            .strokeBorder(
                                origin != nil ? Theme.brand.opacity(0.5) : Theme.cardBorder,
                                lineWidth: origin != nil ? 1 : 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
                    .onTapGesture {
                        guard installable || updatable else { return }
                        installOverwrite = updatable
                        installTarget = source
                    }
                    .help(installable
                        ? L10n.format("Copy this skill to %@", zhHans: "把该技能复制到 %@", source.displayName)
                        : updatable
                            ? L10n.format(
                                "Overwrite %@'s same-named skill with the current version (the old one moves to the Trash)",
                                zhHans: "用当前版本覆盖更新 %@ 的同名技能（旧版移入废纸篓）",
                                source.displayName)
                            : source.displayName)
                }
            }
            if let note = installNote {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .confirmationDialog(
            installOverwrite
                ? L10n.format(
                    "Overwrite %@'s same-named skill?",
                    zhHans: "覆盖更新 %@ 的同名技能？",
                    installTarget?.displayName ?? "")
                : L10n.format(
                    "Install to %@?",
                    zhHans: "安装到 %@？",
                    installTarget?.displayName ?? ""),
            isPresented: Binding(
                get: { installTarget != nil },
                set: { if !$0 { installTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button(installOverwrite ? L10n.text("Overwrite (old version moves to the Trash)", zhHans: "覆盖更新（旧版移入废纸篓）") : L10n.text("Copy the skill directory over", zhHans: "复制技能目录过去")) {
                runInstall()
            }
            Button(L10n.text("Cancel", zhHans: "取消"), role: .cancel) {}
        } message: {
            if let target = installTarget {
                Text(installOverwrite
                    ? L10n.format(
                        "The current version will replace the same-named skill directory under\n%@. The old version moves to the Trash and can be restored.",
                        zhHans: "将用当前版本整体替换\n%@ 下的同名技能目录，旧版本移入废纸篓（可恢复）",
                        SkillMemoryService.writableSkillRoot(for: target).path)
                    : L10n.format(
                        "The whole skill directory will be copied to\n%@",
                        zhHans: "将把整个技能目录复制到\n%@",
                        SkillMemoryService.writableSkillRoot(for: target).path))
            }
        }
    }

    /// Performs the cross-source install/overwrite update (after confirmationDialog); the result is
    /// shown briefly below the matrix
    private func runInstall() {
        guard let installTo = installTarget, let entry else { return }
        installTarget = nil
        let overwrite = installOverwrite
        let targetName = installTo.displayName
        installNote = overwrite
            ? L10n.format("Updating %@…", zhHans: "正在更新到 %@…", targetName)
            : L10n.format("Installing to %@…", zhHans: "正在安装到 %@…", targetName)
        service.propagate(entry, to: [installTo], overwrite: overwrite) { results in
            if let failure = results[installTo] ?? nil {
                installNote = overwrite
                    ? L10n.format(
                        "Update to %1$@ failed: %2$@",
                        zhHans: "更新到 %1$@ 失败：%2$@",
                        targetName, failure)
                    : L10n.format(
                        "Install to %1$@ failed: %2$@",
                        zhHans: "安装到 %1$@ 失败：%2$@",
                        targetName, failure)
            } else if installTo == .zcode {
                installNote = overwrite
                    ? L10n.format(
                        "Updated %@ (~/.agents/skills is a shared directory, so other compatible CLIs will read it too)",
                        zhHans: "已更新到 %@（~/.agents/skills 为共享目录，其他兼容 CLI 也会读到）",
                        targetName)
                    : L10n.format(
                        "Installed to %@ (~/.agents/skills is a shared directory, so other compatible CLIs will read it too)",
                        zhHans: "已安装到 %@（~/.agents/skills 为共享目录，其他兼容 CLI 也会读到）",
                        targetName)
            } else {
                installNote = overwrite
                    ? L10n.format("Updated %@", zhHans: "已更新到 %@", targetName)
                    : L10n.format("Installed to %@", zhHans: "已安装到 %@", targetName)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { installNote = nil }
        }
    }

    private func originLabel(_ origin: SkillOrigin?) -> String {
        switch origin {
        case .user: return L10n.text("Custom", zhHans: "自建")
        case .bundled: return L10n.text("Built-in", zhHans: "内置")
        case nil: return L10n.text("Not configured", zhHans: "未配置")
        }
    }

    private func originColor(_ origin: SkillOrigin?) -> Color {
        switch origin {
        case .user: return .green
        case .bundled: return .blue
        case nil: return .secondary
        }
    }

    // MARK: - Call stats

    private var statsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle(L10n.text("Call statistics", zhHans: "调用统计"))
            if let stat {
                HStack(spacing: 8) {
                    metricTile(L10n.text("Total calls", zhHans: "累计调用"), L10n.format("%@ times", zhHans: "%@ 次", String(stat.count)), valueColor: Theme.brandFg)
                    if target.source == .claude {
                        metricTile(L10n.text("Tokens at trigger", zhHans: "触发时 token"), formatTokens(stat.tokens))
                    }
                    if let last = stat.lastTs {
                        metricTile(L10n.text("Last active", zhHans: "最近活跃"),
                            relativeFormatter.localizedString(for: last, relativeTo: Date()))
                    }
                    if let weeklyRank {
                        metricTile(L10n.text("Rank this week", zhHans: "本周排名"), "#\(weeklyRank)", gold: true)
                    }
                }
                if target.source == .claude {
                    Text(L10n.text("Tokens at trigger ≈ the context size of that turn, not the cost of running the whole skill", zhHans: "触发时 token ≈ 调用当轮上下文规模，非技能整段执行开销"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                trendChart
            } else {
                Text(target.source == .claude
                    ? L10n.text("No recent calls", zhHans: "近期暂无调用记录")
                    : L10n.text("This source has no per-skill call data (only Claude can be counted)", zhHans: "该来源无逐技能调用数据（仅 Claude 可统计）"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            if !recentSessions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle(L10n.text("Recent calling sessions", zhHans: "最近调用会话"))
                    ForEach(recentSessions, id: \.sessionId) { row in
                        recentSessionRow(row)
                    }
                }
                // sessionIndexVersion changes once the sessionBrowser index is built, forcing this
                // sub-section to rebuild so each row's info is recomputed (otherwise greyed
                // unreachable rows never heal to clickable)
                .id(sessionIndexVersion)
            }
        }
    }

    private func recentSessionRow(
        _ row: (sessionId: String, lastTs: Date, count: Int)
    ) -> some View {
        let info = sessionBrowser?.sessionsById[row.sessionId]
        return HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 10))
                .foregroundStyle(info == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Theme.brandFg))
            Text(info?.displayName ?? L10n.format("Session %@ (unavailable)", zhHans: "会话 %@（已不可达）", String(row.sessionId.prefix(8))))
                .font(Theme.font.themed(11.5))
                .foregroundStyle(info == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(L10n.format("%@ times", zhHans: "%@ 次", String(row.count)))
                .font(Theme.font.themedMono(10.5))
                .foregroundStyle(.tertiary)
            Text(relativeFormatter.localizedString(for: row.lastTs, relativeTo: Date()))
                .font(Theme.font.themed(10.5))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard info != nil else { return }
            NotificationCenter.default.post(name: .eurekaRevealSession, object: row.sessionId)
        }
        .help(info == nil ? L10n.text("The session record was deleted or is outside the current index", zhHans: "会话记录已删除或不在当前索引范围") : L10n.text("Jump to this session", zhHans: "跳到该会话"))
    }

    @ViewBuilder
    private var trendChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.text("Calls in the last 30 days", zhHans: "近 30 天调用"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            if series.isEmpty {
                Text(L10n.text("No calls in the last 30 days", zhHans: "近 30 天无调用"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                Chart(series) { point in
                    BarMark(
                        x: .value(L10n.text("Date", zhHans: "日期"), point.day, unit: .day),
                        y: .value(L10n.text("Calls", zhHans: "调用"), point.count))
                    // Global purple-gold: chart bars don't use CLI brand colors
                    .foregroundStyle(Theme.chartBarGradient)
                }
                .frame(height: 120)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            }
        }
    }

    // MARK: - helpers

    private func loadText() {
        guard !textLoaded, let entry else { return }
        text = service.readContent(path: entry.path) ?? ""
        textLoaded = true
    }

    private func loadSeries() {
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: to) ?? to
        // The series is queried by the raw call name stored in tool_calls (stat.name is exact;
        // falls back to target.name)
        let queryName = stat?.name ?? target.name
        usageService.loadSkillDailySeries(
            source: target.source, name: queryName, from: from, to: to
        ) { points in
            series = points
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func metricTile(
        _ label: String, _ value: String,
        valueColor: Color = .primary, gold: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(gold ? Theme.goldFg.opacity(0.9) : Color.primary.opacity(0.35))
            Text(value)
                .font(Theme.font.statNumber(18))
                .foregroundStyle(gold ? Theme.goldFg : valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // This week's rank = gold tile; others = white fill + thin stroke
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .fill(gold ? Theme.gold.opacity(0.12) : Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container)
                .strokeBorder(gold ? Theme.gold.opacity(0.4) : Theme.cardBorder,
                              lineWidth: 0.5))
    }
}
