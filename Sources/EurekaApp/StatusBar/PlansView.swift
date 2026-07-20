import EurekaIngest
import EurekaKit
import SwiftUI

/// 计划浏览：按来源（Claude / Codex / opencode）分组，点开用 Markdown 渲染。
/// Claude 计划来自 ~/.claude/plans；Codex/opencode 计划由 PlanMaterializer 从会话/库物化而来。
struct PlansView: View {
    @ObservedObject var service: PlansService

    @State private var viewer: PlanViewerTarget?
    @State private var deleting: PlanMaterializer.PlanEntry?
    /// 已折叠的来源（存 AgentSource.rawValue）；默认展开
    @State private var collapsed: Set<String> = []

    private let sources: [AgentSource] = [.claude, .codex, .opencode, .grok, .kimi]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .onAppear { service.refresh() }
        .sheet(item: $viewer) { target in
            PlanViewerSheet(service: service, target: target)
        }
        .confirmationDialog(
            deleting.map { "删除计划「\($0.title)」？文件会移入废纸篓，可恢复。" } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let entry = deleting { service.delete(entry) }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            TextField("搜索计划", text: $service.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if service.scanning {
                ProgressView().controlSize(.mini)
            }
            Button { service.refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("刷新（重新物化并索引计划）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if service.plans.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sources, id: \.self) { source in
                        let items = service.plans(for: source)
                        if !items.isEmpty {
                            let isExpanded = !collapsed.contains(source.rawValue)
                            PlanSourceHeader(
                                source: source, count: items.count, isExpanded: isExpanded
                            ) { toggle(source) }
                            if isExpanded {
                                ForEach(items) { plan in
                                    PlanRow(
                                        plan: plan, service: service,
                                        onOpen: {
                                            viewer = PlanViewerTarget(
                                                id: plan.path, title: plan.title,
                                                path: plan.path, source: plan.source)
                                        },
                                        onDelete: { deleting = plan })
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.clipboard")
                .font(.system(size: 34))
                .foregroundStyle(Theme.plans.opacity(0.5))
            Text(service.isSearching ? "没有匹配的计划" : "还没有计划记录")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if !service.isSearching {
                Text("Claude 计划来自 ~/.claude/plans；Codex / opencode 的计划会从会话记录中提取生成")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggle(_ source: AgentSource) {
        if collapsed.contains(source.rawValue) {
            collapsed.remove(source.rawValue)
        } else {
            collapsed.insert(source.rawValue)
        }
    }
}

/// 计划来源折叠头：chevron + 来源徽标 + 名称 + 计数
private struct PlanSourceHeader: View {
    let source: AgentSource
    let count: Int
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                SourceBadge(source: source, size: 11)
                Text(source.displayName)
                    .font(.system(size: 11, weight: .medium))
                Spacer(minLength: 6)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Color.primary.opacity(0.03) : .clear)
    }
}

private struct PlanRow: View {
    let plan: PlanMaterializer.PlanEntry
    let service: PlansService
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 12))
                .foregroundStyle(Theme.plans.opacity(0.8))
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if plan.source == .codex {
                        Text(plan.kind.displayName)
                    }
                    Text(plan.modifiedAt, formatter: relativeFormatter)
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 6)
            Text(formatBytes(plan.sizeBytes))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Menu {
                Button(plan.source == .claude ? "查看 / 编辑" : "查看") { onOpen() }
                Button("用默认编辑器打开") { service.openInEditor(path: plan.path) }
                Button("在 Finder 中显示") { service.reveal(path: plan.path) }
                if plan.source == .claude {
                    // 仅 Claude 计划是真实文件；其它源为物化副本，删了会被下一轮复原
                    Divider()
                    Button("删除", role: .destructive) { onDelete() }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }
}

// MARK: - 查看 sheet（Claude 可编辑；其它源为物化副本只读）

struct PlanViewerTarget: Identifiable {
    let id: String
    let title: String
    let path: String
    var source: AgentSource = .claude
}

private struct PlanViewerSheet: View {
    let service: PlansService
    let target: PlanViewerTarget

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var loaded = false
    @State private var editing = false  // 仅 claude 可切编辑
    @State private var saved = false

    private var editable: Bool { target.source == .claude }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(target.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if editable {
                    Picker("", selection: $editing) {
                        Text("预览").tag(false)
                        Text("编辑").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 120)
                }
                Button { service.reveal(path: target.path) } label: {
                    Image(systemName: "folder")
                }
                .help("在 Finder 中显示")
                Button { service.openInEditor(path: target.path) } label: {
                    Image(systemName: "square.and.pencil")
                }
                .help("用默认编辑器打开")
            }
            .buttonStyle(.borderless)
            .padding(10)
            Divider()

            Group {
                if editing {
                    TextEditor(text: $text)
                        .font(.system(size: 12).monospaced())
                } else {
                    ScrollView {
                        MarkdownRichText(text: text)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(minWidth: 460, minHeight: 320)

            Divider()
            HStack {
                Text(editable
                    ? target.path
                    : "物化副本（只读，每轮扫描自动重建） · \(target.path)")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if editable {
                    Button(saved ? "已保存" : "保存") {
                        service.save(path: target.path, content: text) { _ in }
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { dismiss() }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                    .buttonStyle(.borderedProminent)
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(10)
        }
        .frame(width: 560, height: 460)
        .onAppear {
            if !loaded {
                text = service.readContent(path: target.path) ?? ""
                loaded = true
            }
        }
    }
}
