import Charts
import Combine
import EurekaIngest
import EurekaKit
import EurekaStore
import SwiftUI

/// The right pane of the Skills shell: everything about one skill group, top to bottom —
/// what it is, its state, the actions, the description, the SKILL.md text, usage, where
/// each copy lives, and the file facts. Every action is a labelled button; nothing is
/// hidden behind hover.
struct SkillDetailPane: View {
    let group: SkillGroup
    /// The copy whose file to show; nil = the group's primary.
    var focusedCopyPath: String? = nil
    @ObservedObject var service: SkillMemoryService
    @ObservedObject var usageService: UsageService
    var sessionBrowser: SessionBrowserService? = nil
    /// Narrow (single-pane) mode: shows a back button in the header.
    var onBack: (() -> Void)? = nil
    let onDelete: (SkillEntry) -> Void

    @State private var text = ""
    @State private var expanded = false
    @State private var editing = false
    @State private var draft = ""
    @State private var saveNote: String?
    @State private var series: [UsageService.SkillDayCount] = []
    @State private var weeklyRank: Int?
    @State private var recentSessions: [(sessionId: String, lastTs: Date, count: Int)] = []
    @State private var installTarget: AgentSource?
    @State private var installNote: String?
    @State private var showMore = false
    @State private var showInstall = false
    @State private var sessionIndexVersion = 0

    private var hard: Bool { ThemeStyle.current.isHardEdged }

    /// The copy on display. Enabling / disabling moves the directory, so re-resolve it
    /// from the service by source + project + directory name on every render.
    private var copy: SkillEntry {
        let base = group.copies.first { $0.path == focusedCopyPath } ?? group.primary
        let dir = URL(fileURLWithPath: base.directory).lastPathComponent
        return service.skills.first {
            $0.source == base.source
                && $0.scope.projectName == base.scope.projectName
                && URL(fileURLWithPath: $0.directory).lastPathComponent == dir
        } ?? base
    }

    private var stat: ToolCallsRepo.SkillUsageStat? {
        let key = SkillGrouping.usageKey(source: copy.source, name: copy.name)
        let dirKey = SkillGrouping.usageKey(
            source: copy.source, name: URL(fileURLWithPath: copy.directory).lastPathComponent)
        return usageService.skillStats.first {
            let k = SkillGrouping.usageKey(source: $0.source, name: $0.name)
            return k == key || k == dirKey
        }
    }

    /// Sources without any copy of this skill (install targets).
    private var unconfigured: [AgentSource] {
        let configured = service.configurations(forName: group.name)
        return AgentSource.allCases.filter { configured[$0] == nil }
    }

    private var lineCount: Int { text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count }
    private var isLong: Bool { lineCount > 28 }

    // MARK: - Body

    var body: some View {
        KnowledgePane {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    statusLine
                    actions
                    whatSection
                    fullTextSection
                    usageSection
                    installedSection
                    fileSection
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: load)
        .onReceive(
            sessionBrowser?.objectWillChange.eraseToAnyPublisher()
                ?? Empty<Void, Never>().eraseToAnyPublisher()
        ) { _ in sessionIndexVersion &+= 1 }
        .themedConfirm(
            L10n.format("Install to %@?", zhHans: "安装到 %@？", installTarget?.displayName ?? ""),
            isPresented: Binding(get: { installTarget != nil }, set: { if !$0 { installTarget = nil } }),
            message: installTarget.map { target in
                L10n.format(
                    "The whole skill folder will be copied to\n%@",
                    zhHans: "将把整个技能目录复制到\n%@",
                    SkillMemoryService.writableSkillRoot(for: target).path)
            },
            confirm: L10n.text("Copy the skill folder over", zhHans: "复制技能目录过去")
        ) { runInstall() }
    }

    // MARK: - Header / status / actions

