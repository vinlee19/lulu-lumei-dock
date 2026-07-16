import EurekaKit
import SwiftUI

/// 最近任务历史列表：显示对话开始时间，支持「最近活跃 / 开始时间」排序
struct HistoryView: View {
    let tasks: [FinishedTask]
    @ObservedObject var settings: AppSettings

    /// rawValue 为持久化 token；label 为界面文案
    enum SortMode: String, CaseIterable {
        case active
        case start
        var label: String { self == .active ? "最近活跃" : "开始时间" }
    }

    private var sortMode: SortMode {
        SortMode(rawValue: settings.historySortMode) ?? .active
    }

    /// 客户端排序（50 行内成本可忽略）：活跃=finishedAt，开始=会话最初开始时间
    private var sortedTasks: [FinishedTask] {
        switch sortMode {
        case .active:
            return tasks.sorted { $0.finishedAt > $1.finishedAt }
        case .start:
            return tasks.sorted { startKey($0) > startKey($1) }
        }
    }

    private func startKey(_ task: FinishedTask) -> Date {
        task.sessionStartedAt ?? task.startedAt ?? task.finishedAt
    }

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.history.opacity(0.45))
                Text("还没有任务记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("跑一次 claude / codex / grok 任务试试")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Picker("", selection: Binding(
                        get: { sortMode },
                        set: { settings.historySortMode = $0.rawValue }
                    )) {
                        ForEach(SortMode.allCases, id: \.self) { Text($0.label) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 148)
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Divider()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedTasks) { task in
                            HistoryRow(task: task)
                            Divider().padding(.leading, 38)
                        }
                    }
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let task: FinishedTask

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15))
                .foregroundStyle(iconColor)
                .frame(width: 18)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title ?? task.projectName ?? task.sessionId)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(task.source.displayName)
                    if let project = task.projectName {
                        Text("·")
                        Text(project)
                    }
                    if let start = task.sessionStartedAt ?? task.startedAt {
                        Text("·")
                        Image(systemName: "calendar")
                            .font(.system(size: 9))
                        Text(formatStartTime(start))
                    }
                    if let duration = task.duration {
                        Text("·")
                        Text(formatDuration(duration))
                    }
                    Text("·")
                    Text(relativeFormatter.localizedString(
                        for: task.finishedAt, relativeTo: Date()))
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if let detail = task.detail, task.outcome != .success {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private var iconName: String {
        switch task.outcome {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.octagon.fill"
        case .interrupted: return "minus.circle.fill"
        }
    }

    private var iconColor: Color {
        Theme.outcomeColor(task.outcome)
    }
}
