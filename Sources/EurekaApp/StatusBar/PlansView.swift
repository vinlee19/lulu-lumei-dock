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
    /// 折叠的分区（key：来源 rawValue；项目计划组用 "projects"）
    @State private var collapsedSections: Set<String> = []
    /// 管理区布局：卡片网格 / 列表
    @State private var layout: KnowledgeLayout = .cards

    private let sources: [AgentSource] = [.claude, .codex, .opencode, .grok, .kimi, .gemini, .qwen]

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
        .onAppear { service.refresh() }
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

    // MARK: - 顶部栏（搜索 + 刷新）

    private var header: some View {
        HStack(spacing: 8) {
            SearchField(placeholder: "搜索计划 / 项目", text: $service.searchText, scanning: service.scanning)
            LayoutToggle(layout: $layout)
            RefreshButton(help: "刷新（重新物化并索引计划）") { service.refresh(force: true) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 统计瓦片（总量 + 各类计数，点击即筛选）

    private var statsTiles: some View {
        HStack(spacing: 10) {
            StatTile(
                value: "\(service.totalCount)",
                sub: formatBytes(service.totalBytes),
                label: "全部计划", icon: "list.bullet.clipboard.fill",
                tint: Theme.brand,
                isSelected: service.filter == .all
            ) { service.filter = .all }
            if service.hasProjectPlans {
                StatTile(
                    value: "\(service.projectCount)",
                    label: "项目", icon: "folder.fill",
                    tint: Theme.gold,
                    isSelected: service.filter == .project
                ) { service.filter = .project }
            }
            ForEach(service.availableSources, id: \.self) { source in
                StatTile(
                    value: "\(service.count(for: source))",
                    label: source.displayName, source: source,
                    tint: Theme.brand,
                    isSelected: service.filter == .source(source)
                ) { service.filter = .source(source) }
            }
        }
    }

    // MARK: - 主体（分区 + 卡片网格）

    private let gridColumns = [GridItem(.adaptive(minimum: 290), spacing: 14)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                statsTiles
                if service.plans.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    let projectItems = service.projectPlans
                    if !projectItems.isEmpty {
                        // 单项目时组头带项目名（设计稿：项目计划 aftership-semantic-layer 41）
                        let projects = Set(projectItems.compactMap(\.project))
                        sectionHeader(
                            key: "projects", icon: "folder.fill", title: "项目计划",
                            subtitle: projects.count == 1 ? projects.first : nil,
                            count: projectItems.count)
                        if !collapsedSections.contains("projects") {
                            // 每张卡/行都带上所属项目标签（用户偏好：一眼可见 plan 属于哪个项目）
                            itemsView(projectItems)
                        }
                    }
                    ForEach(sources, id: \.self) { source in
                        let items = service.plans(for: source)
                        if !items.isEmpty {
                            sectionHeader(key: source.rawValue, source: source, count: items.count)
                            if !collapsedSections.contains(source.rawValue) {
                                itemsView(items)
                            }
                        }
                    }
                }
            }
            .padding(Theme.spacing.page)
        }
    }

    /// 折叠/展开分区（不做结构动画，避免 LazyVStack 幽灵空白）
    private func toggleSection(_ key: String) {
        if collapsedSections.contains(key) {
            collapsedSections.remove(key)
        } else {
            collapsedSections.insert(key)
        }
    }

    /// 分区头：统一 SourceSectionHeader（折叠箭头 + 图标/徽标 + 标题 + 可选副标题 + 中性计数）
    private func sectionHeader(
        key: String, icon: String? = nil, source: AgentSource? = nil,
        title: String? = nil, subtitle: String? = nil, count: Int
    ) -> some View {
        SourceSectionHeader(
            source: source,
            icon: icon,
            title: title ?? source?.displayName ?? "",
            subtitle: subtitle,
            count: count,
            collapsed: collapsedSections.contains(key),
            onToggle: { toggleSection(key) })
    }

    /// 按当前布局出卡片网格或通栏列表
    @ViewBuilder
    private func itemsView(_ items: [PlanMaterializer.PlanEntry], showProject: Bool = true) -> some View {
        switch layout {
        case .cards:
            grid(items, showProject: showProject)
        case .list:
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, plan in
                    PlanRow(
                        plan: plan, service: service, showProject: showProject,
                        onOpen: { open(plan) },
                        onDelete: { deleting = plan })
                    if index < items.count - 1 {
                        Divider().opacity(0.4).padding(.leading, 12)
                    }
                }
            }
        }
    }

    private func grid(_ items: [PlanMaterializer.PlanEntry], showProject: Bool = true) -> some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 14) {
            ForEach(items) { plan in
                PlanCard(
                    plan: plan, service: service, showProject: showProject,
                    onOpen: { open(plan) },
                    onDelete: { deleting = plan })
            }
        }
    }

    private func open(_ plan: PlanMaterializer.PlanEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detail = plan }
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            // 首次扫描要全量解析 Codex 会话提取计划，可能等数分钟；之后增量秒级
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
                title: service.isSearching ? "没有匹配的计划" : "还没有计划记录",
                hint: service.isSearching
                    ? nil
                    : "Claude 计划来自 ~/.claude/plans；Codex / OpenCode 计划从会话记录提取生成；"
                        + "项目计划来自各仓库的 plans/ 与 docs/**/plans/ 目录")
        }
    }
}

