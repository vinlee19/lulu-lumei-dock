import EurekaIngest
import SwiftUI

/// 项目会话管理：按项目分组，命名（ai-title/首条 prompt）、时间/大小排序、
/// 一键拷贝 resume 命令
struct SessionsView: View {
    @ObservedObject var service: SessionBrowserService

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("近 30 天会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $service.sortMode) {
                    ForEach(SessionBrowserService.SortMode.allCases, id: \.self) {
                        Text($0.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 130)
                .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if service.groups.isEmpty {
                VStack(spacing: 8) {
                    if service.scanning {
                        ProgressView("正在索引会话…")
                    } else {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("近 30 天没有会话")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(service.groups) { group in
                            Section {
                                ForEach(group.sessions) { session in
                                    SessionRow(session: session, service: service)
                                }
                            } header: {
                                HStack {
                                    Text(group.name)
                                        .font(.system(size: 11, weight: .semibold))
                                    Spacer()
                                    Text("\(group.sessions.count) 个 · \(formatBytes(group.totalBytes))")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 5)
                                .background(.regularMaterial)
                            }
                        }
                    }
                }
            }
        }
        .onAppear { service.refresh() }
    }
}

private struct SessionRow: View {
    let session: ClaudeSessionInfo
    let service: SessionBrowserService
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name ?? "会话 \(session.id.prefix(8))")
                    .font(.system(size: 12))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text("#\(session.id.prefix(6))")
                        .font(.system(size: 10).monospaced())
                    Text("·")
                    Text(relativeFormatter.localizedString(
                        for: session.lastActiveAt, relativeTo: Date()))
                    Text("·")
                    Text(formatBytes(session.sizeBytes))
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
            .help("拷贝恢复命令（cd 项目 && claude --resume）")
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
