import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// Prompt 库：从全部会话提取的用户提问，统一浏览/搜索/复用。
/// 列表 = 收藏星标 + 来源徽标 + 首行标题 + 项目/会话 + 时间；详情 = 全文 + 复制/回跳会话。
struct PromptsView: View {
    @ObservedObject var service: PromptsService
    /// 跳回所属会话（transcript 定位到该提问）
    var sessionBrowser: SessionBrowserService

    /// 内嵌详情页当前展示的条目（nil = 列表）
    @State private var detail: PromptEntry?
    @State private var deleting: PromptEntry?
    /// 来源筛选（nil = 全部）
    @State private var selectedSource: AgentSource?

    /// 搜索 + 来源 + 收藏筛选后的列表（service 已按 first_seen 倒序）
    private var filtered: [PromptEntry] {
        service.prompts
            .filter { selectedSource == nil || $0.source == selectedSource }
    }

    var body: some View {
        Group {
            if let entry = detail, let live = service.entry(id: entry.id) {
                PromptDetailView(
                    entry: live, service: service,
                    onBack: { withAnimation(.easeOut(duration: 0.15)) { detail = nil } },
                    onDelete: { deleting = live },
                    onJumpToSession: { jumpToSession(live) })
                    .id(live.id)
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
        .onChange(of: service.focusId) { _, _ in consumeFocus() }
        .onChange(of: service.lastScanAt) { _, _ in consumeFocus() }
        .confirmationDialog(
            deleting.map { "从 Prompt 库移除「\($0.title)」？源会话不受影响。" } ?? "",
            isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("移除", role: .destructive) {
                if let entry = deleting {
                    service.delete(entry.id)
                    if detail?.id == entry.id { detail = nil }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部栏

    private var header: some View {
        HStack(spacing: 12) {
            Text("Prompt 库").font(.system(size: 15, weight: .bold))
            SearchField(
                placeholder: "搜索提问", text: $service.searchText,
                scanning: service.scanning, resultCount: service.prompts.count)
            Spacer(minLength: 12)
            Button {
                service.favoritesOnly.toggle()
            } label: {
                Image(systemName: service.favoritesOnly ? "star.fill" : "star")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(service.favoritesOnly ? Theme.gold : .secondary)
            }
            .buttonStyle(.borderless)
            .help(service.favoritesOnly ? "显示全部提问" : "只看收藏")
            ScanStatusLabel(
                scanning: service.scanning, phase: service.scanPhase,
                lastScanAt: service.lastScanAt)
            RefreshButton(help: "重新提取（增量：只解析有新消息的会话）") { service.refresh() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statsCard
                SourceFilterBar(
                    selected: $selectedSource,
                    allLabel: "全部", allIcon: "text.quote",
                    totalCount: service.totalCount,
                    sources: availableSources,
                    count: { sourceCount($0) })
                if filtered.isEmpty {
                    emptyState.padding(.top, 40)
                } else {
                    KnowledgeListContainer {
                        // 懒加载：prompt 库是首个数据量可上万的条目面，
                        // 普通 VStack 会一次性物化全部行（Plans 条数少无所谓，这里会卡）
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                                PromptRow(
                                    entry: entry, service: service,
                                    onOpen: { open(entry) },
                                    onCopy: { service.copyToPasteboard(entry.id) },
                                    onJump: { jumpToSession(entry) })
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
        let counts = sourceCounts
        let top = counts.sorted { $0.value > $1.value }.prefix(4)
        return StatOverviewCard(
            value: "\(service.totalCount)",
            unit: "提问",
            subtitle: "\(availableSources.count) 个来源 · 收藏 \(service.favoriteCount)",
            distributionTitle: "来源分布",
            segments: top.map {
                .init(label: $0.key.displayName, count: $0.value, color: Theme.brand)
            },
            showBar: false)
    }

    private var availableSources: [AgentSource] {
        var seen: [AgentSource: Int] = [:]
        for entry in service.knowledgeSnapshot() {
            seen[entry.source, default: 0] += 1
        }
        return seen.sorted { $0.value > $1.value }.map(\.key)
    }

    private var sourceCounts: [AgentSource: Int] {
        var counts: [AgentSource: Int] = [:]
        for entry in service.knowledgeSnapshot() {
            counts[entry.source, default: 0] += 1
        }
        return counts
    }

    private func sourceCount(_ source: AgentSource) -> Int {
        sourceCounts[source] ?? 0
    }

    private func open(_ entry: PromptEntry) {
        withAnimation(.easeOut(duration: 0.15)) { detail = entry }
    }

    /// 跳回所属会话（切页签 + 滚动定位到该提问）。
    /// 与命令面板 transcript 命中同款顺序：先发通知切页+选中，再补 messageIdx 定位
    /// （pendingJump 在 transcript 加载完成后被 SessionDetailView 消费）。
    private func jumpToSession(_ entry: PromptEntry) {
        NotificationCenter.default.post(name: .eurekaRevealSession, object: entry.sessionId)
        sessionBrowser.revealMessage(sessionId: entry.sessionId, messageIdx: entry.messageIdx)
    }

    /// 跨页直达落点：按 id 找到条目并打开详情（找不到不清空——扫描可能还没跑到）
    private func consumeFocus() {
        guard let id = service.focusId, let entry = service.entry(id: id) else { return }
        withAnimation(.easeOut(duration: 0.15)) { detail = entry }
        service.focusId = nil
    }

    @ViewBuilder
    private var emptyState: some View {
        if service.scanning {
            VStack(spacing: 10) {
                ProgressView()
                Text("正在提取用户提问…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("首次提取需解析全部会话记录，可能需要一两分钟；"
                    + "之后为增量提取，秒级完成。可先切到其他页签，提取在后台继续。")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            EmptyStateView(
                icon: "text.quote",
                title: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? "没有匹配的提问" : "还没有提取到提问",
                hint: service.isSearching || service.favoritesOnly || selectedSource != nil
                    ? nil
                    : "提问从各 Agent 的会话记录中自动提取（会话页签扫描完成后开始）")
        }
    }
}

// MARK: - 列表行

/// 一行提问：收藏星标 + 首行标题 + 来源/项目/时间副标 + 悬停复制/回跳操作。
private struct PromptRow: View {
    let entry: PromptEntry
    let service: PromptsService
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onJump: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                service.toggleFavorite(entry.id)
            } label: {
                Image(systemName: entry.favorite ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(entry.favorite ? Theme.gold : .secondary.opacity(0.6))
            }
            .buttonStyle(.borderless)
            .help(entry.favorite ? "取消收藏" : "收藏")

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(Theme.font.themed(12.5, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 6) {
                    SourceBadge(source: entry.source, size: 11)
                    if let project = entry.projectName {
                        Text(project).font(Theme.font.themed(10)).foregroundStyle(.secondary)
                    }
                    if let ts = entry.timestamp {
                        Text(ts, format: .dateTime.month().day().hour().minute())
                            .font(Theme.font.themedMono(9.5))
                            .foregroundStyle(.tertiary)
                    }
                    if entry.useCount > 0 {
                        Text("已用 \(entry.useCount) 次")
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(Theme.brandFg.opacity(0.7))
                    }
                    ForEach(entry.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)")
                            .font(Theme.font.themed(9.5))
                            .foregroundStyle(Theme.goldFg.opacity(0.8))
                    }
                }
            }
            Spacer(minLength: 8)
            if hovering {
                HStack(spacing: 10) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc").font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("复制提问原文")
                    Button(action: onJump) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("在所属会话中查看")
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.04) : .clear))
    }
}

// MARK: - 详情页

/// 提问详情：全文可选中复制 + 标签编辑 + 复制/回跳/收藏/移除。
private struct PromptDetailView: View {
    let entry: PromptEntry
    let service: PromptsService
    let onBack: () -> Void
    let onDelete: () -> Void
    let onJumpToSession: () -> Void

    @State private var newTag = ""
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    metaCard
                    MarkdownRichText(text: entry.text)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                                .fill(Theme.surface))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                    tagsCard
                    actionsCard
                }
                .padding(22)
            }
            .background(Theme.surfaceSecondary)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("返回列表")
            SourceBadge(source: entry.source, size: 14)
            Text(entry.title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            if let session = service.sessionName(for: entry) {
                Text(session)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var metaCard: some View {
        HStack(spacing: 16) {
            if let ts = entry.timestamp {
                metaItem("clock", ts.formatted(
                    .dateTime.year().month().day().hour().minute().second()))
            }
            if let project = entry.projectName {
                metaItem("folder", project)
            }
            Text("\(entry.text.count) 字")
            Spacer(minLength: 0)
        }
        .font(Theme.font.themed(10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text)
        }
    }

    private var tagsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标签")
                .font(Theme.font.themed(11, .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text("#\(tag)").font(Theme.font.themed(10))
                        Button {
                            service.setTags(entry.id, tags: entry.tags.filter { $0 != tag })
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.borderless)
                    }
                    .foregroundStyle(Theme.goldFg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Theme.gold.opacity(0.12)))
                }
                TextField("添加标签", text: $newTag)
                    .textFieldStyle(.plain)
                    .font(Theme.font.themed(10))
                    .frame(width: 90)
                    .onSubmit(addTag)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
                .fill(Theme.surface))
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespaces)
        guard !tag.isEmpty, !entry.tags.contains(tag) else { return }
        service.setTags(entry.id, tags: entry.tags + [tag])
        newTag = ""
    }

    private var actionsCard: some View {
        HStack(spacing: 10) {
            Button {
                service.copyToPasteboard(entry.id)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Label(copied ? "已复制" : "复制提问", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .tint(Theme.brand)
            Button(action: onJumpToSession) {
                Label("在会话中查看", systemImage: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .help("切到会话页签并定位到这条提问")
            Spacer(minLength: 0)
            if entry.useCount > 0 {
                Text("已使用 \(entry.useCount) 次"
                    + (entry.lastUsedAt.map { " · 最近 " + $0.formatted(.dateTime.month().day()) } ?? ""))
                    .font(Theme.font.themed(9.5))
                    .foregroundStyle(.tertiary)
            }
            Button(role: .destructive, action: onDelete) {
                Label("移除", systemImage: "trash").font(.system(size: 11))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .tint(.red)
            .help("从 Prompt 库移除（源会话不受影响）")
        }
    }
}
