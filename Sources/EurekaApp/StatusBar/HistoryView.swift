import EurekaKit
import SwiftUI

/// 最近任务历史列表
struct HistoryView: View {
    let tasks: [FinishedTask]

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.tertiary)
                Text("还没有任务记录")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text("跑一次 claude 或 codex 任务试试")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(tasks) { task in
                        HistoryRow(task: task)
                        Divider().padding(.leading, 38)
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
        switch task.outcome {
        case .success: return .green
        case .error: return .red
        case .interrupted: return .gray
        }
    }
}
