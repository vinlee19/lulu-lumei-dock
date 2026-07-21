import EurekaIngest
import EurekaKit
import SwiftUI

/// 会话管理三栏：左 = 项目分组列表（搜索/来源筛选/多选/刷新），
/// 右 = 会话详情（对话记录 + 对话目录，见 SessionDetailView）。
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService
    @ObservedObject var settings: AppSettings
    @State private var expanded: Set<String> = []
    /// 多选模式与选中集合（存 session id）
    @State private var multiSelect = false
    @State private var checkedIds: Set<String> = []
    @State private var confirmingBatchDelete = false

    private var limitLabel: String {
        settings.sessionDisplayLimit == 0 ? "全部" : "最近 \(settings.sessionDisplayLimit)"
    }

    var body: some View {
        HSplitView {
            listPane
                .frame(minWidth: 250, idealWidth: 300, maxWidth: 420)
            SessionDetailView(service: service)
                .frame(minWidth: 380, maxWidth: .infinity)
        }
        .onAppear {
            service.displayLimit = settings.sessionDisplayLimit
            if let mode = SessionBrowserService.SortMode(rawValue: settings.sessionSortMode) {
                service.sortMode = mode
            }
            service.refresh()
        }
        .onChange(of: settings.sessionDisplayLimit) { _, newValue in
            service.displayLimit = newValue
        }
        .onChange(of: service.sortMode) { _, newValue in
            settings.sessionSortMode = newValue.rawValue
        }
        .confirmationDialog(
            "删除选中的 \(deletableChecked.count) 个会话？transcript 文件会移入废纸篓，可恢复。",
            isPresented: $confirmingBatchDelete, titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                service.deleteSessions(deletableChecked)
                checkedIds = []
                multiSelect = false
            }
            Button("取消", role: .cancel) {}
        }
    }

    /// 选中且可删（opencode 不可删）的会话
    private var deletableChecked: [AgentSessionInfo] {
        allVisibleSessions.filter {
            checkedIds.contains($0.id) && $0.source != .opencode
        }
    }

    private var allVisibleSessions: [AgentSessionInfo] {
        service.groups.flatMap(\.sessions)
    }

    // MARK: - 左栏

    private var listPane: some View {
        VStack(spacing: 0) {
            // 账本总览 + 展示数量
            HStack(spacing: 6) {
                Text("共 \(service.summary.sessionCount) 个会话")
                    .font(.system(size: 11, weight: .medium))
                Text("·").foregroundStyle(.tertiary)
                Text(formatBytes(service.summary.totalBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if let cost = service.summary.totalCostUSD {
                    Text("·").foregroundStyle(.tertiary)
                    Text("≈\(formatCost(cost))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.cost)
                }
                Spacer(minLength: 6)
                Menu {
                    ForEach([10, 20, 50], id: \.self) { n in
                        Button("最近 \(n) 个") { settings.sessionDisplayLimit = n }
                    }
                    Button("全部") { settings.sessionDisplayLimit = 0 }
                } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 10))
                        Text(limitLabel).font(.system(size: 10))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 2)

            // 搜索 + 工具条
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("搜索会话 / 项目 / id", text: $service.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                // 来源筛选
                Menu {
                    Button("全部来源") { service.sourceFilter = nil }
                    Divider()
                    ForEach(AgentSource.allCases, id: \.self) { source in
                        Button(source.displayName) { service.sourceFilter = source }
                    }
                } label: {
                    HStack(spacing: 2) {
                        if let filter = service.sourceFilter {
                            SourceBadge(source: filter, size: 10)
                        } else {
                            Image(systemName: "line.3.horizontal.decrease")
                                .font(.system(size: 9))
                        }
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7))
                    }
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("按来源筛选")
                // 多选模式
                Button {
                    multiSelect.toggle()
                    if !multiSelect { checkedIds = [] }
                } label: {
                    Image(systemName: multiSelect
                        ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(multiSelect ? Theme.brand : .secondary)
                }
                .buttonStyle(.borderless)
                .help("多选模式（批量删除）")
                // 刷新
                Button {
                    service.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("重新索引会话")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // 排序
            Picker("", selection: $service.sortMode) {
                ForEach(SessionBrowserService.SortMode.allCases, id: \.self) {
                    Text($0.label)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Divider()

            if service.groups.isEmpty && service.fullTextHits.isEmpty {
                VStack(spacing: 8) {
                    if service.scanning {
                        ProgressView("正在索引会话…")
                    } else {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.brand.opacity(0.45))
                        Text(service.isSearching ? "没有匹配的会话" : "近 30 天没有会话")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(service.groups) { group in
                            let isOpen = service.isSearching || expanded.contains(group.id)
                            ProjectHeaderRow(group: group, isExpanded: isOpen) {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    if expanded.contains(group.id) {
                                        expanded.remove(group.id)
                                    } else {
                                        expanded.insert(group.id)
                                    }
                                }
                            }
                            if isOpen {
                                ForEach(group.sessions) { session in
                                    SessionRow(
                                        session: session,
                                        cost: service.costs[session.id],
                                        promptCount: service.promptCounts[session.id],
                                        service: service,
                                        isSelected: service.selected?.id == session.id,
                                        multiSelect: multiSelect,
                                        isChecked: checkedIds.contains(session.id),
                                        onToggleCheck: { toggleCheck(session) }
                                    )
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
                        Text("已选 \(checkedIds.count) 个")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("批量删除") { confirmingBatchDelete = true }
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

    private func toggleCheck(_ session: AgentSessionInfo) {
        if checkedIds.contains(session.id) {
            checkedIds.remove(session.id)
        } else {
            checkedIds.insert(session.id)
        }
    }

    // MARK: - 全文命中区（对话内容级搜索结果，点击直达消息）

    private var fullTextSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.gold)
                Text("对话内容命中")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(service.fullTextHits.count)")
                    .font(.system(size: 10).monospacedDigit())
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
                            Text(hit.sessionName ?? "会话 \(hit.sessionId.prefix(8))")
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(hit.role == "user" ? "用户" : "助手")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                            if let ts = hit.ts {
                                Text(relativeFormatter.localizedString(for: ts, relativeTo: Date()))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text(hit.snippet)
                            .font(.system(size: 10.5))
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

/// 项目行：点击展开/收起该项目下的会话
private struct ProjectHeaderRow: View {
    let group: SessionBrowserService.ProjectGroup
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.brand.opacity(0.8))
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let cost = group.totalCostUSD {
                    Text("≈\(formatCost(cost))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.cost)
                }
                Text("\(group.sessions.count) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(formatBytes(group.totalBytes))
                    .font(.system(size: 10).monospacedDigit())
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

/// 会话行：点击选中（详情栏加载 transcript）；多选模式带复选框
private struct SessionRow: View {
    let session: AgentSessionInfo
    let cost: SessionBrowserService.SessionCost?
    var promptCount: Int?
    let service: SessionBrowserService
    let isSelected: Bool
    let multiSelect: Bool
    let isChecked: Bool
    let onToggleCheck: () -> Void

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            if multiSelect {
                Button(action: onToggleCheck) {
                    Image(systemName: isChecked ? "checkmark.square.fill" : "square")
                        .font(.system(size: 12))
                        .foregroundStyle(session.source == .opencode
                            ? AnyShapeStyle(.tertiary)
                            : (isChecked ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.secondary)))
                }
                .buttonStyle(.borderless)
                .disabled(session.source == .opencode)
                .help(session.source == .opencode ? "opencode 会话不支持删除" : "")
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    SourceBadge(source: session.source, size: 11)
                    Text(session.name ?? "会话 \(session.id.prefix(8))")
                        .font(.system(size: 12.5))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text(relativeFormatter.localizedString(
                        for: session.lastActiveAt, relativeTo: Date()))
                    Text("·")
                    Text(formatBytes(session.sizeBytes))
                    if let promptCount, promptCount > 0 {
                        Text("·")
                        Text("\(promptCount) 段")
                    }
                    if let cost, let usd = cost.costUSD {
                        Text("·")
                        Text(formatCost(usd))
                            .foregroundStyle(Theme.cost)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Button {
                service.copyResumeCommand(session)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)
            .help("拷贝恢复命令")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            ZStack(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Theme.brandFill(0.08))
                    // 左侧品牌色指示条（Activity Monitor 式选中态）
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Theme.brand)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                }
            })
        .contentShape(Rectangle())
        .onTapGesture {
            if multiSelect {
                if session.source != .opencode { onToggleCheck() }
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
