import AppKit
import EurekaIngest
import EurekaKit
import SwiftUI

/// 会话详情：头部信息 + resume 命令条 + 恢复/删除动作 + 对话记录流 + 对话目录（可折叠右栏）
struct SessionDetailView: View {
    @ObservedObject var service: SessionBrowserService

    @State private var showTOC = true
    @State private var confirmingDelete = false
    @State private var copiedCommand = false
    @State private var roleFilter: RoleFilter = .all
    @State private var searchQuery = ""
    @State private var matchIndex = 0
    @State private var exportNote: String?
    /// 已展开的轨迹消息 id（切会话时清空，避免新会话同 id 意外展开）
    @State private var expandedTrails: Set<Int> = []

    enum RoleFilter: String, CaseIterable {
        case all = "全部"
        case user = "用户"
        case assistant = "助手"
    }

    var body: some View {
        Group {
            if let session = service.selected {
                VStack(spacing: 0) {
                    header(session)
                    overviewCard(session)
                    searchBar
                    Divider()
                    HStack(spacing: 0) {
                        transcriptPane(session)
                        if showTOC && !userMessages.isEmpty {
                            Divider()
                            tocPane
                                .frame(width: 190)
                        }
                    }
                }
                .confirmationDialog(
                    "删除会话「\(session.name ?? String(session.id.prefix(8)))」？transcript 文件会移入废纸篓，可恢复。",
                    isPresented: $confirmingDelete, titleVisibility: .visible
                ) {
                    Button("删除", role: .destructive) {
                        service.deleteSessions([session])
                    }
                    Button("取消", role: .cancel) {}
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .font(.system(size: 32))
                        .foregroundStyle(Theme.brand.opacity(0.4))
                    Text("选择左侧会话查看对话记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // 挂在 Group 上：经由"清空选择"中转的切换也能清空轨迹展开态（新会话同 id 不误展开）
        .onChange(of: service.selected?.id) { _, _ in
            expandedTrails = []
        }
        // 全文命中跳转：transcript 加载完成后滚到目标消息（延迟一拍等 LazyVStack 布局）
        .onChange(of: service.transcriptLoading) { _, loading in
            guard !loading, let pending = service.consumePendingJump() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: .eurekaJumpToMessage, object: pending)
            }
        }
    }

    private var userMessages: [TranscriptMessage] {
        service.transcript.filter { $0.role == .user }
    }

    /// 按角色筛选后的消息流（搜索不过滤、只高亮+跳转）
    private var displayMessages: [TranscriptMessage] {
        switch roleFilter {
        case .all: return service.transcript
        case .user: return service.transcript.filter { $0.role == .user }
        case .assistant: return service.transcript.filter { $0.role == .assistant }
        }
    }

    /// 搜索命中的消息 id（在 displayMessages 内）
    private var matchIDs: [Int] {
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        return displayMessages
            .filter { $0.text.lowercased().contains(query) }
            .map(\.id)
    }

    // MARK: - 头部

    private func header(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                SourceBadge(source: session.source, size: 14)
                Text(session.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 8)
                Button {
                    service.resumeInTerminal(session)
                } label: {
                    Label("恢复会话", systemImage: "play.fill")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .tint(Theme.brand)
                .help("在 Terminal 中执行恢复命令")
                Button {
                    confirmingDelete = true
                } label: {
                    Label("删除会话", systemImage: "trash")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(session.source == .opencode)
                .help(session.source == .opencode
                    ? "OpenCode 会话存于共享数据库，暂不支持删除" : "移入废纸篓，可恢复")
                Menu {
                    Button("复制为 Markdown") { copyMarkdown(session) }
                    Button("导出为 .md 文件…") { exportMarkdown(session) }
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("导出对话记录")
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showTOC.toggle() }
                } label: {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 11))
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .help(showTOC ? "隐藏对话目录" : "显示对话目录")
            }
            if let note = exportNote {
                Text(note)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                if let started = session.startedAt {
                    metaItem("clock", started.formatted(.dateTime.year().month().day().hour().minute().second()))
                }
                if let cwd = session.cwd {
                    metaItem("folder", URL(fileURLWithPath: cwd).lastPathComponent)
                }
                if session.source != .opencode {
                    metaItem("doc.text",
                             URL(fileURLWithPath: session.transcriptPath).lastPathComponent)
                }
                Spacer(minLength: 0)
            }
            // resume 命令条
            HStack(spacing: 6) {
                Text(service.resumeCommand(for: session))
                    .font(.system(size: 10).monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                Button {
                    service.copyResumeCommand(session)
                    copiedCommand = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copiedCommand = false
                    }
                } label: {
                    Image(systemName: copiedCommand ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .help("复制恢复命令")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func metaItem(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(.tertiary)
    }

    // MARK: - 概览卡

    @ViewBuilder
    private func overviewCard(_ session: AgentSessionInfo) -> some View {
        let cost = service.costs[session.id]
        HStack(spacing: 16) {
            overviewStat("消息", "\(service.transcript.count)")
            overviewStat("提问", "\(userMessages.count)")
            if let cost {
                overviewStat("Tokens", formatTokens(cost.totalTokens))
                if let usd = cost.costUSD {
                    overviewStat("费用", formatCost(usd), color: Theme.cost)
                }
            }
            if let span = session.duration, span >= 60 {
                overviewStat("时长", formatDuration(span))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func overviewStat(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(color)
        }
    }

    // MARK: - 搜索栏

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 8) {
            Picker("", selection: $roleFilter) {
                ForEach(RoleFilter.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .controlSize(.mini)
            .onChange(of: roleFilter) { _, _ in
                matchIndex = 0
                jumpToCurrentMatch()
            }

            Image(systemName: "magnifyingglass")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            TextField("在对话中搜索", text: $searchQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .onChange(of: searchQuery) { _, _ in
                    matchIndex = 0
                    jumpToCurrentMatch()
                }
            if !matchIDs.isEmpty {
                Text("\(min(matchIndex + 1, matchIDs.count))/\(matchIDs.count)")
                    .font(.system(size: 9.5).monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    matchIndex = (matchIndex - 1 + matchIDs.count) % matchIDs.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.up").font(.system(size: 9)) }
                .buttonStyle(.borderless)
                Button {
                    matchIndex = (matchIndex + 1) % matchIDs.count
                    jumpToCurrentMatch()
                } label: { Image(systemName: "chevron.down").font(.system(size: 9)) }
                .buttonStyle(.borderless)
            } else if !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("无匹配")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 7)
    }

    private func jumpToCurrentMatch() {
        guard matchIndex < matchIDs.count else { return }
        NotificationCenter.default.post(name: .eurekaJumpToMessage, object: matchIDs[matchIndex])
    }

    // MARK: - 导出

    private func copyMarkdown(_ session: AgentSessionInfo) {
        let md = TranscriptMarkdown.render(session: session, messages: service.transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(md, forType: .string)
        exportNote = "已复制 Markdown 到剪贴板"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportNote = nil }
    }

    private func exportMarkdown(_ session: AgentSessionInfo) {
        let md = TranscriptMarkdown.render(session: session, messages: service.transcript)
        let panel = NSSavePanel()
        let base = session.name.map { TranscriptMarkdown.safeFileName($0) }
            ?? String(session.id.prefix(8))
        panel.nameFieldStringValue = "\(base).md"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? Data(md.utf8).write(to: url)
            exportNote = "已导出 \(url.lastPathComponent)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exportNote = nil }
        }
    }

    // MARK: - 对话记录流

    private func transcriptPane(_ session: AgentSessionInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("对话记录")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(service.transcript.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Theme.brand.opacity(0.12)))
                    .foregroundStyle(Theme.brand)
                if service.transcriptTruncated {
                    Text("仅显示前 \(service.transcript.count) 条")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            Divider()

            if service.transcriptLoading {
                ProgressView("正在解析对话记录…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if service.transcript.isEmpty {
                Text("没有可显示的消息")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        // 聊天式排版：消息间距拉开；左右两侧本就有列表/目录夹着，不再限宽居中
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(displayMessages) { message in
                                MessageRowView(
                                    message: message,
                                    isMatch: matchIDs.contains(message.id),
                                    expandedTrails: $expandedTrails)
                                    .id(message.id)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 16)
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: .eurekaJumpToMessage)) { note in
                        if let id = note.object as? Int {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(id, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 对话目录

    private var tocPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "list.number")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("对话目录")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(userMessages.enumerated()), id: \.element.id) { index, message in
                        Button {
                            NotificationCenter.default.post(
                                name: .eurekaJumpToMessage, object: message.id)
                        } label: {
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(Theme.brand)
                                    .frame(width: 16, height: 16)
                                    .background(Circle().fill(Theme.brand.opacity(0.1)))
                                VStack(alignment: .leading, spacing: 1) {
                                    if let ts = message.timestamp {
                                        Text(ts, format: .dateTime.month(.twoDigits).day(.twoDigits)
                                            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
                                            .font(.system(size: 8.5).monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                    Text(message.text)
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(Color.primary.opacity(0.02))
    }
}

extension Notification.Name {
    /// 对话目录 → 消息流跳转（携带消息 id）
    static let eurekaJumpToMessage = Notification.Name("eurekaJumpToMessage")
}

// MARK: - 消息行

/// 聊天式消息行：用户提问 = 右对齐、紧贴内容宽的品牌色气泡；助手回复 = 靠左无边框正文直排；
/// 时间戳 + 复制按钮不常驻，hover 时浮出在消息块右上角（overlay 不占布局）。
private struct MessageRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    @Binding var expandedTrails: Set<Int>

    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch message.role {
        case .toolNote:
            HStack(spacing: 5) {
                Text(message.text)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.brand.opacity(0.65))
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
        case .turnTrail:
            TurnTrailRowView(
                message: message, isMatch: isMatch, expandedTrails: $expandedTrails)
        case .user:
            HStack(spacing: 0) {
                // 左侧至少留 ~15% 空，气泡宽度由内容决定、靠右
                Spacer(minLength: 56)
                MarkdownRichText(text: message.text, fillWidth: false)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.brandFill(0.10)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                isMatch ? Theme.gold.opacity(0.85) : Theme.hairline,
                                lineWidth: isMatch ? 1.5 : 0.5))
            }
            .overlay(alignment: .topTrailing) { hoverMeta }
            .onHover { hovering = $0 }
        case .assistant:
            MarkdownRichText(text: message.text)
                .padding(.horizontal, 2)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isMatch ? Theme.gold.opacity(0.12) : .clear)
                        .padding(-6))
                .overlay(alignment: .topTrailing) { hoverMeta }
                .onHover { hovering = $0 }
        case .error:
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.red.opacity(0.8))
                    .frame(width: 3)
                Text(message.text)
                    .font(.system(size: 12.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.06)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isMatch ? Theme.gold.opacity(0.85) : .clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) { hoverMeta }
            .onHover { hovering = $0 }
        }
    }

    /// hover 浮出的时间戳 + 复制胶囊：悬在消息块右上角外侧，不参与布局
    @ViewBuilder
    private var hoverMeta: some View {
        if hovering || copied {
            HStack(spacing: 5) {
                if let timestamp = message.timestamp {
                    Text(timestamp, format: .dateTime.month(.twoDigits).day(.twoDigits)
                        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.text, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("复制消息原文")
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Theme.surface)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.10), radius: 3, y: 1))
            .offset(y: -11)
        }
    }
}

// 富文本正文渲染已抽到共享组件 MarkdownRichText.swift（会话/记忆/技能/计划共用）
