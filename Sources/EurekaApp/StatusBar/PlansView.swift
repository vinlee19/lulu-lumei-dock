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
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("搜索计划 / 项目", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if service.scanning {
                ProgressView().controlSize(.mini)
            }
            Button { service.refresh(force: true) } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("刷新（重新物化并索引计划）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 统计瓦片（总量 + 各类计数，点击即筛选）

    private var statsTiles: some View {
        HStack(spacing: 8) {
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

    private let gridColumns = [GridItem(.adaptive(minimum: 170), spacing: 10)]

    @ViewBuilder
    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                statsTiles
                if service.plans.isEmpty {
                    emptyState
                        .padding(.top, 40)
                } else {
                    let projectItems = service.projectPlans
                    if !projectItems.isEmpty {
                        sectionHeader(icon: "folder.fill", title: "项目计划",
                                      count: projectItems.count)
                        grid(projectItems)
                    }
                    ForEach(sources, id: \.self) { source in
                        let items = service.plans(for: source)
                        if !items.isEmpty {
                            sectionHeader(source: source, count: items.count)
                            grid(items)
                        }
                    }
                }
            }
            .padding(Theme.spacing.page)
        }
    }

    /// 分区头：图标/来源徽标 + 标题 + 计数 + 贯通分隔线
    private func sectionHeader(
        icon: String? = nil, source: AgentSource? = nil, title: String? = nil, count: Int
    ) -> some View {
        HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.gold)
            }
            if let source {
                SourceBadge(source: source, size: 12)
            }
            Text(title ?? source?.displayName ?? "")
                .font(.system(size: 12, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 10).monospacedDigit())
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Theme.brandFill(0.10)))
                .foregroundStyle(Theme.brand)
            VStack { Divider() }
        }
    }

    private func grid(_ items: [PlanMaterializer.PlanEntry]) -> some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 10) {
            ForEach(items) { plan in
                PlanCard(
                    plan: plan, service: service,
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
            VStack(spacing: 10) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.brand.opacity(0.5))
                Text(service.isSearching ? "没有匹配的计划" : "还没有计划记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                if !service.isSearching {
                    Text("Claude 计划来自 ~/.claude/plans；Codex / OpenCode 计划从会话记录提取生成；"
                        + "项目计划来自各仓库的 plans/ 与 docs/**/plans/ 目录")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 30)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 计划卡片：标题 + 底部 meta（项目名 / kind 标签 · 相对时间 · 大小），hover 品牌色描边
private struct PlanCard: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    /// 真实文件（Claude 计划 / 项目文档）可编辑可删除；物化副本只读
    private var isRealFile: Bool {
        plan.source == .claude || plan.kind == .projectDocument
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: plan.kind == .projectDocument
                        ? "folder.fill" : "doc.text")
                        .font(.system(size: 11))
                        .foregroundStyle(plan.kind == .projectDocument
                            ? AnyShapeStyle(Theme.gold)
                            : AnyShapeStyle(Theme.brand.opacity(0.8)))
                        .padding(.top, 1)
                    Text(plan.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                HStack(spacing: 5) {
                    if let project = plan.project {
                        Text(project)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.gold.opacity(0.15)))
                            .foregroundStyle(Theme.gold)
                            .lineLimit(1)
                    } else if plan.source == .codex, plan.kind != .document {
                        Text(plan.kind.displayName)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    Text(plan.modifiedAt, formatter: relativeFormatter)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(formatBytes(plan.sizeBytes))
                        .font(.system(size: 9.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(10)
            .frame(height: 76)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(
                        hovering ? Theme.brand.opacity(0.6) : Theme.hairline,
                        lineWidth: hovering ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
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
                ScrollView {
                    // 文档卡：限宽居中 + 宽松内边距，接近正式文档排版
                    MarkdownRichText(text: text)
                        .padding(24)
                        .frame(maxWidth: 720, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .fill(Theme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.radius.card)
                                        .strokeBorder(Theme.hairline, lineWidth: 0.5)))
                        .frame(maxWidth: .infinity)
                        .padding(Theme.spacing.page)
                }
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
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.gold)
            } else {
                SourceBadge(source: plan.source, size: 12)
            }
            Text(plan.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            if let project = plan.project {
                Text(project)
                    .font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Theme.gold.opacity(0.15)))
                    .foregroundStyle(Theme.gold)
            }
            Spacer(minLength: 8)
            if editable {
                Picker("", selection: $editing) {
                    Text("预览").tag(false)
                    Text("编辑").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
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
