import EurekaKit
import SwiftUI

/// 任务历史：按天分组的任务时间线（今天 / 更早），状态一眼可辨；
/// 支持「最近活跃 / 开始时间」排序。成功绿圈✓ / 失败红圈✕ / 自动清理灰圈—。
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

    /// 分组键（跟随当前排序依据的日期）
    private func groupKey(_ task: FinishedTask) -> Date {
        sortMode == .active ? task.finishedAt : startKey(task)
    }

    /// 按天分组：今天 / 更早（sortedTasks 已按时间倒序，组内保持该顺序）
    private var dayGroups: [(title: String, tasks: [FinishedTask])] {
        let cal = Calendar.current
        var today: [FinishedTask] = []
        var earlier: [FinishedTask] = []
        for task in sortedTasks {
            if cal.isDateInToday(groupKey(task)) {
                today.append(task)
            } else {
                earlier.append(task)
            }
        }
        var groups: [(String, [FinishedTask])] = []
        if !today.isEmpty { groups.append(("今天", today)) }
        if !earlier.isEmpty { groups.append(("更早", earlier)) }
        return groups
    }

    var body: some View {
        if tasks.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(Theme.brand.opacity(0.45))
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
                // 顶栏：标题 + 排序分段（选中紫底白字）
                HStack {
                    Text("任务历史")
                        .font(Theme.font.pageTitle)
                    Text("共 \(tasks.count) 条")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    CapsuleTabTray {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            CapsuleTabButton(
                                title: mode.label,
                                fillWidth: false,
                                isSelected: sortMode == mode
                            ) { settings.historySortMode = mode.rawValue }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(dayGroups, id: \.title) { group in
                            // 分组头（小写强调标签）
                            Text(group.title)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 12)
                                .padding(.bottom, 4)
                            ForEach(group.tasks) { task in
                                HistoryRow(task: task)
                                Divider().padding(.leading, 44).opacity(0.5)
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct HistoryRow: View {
    let task: FinishedTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 状态圆：成功绿圈✓ / 失败红圈✕ / 自动清理灰圈—
            Image(systemName: iconName)
                .font(.system(size: 13))
                .foregroundStyle(iconColor)
                .frame(width: 16)
                .padding(.top, 1)

            SourceBadge(source: task.source, size: 13)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title ?? task.projectName ?? task.sessionId)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    if let project = task.projectName {
                        Text(project)
                    }
                    if let start = task.sessionStartedAt ?? task.startedAt {
                        Text("·")
                        Text(formatStartTime(start))
                    }
                    if let duration = task.duration {
                        Text("·")
                        Text("时长 \(formatDuration(duration))")
                    }
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

                // 失败红 / 自动清理灰的彩色注释
                if let detail = task.detail, task.outcome != .success {
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(task.outcome == .error
                            ? Theme.failureRed : Theme.autoCleanGray)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            // 右端相对时间
            Text(relativeFormatter.localizedString(for: task.finishedAt, relativeTo: Date()))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, Theme.spacing.row)
    }

    private var iconName: String {
        switch task.outcome {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        case .interrupted: return "minus.circle.fill"
        }
    }

    private var iconColor: Color {
        switch task.outcome {
        case .success: return Theme.enabledGreen
        case .error: return Theme.failureRed
        case .interrupted: return Theme.autoCleanGray
        }
    }
}
