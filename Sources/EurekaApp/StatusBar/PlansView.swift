import EurekaIngest
import EurekaKit
import SwiftUI

/// Plan browser: card grid + source filter. "Project plans" (plan docs inside repos) sit at the
/// same level as each tool's source section.
/// Claude plans come from ~/.claude/plans; Codex/opencode etc. are materialized from sessions/
/// databases by PlanMaterializer.
struct PlansView: View {
    @ObservedObject var service: PlansService

    /// Plan shown in the embedded detail page (nil = list)
    @State private var detail: PlanMaterializer.PlanEntry?
    @State private var deleting: PlanMaterializer.PlanEntry?
    /// Source filter (nil = all)
    @State private var selectedSource: AgentSource?
    /// Management area layout: list / icon grid (list by default, matching the design mock)
    @State private var layout: KnowledgeLayout = .list

    /// Offscreen rendering/preview only: sets the initial layout (LayoutToggle switches it
    /// interactively)
    init(service: PlansService, initialLayout: KnowledgeLayout = .list) {
        self._service = ObservedObject(wrappedValue: service)
        self._layout = State(initialValue: initialLayout)
    }

    /// Flat list after search + source filtering (sorted by most recently modified first)
    private var filtered: [PlanMaterializer.PlanEntry] {
        service.plans
            .filter { selectedSource == nil || $0.source == selectedSource }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    var body: some View {
        Group {
            if let plan = detail {
                PlanDetailView(
                    plan: plan, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = plan })
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
            consumeFocus()
        }
        .onChange(of: service.focusPath) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
        .themedConfirm(
            deleting.map { L10n.format("Delete plan “%@”? The file moves to the Trash and can be restored.", zhHans: "删除计划「%@」？文件会移入废纸篓，可恢复。", String($0.title)) } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            confirm: L10n.text("Delete", zhHans: "删除"), destructive: true
        ) {
            if let entry = deleting {
                service.delete(entry)
                if detail?.id == entry.id { detail = nil }
            }
        }
    }

    // MARK: - Top bar (title + search + refresh + layout toggle)

    private var header: some View {
        HStack(spacing: 12) {
            Text("Plans").font(Theme.font.themed(15, .bold))
            SearchField(
                placeholder: L10n.text("Search plans", zhHans: "搜索计划"), text: $service.searchText,
                scanning: service.scanning, resultCount: service.plans.count)
            Spacer(minLength: 12)
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: L10n.text("Force rescan (materialize and index plans again)", zhHans: "强制重扫（重新物化并索引计划）")) { service.refresh(force: true) }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Body (stats overview card + source chips + flat list/grid)

    private let gridColumns = KnowledgeGrid.columns

    @ViewBuilder
    private var content: some View {
        // Filtered and sorted once per render: `filtered` used to be re-evaluated for every row
        // (N rows × filter + sort of N), all on the main thread
        let rows = filtered
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterMenu(
                    selected: $selectedSource,
                    allLabel: L10n.text("All", zhHans: "全部"), allIcon: "list.bullet.clipboard.fill",
                    totalCount: service.totalCount,
                    sources: service.availableSources,
                    count: { service.count(for: $0) },
                    singleLine: true)
                if rows.isEmpty {
                    emptyState.padding(.top, 40)
                } else if layout == .cards {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(rows) { plan in planCard(plan) }
                    }
                } else {
                    KnowledgeListContainer {
                        // Lazy: only the rows on screen are built
                        LazyVStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, plan in
                                PlanRow(
                                    plan: plan, service: service,
                                    onOpen: { open(plan) }, onDelete: { deleting = plan })
                                if index < rows.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 50)
                                }
                            }
                        }
                    }
                }
            }
            .padding(22)
        }
        .background(Theme.surfaceSecondary)
    }

    private var statsCard: some View {
        let counts = service.statusCounts
        return StatOverviewCard(
            value: "\(service.totalCount)",
            unit: L10n.text("plans", zhHans: "计划"),
            subtitle: L10n.format("%@ projects · %@", zhHans: "%@ 项目 · %@", String(service.distinctProjectCount), String(formatBytes(service.totalBytes))),
            distributionTitle: L10n.text("By status", zhHans: "状态分布"),
            segments: [
                .init(label: L10n.text("Done", zhHans: "完成"), count: counts.complete, color: Theme.enabledGreen),
                .init(label: L10n.text("In progress", zhHans: "进行"), count: counts.inProgress, color: Theme.brand),
                .init(label: L10n.text("Draft", zhHans: "草稿"), count: counts.draft, color: Theme.draftGray),
                .init(label: L10n.text("Document", zhHans: "文档"), count: counts.document, color: Theme.autoCleanGray),
            ])
    }

    private func planCard(_ plan: PlanMaterializer.PlanEntry) -> some View {
        PlanCard(plan: plan, service: service,
                 onOpen: { open(plan) }, onDelete: { deleting = plan })
    }

    private func open(_ plan: PlanMaterializer.PlanEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detail = plan }
    }

    /// Cross-page landing: find the plan by path and open its detail (don't clear when not found;
    /// the scan may not have reached it yet)
    private func consumeFocus() {
        guard let path = service.focusPath, let entry = service.entry(atPath: path) else { return }
        withAnimation(.easeOut(duration: 0.15)) { detail = entry }
        service.focusPath = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 10) {
                ProgressView()
                Text(L10n.text("Scanning and extracting plans…", zhHans: "正在扫描并提取计划…"))
                    .font(Theme.font.themed(12))
                    .foregroundStyle(.secondary)
                Text(L10n.text("The first scan parses every Codex session and can take a few minutes;", zhHans: "首次扫描需解析全部 Codex 会话记录，可能需要几分钟；")
                    + L10n.text(" later scans are incremental and finish in seconds. You can switch tabs — scanning continues in the background.", zhHans: "之后为增量扫描，秒级完成。可先切到其他页签，扫描在后台继续。"))
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "list.bullet.clipboard",
                title: service.isSearching || selectedSource != nil ? L10n.text("No matching plans", zhHans: "没有匹配的计划") : L10n.text("No plans yet", zhHans: "还没有计划记录"),
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : L10n.text("Claude plans come from ~/.claude/plans; Codex / OpenCode plans are extracted from session logs;", zhHans: "Claude 计划来自 ~/.claude/plans；Codex / OpenCode 计划从会话记录提取生成；")
                        + L10n.text(" project plans come from each repo’s plans/ and docs/**/plans/ directories", zhHans: "项目计划来自各仓库的 plans/ 与 docs/**/plans/ 目录"))
        }
    }
}

