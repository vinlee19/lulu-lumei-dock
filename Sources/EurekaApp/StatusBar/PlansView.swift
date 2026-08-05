import EurekaIngest
import EurekaKit
import SwiftUI

/// 计划浏览：卡片网格 + 来源筛选。「项目计划」（仓库内 plan 文档）与各工具来源分区平级展示。
/// Claude 计划来自 ~/.claude/plans；Codex/opencode 等由 PlanMaterializer 从会话/库物化而来。
struct PlansView: View {
    @ObservedObject var service: PlansService

    /// 内嵌详情页当前展示的计划（nil = 列表）
    @State private var detail: PlanMaterializer.PlanEntry?
    @State private var deleting: PlanMaterializer.PlanEntry?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?
    /// 管理区布局：列表 / 图标网格（默认列表，对齐设计稿）
    @State private var layout: KnowledgeLayout = .list

    /// 离屏渲染/预览专用：指定初始布局（交互时由 LayoutToggle 切换）
    init(service: PlansService, initialLayout: KnowledgeLayout = .list) {
        self._service = ObservedObject(wrappedValue: service)
        self._layout = State(initialValue: initialLayout)
    }

    /// 搜索 + 来源筛选后的扁平列表（按最近修改降序）
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
        .confirmationDialog(
            deleting.map { "删除计划「\($0.title)」？文件会移入废纸篓，可恢复。" } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let entry = deleting {
                    service.delete(entry)
                    if detail?.id == entry.id { detail = nil }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏（标题 + 搜索 + 刷新 + 布局切换）

    private var header: some View {
        HStack(spacing: 12) {
            Text("Plans").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: "搜索计划", text: $service.searchText,
                scanning: service.scanning, resultCount: service.plans.count)
            Spacer(minLength: 12)
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: "强制重扫（重新物化并索引计划）") { service.refresh(force: true) }
            LayoutToggle(layout: $layout)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 主体（统计概览卡 + 来源 chips + 扁平列表/网格）

    private let gridColumns = [GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14),
                               GridItem(.flexible(), spacing: 14)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: "全部", allIcon: "list.bullet.clipboard.fill",
                    totalCount: service.totalCount,
                    sources: service.availableSources,
                    count: { service.count(for: $0) })
                if filtered.isEmpty {
                    emptyState.padding(.top, 40)
                } else if layout == .cards {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
                        ForEach(filtered) { plan in planCard(plan) }
                    }
                } else {
                    KnowledgeListContainer {
                        VStack(spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, plan in
                                PlanRow(
                                    plan: plan, service: service,
                                    onOpen: { open(plan) }, onDelete: { deleting = plan })
                                if index < filtered.count - 1 {
                                    Divider().opacity(0.4).padding(.leading, 46)
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
            unit: "计划",
            subtitle: "\(service.distinctProjectCount) 项目 · \(formatBytes(service.totalBytes))",
            distributionTitle: "状态分布",
            segments: [
                .init(label: "完成", count: counts.complete, color: Theme.enabledGreen),
                .init(label: "进行", count: counts.inProgress, color: Theme.brand),
                .init(label: "草稿", count: counts.draft, color: Theme.draftGray),
                .init(label: "文档", count: counts.document, color: Theme.gold),
            ])
    }

    private func planCard(_ plan: PlanMaterializer.PlanEntry) -> some View {
        PlanCard(plan: plan, service: service,
                 onOpen: { open(plan) }, onDelete: { deleting = plan })
    }

    private func open(_ plan: PlanMaterializer.PlanEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detail = plan }
    }

    /// 跨页直达落点：按路径找到计划并打开详情（找不到不清空——扫描可能还没跑到）
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
                Text("正在扫描并提取计划…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("首次扫描需解析全部 Codex 会话记录，可能需要几分钟；"
                    + "之后为增量扫描，秒级完成。可先切到其他页签，扫描在后台继续。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "list.bullet.clipboard",
                title: service.isSearching || selectedSource != nil ? "没有匹配的计划" : "还没有计划记录",
                hint: service.isSearching || selectedSource != nil
                    ? nil
                    : "Claude 计划来自 ~/.claude/plans；Codex / OpenCode 计划从会话记录提取生成；"
                        + "项目计划来自各仓库的 plans/ 与 docs/**/plans/ 目录")
        }
    }
}

/// 计划状态点 / 状态字颜色：草稿用可读灰（区别于分布条里的浅灰段）。
private func planAccentColor(_ status: PlanMaterializer.PlanStatus) -> Color {
    status == .draft ? Color(hex: "9A9AA0") : Theme.planStatusColor(status)
}

/// 真实文件（Claude 计划 / 项目文档）可编辑可删除；物化副本只读
private func planIsRealFile(_ plan: PlanMaterializer.PlanEntry) -> Bool {
    plan.source == .claude || plan.kind == .projectDocument
}