    private var header: some View {
        HStack(spacing: 12) {
            if let onBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(Theme.font.themed(12, .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 26, height: 26)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.tile, style: .continuous)
                                .fill(Theme.surfaceSecondary))
                }
                .buttonStyle(.plain)
                .help(L10n.text("Back to the list", zhHans: "返回清单"))
            }
            SourceLogoTile(source: copy.source, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(Theme.font.themed(17, .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(scopeLine)
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            stateControl
        }
    }

    /// The one control people reach for most: the switch, with its state written next to it.
    /// A group with several copies has one switch per copy further down, so it shows the tally.
    @ViewBuilder private var stateControl: some View {
        if group.copies.count == 1 {
            HStack(spacing: 8) {
                Text(copy.enabled ? L10n.text("Enabled", zhHans: "已启用") : L10n.text("Disabled", zhHans: "已停用"))
                    .font(Theme.font.themed(12, .medium))
                    .foregroundStyle(copy.enabled ? .primary : Theme.textSecondary)
                MiniSwitch(isOn: copy.enabled) { service.setSkillEnabled(copy, !copy.enabled) }
            }
            .help(copy.enabled
                ? L10n.text("Turn off: the tool stops reading this skill, the files stay", zhHans: "关掉后工具不再读取这个技能，文件仍保留")
                : L10n.text("Turn on: the tool uses this skill again", zhHans: "打开后工具会重新使用这个技能"))
        } else {
            Text(L10n.format("%1$@ of %2$@ copies on", zhHans: "%2$@ 份里 %1$@ 份已启用",
                             String(group.enabledCount), String(group.copies.count)))
                .font(Theme.font.themed(12, .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var scopeLine: String {
        let where_: String
        if let project = group.projectName {
            where_ = L10n.format("only in %@", zhHans: "只在 %@ 项目里可用", project)
        } else {
            where_ = L10n.text("available in every project", zhHans: "所有项目都能用")
        }
        if group.sources.count > 1 || group.copies.count > 1 {
            return L10n.format("Installed in %@ tools", zhHans: "装在 %@ 个工具里", String(group.sources.count))
                + " · " + where_
        }
        return copy.source.displayName + " · " + where_
    }

    private var statusLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(group.isAllDisabled ? Theme.textTertiary : Theme.enabledGreen)
                .frame(width: 8, height: 8)
                .overlay(Group {
                    if let outline = Theme.controlOutline {
                        Circle().strokeBorder(outline.color, lineWidth: 1.5)
                    }
                })
            Text(statusText)
                .font(Theme.font.themed(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
        }
    }

    private var statusText: String {
        let total = group.copies.count
        if group.isAllDisabled {
            return L10n.format("Disabled · %@ no longer reads it, the files stay",
                               zhHans: "已停用 · %@ 不会再读取它，文件仍保留", copy.source.displayName)
        }
        if total == 1 {
            return L10n.format("Enabled · %@ uses it automatically when relevant",
                               zhHans: "已启用 · %@ 会在需要时自动使用它", copy.source.displayName)
        }
        if group.isAllEnabled {
            return L10n.format("All %@ copies enabled · each copy has its own switch below",
                               zhHans: "%@ 份都已启用 · 每份在下方各有自己的开关", String(total))
        }
        return L10n.format("%1$@ of %2$@ copies enabled · each copy has its own switch below",
                           zhHans: "%2$@ 份里 %1$@ 份已启用 · 每份在下方各有自己的开关",
                           String(group.enabledCount), String(total))
    }

    /// Three things, each saying what it does: edit the text here, open it in the editor,
    /// everything else behind "More". Enable / disable lives on the switch in the header.
    private var actions: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            PaneButton(L10n.text("Edit the text", zhHans: "编辑说明"), icon: "pencil", kind: .primary) {
                draft = text
                expanded = true
                editing = true
            }
            .help(L10n.text("Edit SKILL.md right here, below", zhHans: "在下面直接修改 SKILL.md"))
            PaneButton(L10n.text("Open in editor", zhHans: "用编辑器打开"), icon: "arrow.up.forward.app") {
                service.openInEditor(path: copy.path)
            }
            .help(L10n.text("Open SKILL.md in your default editor", zhHans: "用系统默认编辑器打开 SKILL.md"))
            moreMenu
        }
    }

    private var moreMenu: some View {
        Button {
            showMore.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "ellipsis").font(Theme.font.themed(12, .semibold))
                Text(L10n.text("More", zhHans: "更多")).font(Theme.font.themed(12.5))
            }
            .foregroundStyle(.primary)
            .modifier(PopupButtonChrome(height: 30, horizontalPadding: 13))
        }
        .buttonStyle(.plain)
        .themedPopup(isPresented: $showMore) {
            PopupList {
                PopupRow(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"), systemImage: "folder") {
                    showMore = false
                    service.reveal(path: copy.path)
                }
                PopupRow(L10n.text("Copy folder path", zhHans: "复制目录路径"), systemImage: "doc.on.doc") {
                    showMore = false
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copy.directory, forType: .string)
                }
                Divider().padding(.vertical, 3)
                PopupRow(L10n.text("Move to Trash…", zhHans: "移到废纸篓…"), systemImage: "trash", destructive: true) {
                    showMore = false
                    onDelete(copy)
                }
            }
        }
    }

    /// Pop-up of the tools that do not have this skill yet; picking one asks before copying.
    private func installMenu(compact: Bool) -> some View {
        Button {
            showInstall.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(compact
                    ? L10n.text("Install…", zhHans: "安装到…")
                    : L10n.text("Install to other tools", zhHans: "安装到其他工具"))
                    .font(Theme.font.themed(compact ? 11 : 12))
                Image(systemName: "chevron.down").font(Theme.font.themed(9, .semibold))
                    .foregroundStyle(Theme.textSecondary)
            }
            .foregroundStyle(.primary)
            .modifier(PopupButtonChrome(height: compact ? 24 : 28, horizontalPadding: compact ? 9 : 11))
        }
        .buttonStyle(.plain)
        .themedPopup(isPresented: $showInstall) {
            PopupList(title: L10n.text("Copy this skill to", zhHans: "把这个技能复制到")) {
                ForEach(unconfigured, id: \.self) { source in
                    PopupRow(source.displayName, leading: { SourceBadge(source: source, size: 14) }) {
                        showInstall = false
                        installTarget = source
                    }
                }
            }
        }
    }

    // MARK: - Sections

    private var whatSection: some View {
        section(L10n.text("What it does", zhHans: "它是做什么的")) {
            Text(copy.description?.isEmpty == false
                ? copy.description!
                : L10n.text("SKILL.md has no description.", zhHans: "SKILL.md 里没有写描述。"))
                .font(Theme.font.themed(12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 620, alignment: .leading)
            Text(L10n.format("%@ decides when to use it from this description.",
                             zhHans: "%@ 根据这段描述决定什么时候用它。", copy.source.displayName))
                .font(Theme.font.themed(11))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var fullTextSection: some View {
        section(L10n.text("Full text (SKILL.md)", zhHans: "完整说明（SKILL.md）"), trailing: {
            HStack(spacing: 8) {
                Text(L10n.format("%@ lines · %@", zhHans: "%@ 行 · %@",
                                 String(lineCount), byteCount(copy.sizeBytes)))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.textTertiary)
                if editing {
                    PaneButton(L10n.text("Save", zhHans: "保存"), kind: .primary, small: true) { save() }
                    PaneButton(L10n.text("Cancel", zhHans: "取消"), small: true) {
                        draft = text
                        editing = false
                    }
                }
            }
        }) {
            if editing {
                TextEditor(text: $draft)
                    .font(Theme.font.code(12))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 280)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(Theme.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            } else {
                ZStack(alignment: .bottom) {
                    MarkdownRichText(text: previewText)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: expanded || !isLong ? nil : 300, alignment: .top)
                        .clipped()
                    if isLong && !expanded {
                        if hard {
                            Rectangle().fill(Theme.hairline).frame(height: 2)
                        } else {
                            LinearGradient(
                                colors: [Theme.surface.opacity(0), Theme.surface],
                                startPoint: .top, endPoint: .bottom)
                                .frame(height: 60)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                        .fill(Theme.surface))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                if isLong {
                    HStack(spacing: 8) {
                        PaneButton(expanded
                            ? L10n.text("Collapse", zhHans: "收起")
                            : L10n.text("Show all", zhHans: "展开全文"), small: true) {
                            withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                        }
                        if !expanded {
                            Text(L10n.text("Only the first 300pt is shown so usage and install locations stay in reach.",
                                           zhHans: "默认只展开前 300pt，避免把下面的用量和安装位置埋到几千行之后。"))
                                .font(Theme.font.themed(10.5))
                                .foregroundStyle(Theme.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
            if let saveNote {
                Text(saveNote).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var usageSection: some View {
        section(L10n.text("Usage", zhHans: "使用情况")) {
            Text(usageSentence)
                .font(Theme.font.themed(12.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: 620, alignment: .leading)
            if !series.isEmpty {
                Chart(series) { point in
                    BarMark(
                        x: .value(L10n.text("Date", zhHans: "日期"), point.day, unit: .day),
                        y: .value(L10n.text("Calls", zhHans: "次数"), point.count))
                        .foregroundStyle(Theme.brand)
                        .cornerRadius(hard ? 0 : 2)
                }
                .chartXAxis(.hidden)
                .chartYAxis { AxisMarks(values: .automatic(desiredCount: 2)) }
                .frame(height: 72)
                .frame(maxWidth: 520)
                HStack {
                    Text(L10n.text("30 days ago", zhHans: "30 天前"))
                    Spacer()
                    Text(L10n.text("how many times per day", zhHans: "每天用了几次"))
                    Spacer()
                    Text(L10n.text("today", zhHans: "今天"))
                }
                .font(Theme.font.themedMono(9.5))
                .foregroundStyle(Theme.textTertiary)
                .frame(maxWidth: 520)
            }
            if !recentSessions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(recentSessions, id: \.sessionId) { row in
                        sessionRow(row)
                        if row.sessionId != recentSessions.last?.sessionId { Divider() }
                    }
                }
                .id(sessionIndexVersion)
            }
        }
    }

    private var usageSentence: String {
        guard let stat, stat.count > 0 else {
            return L10n.text("No calls recorded yet.", zhHans: "还没有使用记录。")
        }
        var parts: [String] = []
        if let last = stat.lastTs {
            parts.append(L10n.format(
                "Used %@ times, last %@.", zhHans: "用过 %@ 次，最近一次在%@。",
                String(stat.count), relativeFormatter.localizedString(for: last, relativeTo: Date())))
        } else {
            parts.append(L10n.format("Used %@ times.", zhHans: "用过 %@ 次。", String(stat.count)))
        }
        if let weeklyRank {
            parts.append(L10n.format("Ranked #%@ among all skills this week.",
                                     zhHans: "本周在所有技能里排第 %@。", String(weeklyRank)))
        }
        if copy.source == .claude, stat.tokens > 0 {
            parts.append(L10n.format(
                "When it triggered, the conversation already held about %@ tokens (the conversation's size at the time, not the skill's own cost).",
                zhHans: "触发它的时候，对话平均已有 %@ token（这是当时的对话规模，不是技能本身的花费）。",
                formatTokens(stat.tokens)))
        }
        return parts.joined(separator: " ")
    }

    private func sessionRow(_ row: (sessionId: String, lastTs: Date, count: Int)) -> some View {
        let info = sessionBrowser?.sessionsById[row.sessionId]
        return Button {
            guard info != nil else { return }
            NotificationCenter.default.post(name: .eurekaRevealSession, object: row.sessionId)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(info?.displayName
                        ?? L10n.format("Session %@", zhHans: "会话 %@", String(row.sessionId.prefix(8))))
                        .font(Theme.font.themed(12))
                        .foregroundStyle(info == nil ? Theme.textTertiary : .primary)
                        .lineLimit(1)
                    Text(L10n.format("%@ times · %@", zhHans: "%@ 次 · %@", String(row.count),
                                     relativeFormatter.localizedString(for: row.lastTs, relativeTo: Date()))
                        + (info == nil ? " · " + L10n.text("record no longer available", zhHans: "记录已不在") : ""))
                        .font(Theme.font.themed(10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 8)
                if info != nil {
                    Text(L10n.text("Open session", zhHans: "打开会话"))
                        .font(Theme.font.themed(11))
                        .foregroundStyle(Theme.brandFg)
                    Image(systemName: "chevron.right")
                        .font(Theme.font.themed(10, .semibold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var installedSection: some View {
        section(L10n.text("Installed in", zhHans: "装在哪里")) {
            VStack(spacing: 0) {
                ForEach(group.copies) { entry in
                    copyRow(entry)
                    if entry.id != group.copies.last?.id { Divider() }
                }
            }
            if !unconfigured.isEmpty {
                HStack(spacing: 6) {
                    Text(L10n.text("Can also be installed to", zhHans: "还可以装到"))
                        .font(Theme.font.themed(11.5))
                        .foregroundStyle(Theme.textSecondary)
                    ForEach(unconfigured.prefix(6), id: \.self) { source in
                        SourceLogoTile(source: source, size: 22).opacity(0.45)
                            .help(source.displayName)
                    }
                    installMenu(compact: true)
                }
            }
            if let installNote {
                Text(installNote).font(Theme.font.themed(10.5)).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func copyRow(_ entry: SkillEntry) -> some View {
        let live = service.skills.first { $0.source == entry.source && $0.directory == entry.directory } ?? entry
        return HStack(spacing: 10) {
            SourceBadge(source: live.source, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(abbreviateHome(live.path))
                    .font(Theme.font.code(11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(live.source.displayName + " · "
                    + (live.scope.projectName.map { L10n.format("project %@", zhHans: "项目 %@", $0) }
                        ?? L10n.text("global", zhHans: "全局")))
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 8)
            Text(live.enabled ? L10n.text("Enabled", zhHans: "已启用") : L10n.text("Disabled", zhHans: "已停用"))
                .font(Theme.font.themed(11))
                .foregroundStyle(Theme.textSecondary)
            MiniSwitch(isOn: live.enabled) { service.setSkillEnabled(live, !live.enabled) }
        }
        .frame(height: 40)
    }

    private var fileSection: some View {
        section(L10n.text("File", zhHans: "文件")) {
            VStack(spacing: 0) {
                kvRow(L10n.text("Location", zhHans: "位置"), abbreviateHome(copy.directory), mono: true)
                Divider()
                kvRow(L10n.text("Contains", zhHans: "包含"), containsText)
                Divider()
                kvRow(L10n.text("Size", zhHans: "大小"), byteCount(copy.sizeBytes))
                Divider()
                kvRow(L10n.text("Modified", zhHans: "修改时间"), Self.dateFormatter.string(from: copy.modifiedAt))
            }
        }
    }

    private var containsText: String {
        let items = (try? FileManager.default.contentsOfDirectory(atPath: copy.directory)) ?? []
        let others = items.filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.count
        return others == 0
            ? "SKILL.md"
            : L10n.format("SKILL.md · %@ other files", zhHans: "SKILL.md · 另有 %@ 个文件", String(others))
    }

    // MARK: - Building blocks

    private func section<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        section(title, trailing: { EmptyView() }, content: content)
    }

    private func section<Content: View, Trailing: View>(
        _ title: String,
        @ViewBuilder trailing: () -> Trailing,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack(spacing: 8) {
                Text(title).font(Theme.font.themed(12.5, .semibold))
                Spacer(minLength: 8)
                trailing()
            }
            .padding(.top, 4)
            content()
        }
    }

    private func kvRow(_ key: String, _ value: String, mono: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(key).font(Theme.font.themed(12)).foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(mono ? Theme.font.code(11) : Theme.font.themed(12))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(height: 32)
    }

    private func abbreviateHome(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func byteCount(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // MARK: - Loading / actions

    /// The YAML frontmatter (name / description) is already shown in the header and the
    /// "What it does" section, so the preview starts at the body. Editing still works on
    /// the full file.
    private var previewText: String {
        guard text.hasPrefix("---") else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1,
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        text = service.readContent(path: copy.path) ?? ""
        draft = text
        let queryName = stat?.name ?? copy.name
        let to = Date()
        let from = Calendar.current.date(byAdding: .day, value: -30, to: to) ?? to
        usageService.loadSkillDailySeries(source: copy.source, name: queryName, from: from, to: to) { series = $0 }
        usageService.loadSkillWeeklyRank(source: copy.source, name: queryName) { weeklyRank = $0 }
        usageService.loadSkillSessions(source: copy.source, name: queryName) { recentSessions = $0 }
        if let sessionBrowser, sessionBrowser.sessionsById.isEmpty { sessionBrowser.refresh() }
    }

    private func save() {
        let path = copy.path
        service.save(path: path, content: draft) { ok in
            if ok {
                text = draft
                editing = false
                saveNote = L10n.text("Saved", zhHans: "已保存")
            } else {
                saveNote = L10n.text("Save failed", zhHans: "保存失败")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
        }
    }

    private func runInstall() {
        guard let target = installTarget else { return }
        installTarget = nil
        service.propagate(copy, to: [target]) { results in
            if let failure = results[target] ?? nil {
                installNote = L10n.format("Install to %@ failed: %@", zhHans: "安装到 %@ 失败：%@", target.displayName, failure)
            } else {
                installNote = L10n.format("Installed to %@", zhHans: "已安装到 %@", target.displayName)
            }
        }
    }
}

// MARK: - Buttons

enum PaneButtonKind { case primary, normal, quiet, destructive }

/// Labelled action button of the detail pane. Primary = brand fill; normal = surface with
/// the card border; quiet = text only; destructive = failure-red fill for irreversible
/// confirmations. Brutal adds the ink outline and the hard shadow.
struct PaneButton: View {
    let title: String
    var icon: String?
    var kind: PaneButtonKind = .normal
    var small = false
    let action: () -> Void

    init(_ title: String, icon: String? = nil, kind: PaneButtonKind = .normal, small: Bool = false,
         action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.small = small
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            PaneButtonLabel(title, icon: icon, kind: kind, small: small)
        }
        .buttonStyle(.plain)
    }
}

struct PaneButtonLabel: View {
    let title: String
    var icon: String?
    var kind: PaneButtonKind = .normal
    var chevron = false
    var small = false

    init(_ title: String, icon: String? = nil, kind: PaneButtonKind = .normal, chevron: Bool = false,
         small: Bool = false) {
        self.title = title
        self.icon = icon
        self.kind = kind
        self.chevron = chevron
        self.small = small
    }

    private var hard: Bool { ThemeStyle.current.isHardEdged }

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(Theme.font.themed(small ? 10 : 11.5, .semibold))
            }
            Text(title).font(Theme.font.themed(
                small ? 11 : 12.5, kind == .primary || kind == .destructive ? .medium : .regular))
            if chevron {
                Image(systemName: "chevron.down").font(Theme.font.themed(9, .semibold))
            }
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, small ? 9 : 13)
        .frame(height: small ? 24 : 30)
        // The hard (zero-blur) brutal shadow goes on the shape layer only; on a view
        // that contains text it double-prints the glyphs.
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(fill)
                .themeControlShadow(active: kind != .quiet))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .strokeBorder(border, lineWidth: borderWidth))
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.onBrand
        case .normal: return .primary
        case .quiet: return Theme.textSecondary
        case .destructive: return .white
        }
    }

    private var fill: Color {
        switch kind {
        case .primary: return Theme.brand
        case .normal: return Theme.surface
        case .quiet: return .clear
        case .destructive: return Theme.failureRed
        }
    }

    private var border: Color {
        switch kind {
        case .primary: return hard ? Theme.ink : Theme.brand
        case .normal: return Theme.cardBorder
        case .quiet: return .clear
        case .destructive: return hard ? Theme.ink : Theme.failureRed
        }
    }

    private var borderWidth: CGFloat {
        kind == .quiet ? 0 : (hard ? Theme.cardBorderWidth : 0.5)
    }
}
