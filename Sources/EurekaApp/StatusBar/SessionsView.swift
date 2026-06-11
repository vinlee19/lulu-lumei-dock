import EurekaIngest
import EurekaKit
import SwiftUI

/// 项目会话管理：先看项目（数量/大小/费用），点开看会话；
/// 双源（Claude/Codex）、搜索、时间/大小排序、会话级费用、一键拷贝 resume 命令
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                TextField("搜索会话名 / 项目 / id", text: $service.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                Picker("", selection: $service.sortMode) {
                    ForEach(SessionBrowserService.SortMode.allCases, id: \.self) {
                        Text($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 116)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)

            Divider()

            if service.groups.isEmpty {
                VStack(spacing: 8) {
                    if service.scanning {
                        ProgressView("正在索引会话…")
                    } else {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
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
                                        service: service
                                    )
                                    .padding(.leading, 14)
                                }
                                Divider().padding(.leading, 12)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { service.refresh() }
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
                    .foregroundStyle(.blue.opacity(0.8))
                Text(group.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let cost = group.totalCostUSD {
                    Text("≈\(formatCost(cost))")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.blue)
                }
                Text("\(group.sessions.count) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(formatBytes(group.totalBytes))
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isExpanded ? Color.primary.opacity(0.04) : .clear)
    }
}

private struct SessionRow: View {
    let session: AgentSessionInfo
    let cost: SessionBrowserService.SessionCost?
    var promptCount: Int?
    let service: SessionBrowserService
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(session.source == .claude ? "C" : "X")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 13, height: 13)
                        .background(Circle().fill(
                            session.source == .claude ? Color.orange : Color.teal))
                    Text(session.name ?? "会话 \(session.id.prefix(8))")
                        .font(.system(size: 12))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Text("#\(session.id.prefix(6))")
                        .font(.system(size: 10).monospaced())
                    Text("·")
                    Text(relativeFormatter.localizedString(
                        for: session.lastActiveAt, relativeTo: Date()))
                    Text("·")
                    Text(formatBytes(session.sizeBytes))
                    if let promptCount, promptCount > 0 {
                        Text("·")
                        Text("\(promptCount) 段对话")
                            .foregroundStyle(.secondary)
                    }
                    if let cost {
                        Text("·")
                        Text(formatTokens(cost.totalTokens) + " tok")
                        if let usd = cost.costUSD {
                            Text("·")
                            Text(formatCost(usd))
                                .foregroundStyle(.blue)
                        }
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
            .help("拷贝恢复命令（cd 项目 && \(session.source == .claude ? "claude --resume" : "codex resume")）")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    switch bytes {
    case ..<1024: return "\(bytes) B"
    case ..<(1024 * 1024): return String(format: "%.0f KB", Double(bytes) / 1024)
    default: return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }
}