/// 计划卡片：金色图标小块 + 标题（2 行）+ 项目 chip / kind + meta（时间 · 大小）；悬停浮现动作
private struct PlanCard: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    var showProject = true
    let onOpen: () -> Void
    let onDelete: () -> Void

    /// 真实文件（Claude 计划 / 项目文档）可编辑可删除；物化副本只读
    private var isRealFile: Bool {
        plan.source == .claude || plan.kind == .projectDocument
    }

    private var actions: [CardAction] {
        var acts: [CardAction] = [
            CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: plan.path) },
            CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: plan.path) },
        ]
        if isRealFile {
            acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
        }
        return acts
    }

    var body: some View {
        KnowledgeCard(height: 140, actions: actions, onOpen: onOpen) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 10) {
                    PlanIconTile(kind: plan.kind, size: 32)
                    Text(plan.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 5) {
                    if showProject, let project = plan.project {
                        TagChip(project)
                    } else if plan.source == .codex, plan.kind != .document {
                        Text(plan.kind.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    Text(plan.modifiedAt, formatter: relativeFormatter)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(formatBytes(plan.sizeBytes))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
        } menu: {
            Button(isRealFile ? "查看 / 编辑" : "查看") { onOpen() }
            Button("用默认编辑器打开") { service.openInEditor(path: plan.path) }
            Button("在 Finder 中显示") { service.reveal(path: plan.path) }
            if isRealFile {
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            }
        }
    }
}

/// 计划列表行：图标 + 标题/项目·kind 两行 + 时间 · 大小；悬停浮现动作
private struct PlanRow: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    var showProject = true
    let onOpen: () -> Void
    let onDelete: () -> Void

    private var isRealFile: Bool {
        plan.source == .claude || plan.kind == .projectDocument
    }

    private var actions: [CardAction] {
        var acts: [CardAction] = [
            CardAction(icon: "pencil", help: "用默认编辑器打开") { service.openInEditor(path: plan.path) },
            CardAction(icon: "folder", help: "在 Finder 中显示") { service.reveal(path: plan.path) },
        ]
        if isRealFile {
            acts.append(CardAction(icon: "trash", destructive: true, help: "移入废纸篓（可恢复）") { onDelete() })
        }
        return acts
    }

    var body: some View {
        KnowledgeRow(actions: actions, onOpen: onOpen) {
            HStack(spacing: 10) {
                PlanIconTile(kind: plan.kind, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if showProject, let project = plan.project {
                        TagChip(project)
                    } else if plan.source == .codex, plan.kind != .document {
                        Text(plan.kind.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 8)
                Text(plan.modifiedAt, formatter: relativeFormatter)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                Text(formatBytes(plan.sizeBytes))
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        } menu: {
            Button(isRealFile ? "查看 / 编辑" : "查看") { onOpen() }
            Button("用默认编辑器打开") { service.openInEditor(path: plan.path) }
            Button("在 Finder 中显示") { service.reveal(path: plan.path) }
            if isRealFile {
                Divider()
                Button("删除", role: .destructive) { onDelete() }
            }
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
                    .foregroundStyle(Theme.gold))
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