private func planActions(
    _ plan: PlanMaterializer.PlanEntry, service: PlansService, onDelete: @escaping () -> Void
) -> [CardAction] {
    var acts: [CardAction] = [
        CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: plan.path) },
        CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: plan.path) },
    ]
    if planIsRealFile(plan) {
        acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
    }
    return acts
}

@ViewBuilder
private func planMenu(
    _ plan: PlanMaterializer.PlanEntry, service: PlansService, onOpen: @escaping () -> Void,
    onDelete: @escaping () -> Void
) -> some View {
    Button(planIsRealFile(plan) ? "查看 / 编辑" : "查看") { onOpen() }
    Button("用默认编辑器打开") { service.openInEditor(path: plan.path) }
    Button("在 Finder 中显示") { service.reveal(path: plan.path) }
    if planIsRealFile(plan) {
        Divider()
        Button("删除", role: .destructive) { onDelete() }
    }
}

/// 计划图标卡：与技能卡同一套骨架——紫底方块 logo + 标题 + 摘要 + 状态/项目/时间。
/// 不放进度环：卡面只交代「是什么、什么状态」，完成度留给列表视图。
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
                    SourceLogoTile(source: plan.source, size: 28)
                    // 计划标题比技能名长，留 2 行并恒占位（网格等高）
                    Text(plan.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(2, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    Circle().fill(planAccentColor(plan.status)).frame(width: 7, height: 7)
                }
                Text(plan.summary ?? "")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text(plan.status.displayName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(planAccentColor(plan.status))
                    if let project = plan.project { TagChip(project) }
                    Spacer(minLength: 0)
                    Text(plan.modifiedAt, formatter: relativeFormatter)
                        .font(.system(size: 9.5)).foregroundStyle(.tertiary)
                }
            }
        } menu: {
            planMenu(plan, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }
}

/// 计划列表行：状态点 + 来源 logo + 标题/项目·摘要 + 状态字 + 进度条% + 步数 + 时间 + 大小
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
                Circle().fill(planAccentColor(plan.status)).frame(width: 8, height: 8)
                // 与技能 / 记忆 / 代理列表行同款方块（紫底浅框 28pt）
                SourceLogoTile(source: plan.source, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let project = plan.project {
                            Text(project).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if let summary = plan.summary {
                            Text(summary)
                                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 8)
                trailing.fixedSize()
            }
        } menu: {
            planMenu(plan, service: service, onOpen: onOpen, onDelete: onDelete)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 10) {
            Text(plan.status.displayName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(planAccentColor(plan.status))
            if plan.status == .document {
                Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(Theme.goldFg)
            } else if let progress = plan.progress {
                PlanProgressBar(progress: progress, width: 66)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
            if plan.stepsTotal > 0 {
                Text("\(plan.stepsDone) / \(plan.stepsTotal) 步")
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
            }
            Text(plan.modifiedAt, formatter: relativeFormatter)
                .font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(formatBytes(plan.sizeBytes))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .trailing)
        }
    }
}

/// 计划卡片 / 详情工具条的金色图标小块（项目文档 = folder，其他 = doc.text）
private struct PlanIconTile: View {
    let kind: PlanMaterializer.PlanKind
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.gold))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(TileSpec.border(Theme.gold), lineWidth: 0.5))
            .overlay(
                Image(systemName: kind == .projectDocument ? "folder.fill" : "doc.text")
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(Theme.goldFg))
    }
}

// MARK: - 内嵌详情页（专业 Markdown 文档渲染；真实文件可编辑）

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
        // init 即加载：避免首帧空白（计划文档均为小文件，主线程读取无感）
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
                    .font(.system(size: 12).monospaced())
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
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("返回").font(.system(size: 11))
                }
            }
            .buttonStyle(.borderless)
            if plan.kind == .projectDocument {
                PlanIconTile(kind: plan.kind)
            } else {
                SourceBadge(source: plan.source, size: 14)
            }
            Text(plan.title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
            if let project = plan.project {
                TagChip(project)
            }
            Spacer(minLength: 8)
            if editable {
                // 分段「预览 / 编辑」：选中紫底白字
                CapsuleTabTray {
                    CapsuleTabButton(
                        title: "预览", fillWidth: false,
                        isSelected: !editing
                    ) { editing = false }
                    CapsuleTabButton(
                        title: "编辑", fillWidth: false,
                        isSelected: editing
                    ) { editing = true }
                }
            }
            Button { service.openInEditor(path: plan.path) } label: {
                Image(systemName: "square.and.pencil").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("用默认编辑器打开")
            Button { service.reveal(path: plan.path) } label: {
                Image(systemName: "folder").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("在 Finder 中显示")
            if editable {
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("移入废纸篓（可恢复）")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(editable
                ? (plan.kind == .projectDocument
                    ? "项目文档（仓库内真实文件） · \(plan.path)" : plan.path)
                : "物化副本（只读，每轮扫描自动重建） · \(plan.path)")
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
            if editing {
                Button("保存") {
                    service.save(path: plan.path, content: text) { ok in
                        saveNote = ok ? "已保存（写前留有备份）" : "保存失败"
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
}