/// Plan status dot / status text color: drafts use a readable gray (distinct from the light gray
/// segment in the distribution bar).
private func planAccentColor(_ status: PlanMaterializer.PlanStatus) -> Color {
    switch status {
    case .draft, .document: return Theme.textTertiary  // quiet states: no hue of their own
    default: return Theme.planStatusColor(status)
    }
}

/// Real files (Claude plans / project docs) are editable and deletable; materialized copies are
/// read-only
private func planIsRealFile(_ plan: PlanMaterializer.PlanEntry) -> Bool {
    plan.source == .claude || plan.kind == .projectDocument
}

private func planActions(
    _ plan: PlanMaterializer.PlanEntry, service: PlansService, onDelete: @escaping () -> Void
) -> [CardAction] {
    var acts: [CardAction] = [
        CardAction(icon: "pencil", help: L10n.text("Open in the default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: plan.path) },
        CardAction(icon: "folder", help: L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: plan.path) },
    ]
    if planIsRealFile(plan) {
        acts.append(CardAction(icon: "trash", destructive: true, help: L10n.text("Move to the Trash (can be restored)", zhHans: "移入废纸篓（可恢复）")) { onDelete() })
    }
    return acts
}

@ViewBuilder
private func planMenu(
    _ plan: PlanMaterializer.PlanEntry, service: PlansService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(planIsRealFile(plan) ? L10n.text("View / edit", zhHans: "查看 / 编辑") : L10n.text("View", zhHans: "查看")) { onOpen() }
    Button(L10n.text("Open in the default editor", zhHans: "用默认编辑器打开")) { service.openInEditor(path: plan.path) }
    Button(L10n.text("Show in Finder", zhHans: "在 Finder 中显示")) { service.reveal(path: plan.path) }
    if planIsRealFile(plan) {
        Divider()
        Button(L10n.text("Delete", zhHans: "删除"), role: .destructive) { onDelete() }
    }
}

/// Plan icon card: same skeleton as the skill card: title monogram (source as corner badge) +
/// title + summary + status/project/time.
/// No progress ring: the card face only says "what it is and what state it's in"; completion is
/// left to the list view.
private struct PlanCard: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeCard(
            minHeight: 92,
            actions: planActions(plan, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    MonogramTile(name: plan.title, source: plan.source, size: 28)
                    // Plan titles are longer than skill names: allow 2 lines and always reserve the
                    // space (equal-height grid)
                    Text(plan.title)
                        .font(Theme.font.themed(13, .semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Circle().fill(planAccentColor(plan.status)).frame(width: 7, height: 7)
                }
                Text(plan.summary ?? "")
                    .font(Theme.font.themed(11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(plan.status.displayName)
                        .font(Theme.font.themed(10.5, .semibold))
                        .foregroundStyle(planAccentColor(plan.status))
                    if let project = plan.project { TagChip(project, neutral: true) }
                    Spacer(minLength: 0)
                    Text(plan.modifiedAt, formatter: relativeFormatter)
                        .font(Theme.font.themed(9.5)).foregroundStyle(.tertiary)
                }
            }
        } menu: {
            planMenu(plan, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }
}

/// Plan list row: title monogram (source as corner badge) + title / project · summary + fixed
/// trailing columns: status · checklist progress · steps · time · size, aligned down the list
/// whether or not a plan has a checklist
private struct PlanRow: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        KnowledgeRow(
            actions: planActions(plan, service: service, onDelete: onDelete), onOpen: onOpen
        ) {
            HStack(spacing: 10) {
                MonogramTile(name: plan.title, source: plan.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(Theme.font.themed(13, .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let project = plan.project {
                            Text(project).font(Theme.font.themed(10.5, .medium)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let summary = plan.summary {
                            Text(summary)
                                .font(Theme.font.themed(10.5)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } trailing: {
            trailing
        } menu: {
            planMenu(plan, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }

    @ViewBuilder private var trailing: some View {
        let checklist = plan.status == .document ? nil : plan.progress
        HStack(spacing: 10) {
            Text(plan.status.displayName)
                .font(Theme.font.themed(11, .semibold))
                .foregroundStyle(planAccentColor(plan.status))
                .lineLimit(1)
                .frame(width: 40, alignment: .leading)
            Group {
                if let checklist {
                    PlanProgressBar(progress: checklist, width: 60)
                } else {
                    Color.clear.frame(width: 60, height: 6)
                }
            }
            // Steps carry the progress on their own; a separate % column would mostly sit empty
            // (most plans are documents without a checklist)
            Text(plan.stepsTotal > 0
                ? L10n.format("%@/%@ steps", zhHans: "%@/%@ 步", String(plan.stepsDone), String(plan.stepsTotal))
                : "")
                .font(Theme.font.themedMono(10.5, .medium)).foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 56, alignment: .trailing)
            Text(plan.modifiedAt, formatter: relativeFormatter)
                .font(Theme.font.themed(10)).foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: 58, alignment: .trailing)
            Text(formatBytes(plan.sizeBytes))
                .font(Theme.font.themedMono(10)).foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// Gold icon tile for the plan card / detail toolbar (project doc = folder, others = doc.text)
private struct PlanIconTile: View {
    let kind: PlanMaterializer.PlanKind
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(Theme.tileBackground)
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        Theme.tileBorder,
                        lineWidth: ThemeStyle.current.isHardEdged ? Theme.cardBorderWidth : 0.5))
            .overlay(
                Image(systemName: kind == .projectDocument ? "folder.fill" : "doc.text")
                    .font(Theme.font.themed(size * 0.42))
                    .foregroundStyle(Theme.textSecondary))
    }
}

// MARK: - Embedded detail page (polished Markdown document rendering; real files are editable)

private struct PlanDetailView: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    let onBack: () -> Void
    let onDelete: () -> Void

    @State private var text: String
    @State private var editing = false
    @State private var saveNote: String?

    init(
        plan: PlanMaterializer.PlanEntry, service: PlansService,
        onBack: @escaping () -> Void, onDelete: @escaping () -> Void
    ) {
        self.plan = plan
        self.service = service
        self.onBack = onBack
        self.onDelete = onDelete
        // Load in init to avoid a blank first frame (plan docs are all small files, so reading them
        // on the main thread is imperceptible)
        _text = State(initialValue: service.readContent(path: plan.path) ?? "")
    }

    private var editable: Bool {
        plan.source == .claude || plan.kind == .projectDocument
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if editing {
                TextEditor(text: $text)
                    .font(Theme.font.themed(12, .regular))
                    .padding(8)
            } else {
                MarkdownDocumentCard(text: text)
            }
            Divider()
            footer
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                HStack(spacing: 3) {
                    Image(systemName: "chevron.left").font(Theme.font.themed(10, .semibold))
                    Text(L10n.text("Back", zhHans: "返回")).font(Theme.font.themed(11))
                }
            }
            .buttonStyle(.borderless)
            if plan.kind == .projectDocument {
                PlanIconTile(kind: plan.kind)
            } else {
                SourceBadge(source: plan.source, size: 14)
            }
            Text(plan.title)
                .font(Theme.font.themed(15, .bold))
                .lineLimit(1)
            if let project = plan.project {
                TagChip(project, neutral: true)
            }
            Spacer(minLength: 8)
            if editable {
                // Segmented "Preview / Edit": selected = white text on purple
                CapsuleTabTray {
                    CapsuleTabButton(
                        title: L10n.text("Preview", zhHans: "预览"), fillWidth: false,
                        isSelected: !editing
                    ) { editing = false }
                    CapsuleTabButton(
                        title: L10n.text("Edit", zhHans: "编辑"), fillWidth: false,
                        isSelected: editing
                    ) { editing = true }
                }
            }
            Button { service.openInEditor(path: plan.path) } label: {
                Image(systemName: "square.and.pencil").font(Theme.font.themed(11))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Open in the default editor", zhHans: "用默认编辑器打开"))
            Button { service.reveal(path: plan.path) } label: {
                Image(systemName: "folder").font(Theme.font.themed(11))
            }
            .buttonStyle(.borderless)
            .help(L10n.text("Show in Finder", zhHans: "在 Finder 中显示"))
            if editable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(Theme.font.themed(11))
                }
                .buttonStyle(.borderless)
                .help(L10n.text("Move to the Trash (can be restored)", zhHans: "移入废纸篓（可恢复）"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(editable
                ? (plan.kind == .projectDocument
                    ? L10n.format("Project document (real file in the repo) · %@", zhHans: "项目文档（仓库内真实文件） · %@", String(plan.path)) : plan.path)
                : L10n.format("Materialized copy (read-only, rebuilt each scan) · %@", zhHans: "物化副本（只读，每轮扫描自动重建） · %@", String(plan.path)))
                .font(Theme.font.themed(9, .regular))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let note = saveNote {
                Text(note)
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.secondary)
            }
            if editing {
                PrimaryButton(title: L10n.text("Save", zhHans: "保存"), shortcut: KeyboardShortcut("s", modifiers: .command)) {
                    service.save(path: plan.path, content: text) { ok in
                        saveNote = ok ? L10n.text("Saved (backup kept before writing)", zhHans: "已保存（写前留有备份）") : L10n.text("Couldn’t save", zhHans: "保存失败")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveNote = nil }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }
}
