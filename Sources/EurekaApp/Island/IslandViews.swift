import EurekaKit
import SwiftUI

/// 灵动岛根视图：单一黑色圆角形随状态弹簧变形，内容随状态切换
struct IslandRootView: View {
    @ObservedObject var viewModel: IslandViewModel

    var body: some View {
        let size = viewModel.contentSize
        VStack(spacing: 0) {
            if viewModel.display != .hidden {
                island(size: size)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .top)))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, viewModel.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.8), value: viewModel.display)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: viewModel.isFloating)
    }

    private func island(size: CGSize) -> some View {
        // 拖拽在 IslandHostingView（performDrag）；点按回到 SwiftUI——
        // 内部按钮优先消费，背景 tap 才走 islandTapped
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
            .overlay(content.clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)))
            .shadow(color: .black.opacity(0.38), radius: 12, y: 5)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.islandTapped() }
    }

    /// 刘海融合：上沿直角；浮动/普通屏：四角全圆
    private var cornerRadii: RectangleCornerRadii {
        let fused = viewModel.fuseWithNotch
        switch viewModel.display {
        case .compact:
            let bottomRadius: CGFloat = fused ? 12 : 15
            return RectangleCornerRadii(
                topLeading: fused ? 0 : 15, bottomLeading: bottomRadius,
                bottomTrailing: bottomRadius, topTrailing: fused ? 0 : 15)
        default:
            return RectangleCornerRadii(
                topLeading: fused ? 0 : 18, bottomLeading: 22,
                bottomTrailing: 22, topTrailing: fused ? 0 : 18)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.display {
        case .hidden:
            EmptyView()
        case .compact:
            CompactPillView(
                tasks: viewModel.activeTasks,
                hasWaiting: viewModel.hasWaiting,
                centerGap: viewModel.pillCenterGap,
                showStartTime: viewModel.showStartTime
            )
        case .card(let card):
            ExpandedCardView(card: card, queuedCount: viewModel.queuedCount)
        case .taskList:
            TaskListCardView(
                tasks: viewModel.activeTasks,
                idleTasks: viewModel.idleTasks,
                showStartTime: viewModel.showStartTime,
                onToggleTimeMode: { viewModel.onToggleTimeMode?() }
            )
        }
    }
}

/// compact 胶囊：左翼状态 + 数量，右翼最早任务计时/开始时间；中部为物理刘海留空
struct CompactPillView: View {
    let tasks: [AgentTask]
    let hasWaiting: Bool
    let centerGap: CGFloat
    var showStartTime = false

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                if hasWaiting {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.orange)
                } else {
                    PulsingDot()
                }
                Text("\(tasks.count)")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            if centerGap > 0 {
                Color.clear.frame(width: centerGap, height: 1)
            }

            Group {
                if let earliest = tasks.first {
                    if showStartTime {
                        Text(formatStartTime(earliest.startedAt))
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(hasWaiting ? .orange : Color(white: 0.85))
                    } else {
                        Text(timerInterval: earliest.startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(hasWaiting ? .orange : Color(white: 0.85))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 12)
    }
}

/// 运行中呼吸点
struct PulsingDot: View {
    @State private var on = false

    var body: some View {
        Circle()
            .fill(Color.cyan)
            .frame(width: 7, height: 7)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// 展开卡片：完成/出错/中断/等待确认
struct ExpandedCardView: View {
    let card: IslandState.Card
    let queuedCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                if let title {
                    Text(title)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.78))
                        .lineLimit(2)
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var iconName: String {
        switch card {
        case .finished(let task):
            switch task.outcome {
            case .success: return "checkmark.circle.fill"
            case .error: return "xmark.octagon.fill"
            case .interrupted: return "minus.circle.fill"
            }
        case .waiting(let task):
            if case .waiting(.permission, _) = task.phase { return "hand.raised.fill" }
            return "ellipsis.bubble.fill"
        }
    }

    private var iconColor: Color {
        switch card {
        case .finished(let task):
            switch task.outcome {
            case .success: return .green
            case .error: return .red
            case .interrupted: return .gray
            }
        case .waiting: return .orange
        }
    }

    private var headline: String {
        switch card {
        case .finished(let task):
            let verb: String
            switch task.outcome {
            case .success: verb = "任务完成"
            case .error: verb = "任务出错"
            case .interrupted: verb = "任务中断"
            }
            if let duration = task.duration {
                return "\(verb) · 耗时 \(formatDuration(duration))"
            }
            return verb
        case .waiting(let task):
            if case .waiting(let reason, _) = task.phase { return reason.displayName }
            return "等待中"
        }
    }

    private var title: String? {
        switch card {
        case .finished(let task): return task.title ?? task.projectName
        case .waiting(let task): return taskDisplayName(task)
        }
    }

    private var subtitle: String {
        let source: AgentSource
        let project: String?
        let sessionId: String
        switch card {
        case .finished(let task):
            source = task.source
            project = task.projectName
            sessionId = task.sessionId
        case .waiting(let task):
            source = task.source
            project = task.projectName
            sessionId = task.sessionId
        }
        var parts = [source.displayName]
        if let project { parts.append(project) }
        parts.append("#\(sessionId.prefix(6))")  // 多会话同项目时靠它区分
        if queuedCount > 0 { parts.append("还有 \(queuedCount) 条通知") }
        return parts.joined(separator: " · ")
    }
}

/// 任务标识：标题 → 项目名 → 短会话号，永远能认出是哪个会话
func taskDisplayName(_ task: AgentTask) -> String {
    task.title ?? task.projectName ?? "会话 \(task.sessionId.prefix(8))"
}

/// 点击胶囊展开的进行中任务列表（含空闲会话分组）
struct TaskListCardView: View {
    let tasks: [AgentTask]
    var idleTasks: [AgentTask] = []
    var showStartTime = false
    var onToggleTimeMode: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("进行中 \(tasks.count) 个任务")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                // 切换右侧时间显示：已持续时长 ↔ 开始时间
                Button(action: onToggleTimeMode) {
                    HStack(spacing: 3) {
                        Image(systemName: showStartTime ? "calendar.badge.clock" : "stopwatch")
                            .font(.system(size: 9))
                        Text(showStartTime ? "开始时间" : "耗时")
                            .font(.system(size: 9.5))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 4)

            ForEach(tasks.prefix(4)) { task in
                HStack(spacing: 8) {
                    statusIcon(task)
                    Text(taskDisplayName(task))
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let activity = task.currentActivity {
                        Text(activity)
                            .font(.system(size: 9.5).monospaced())
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    if let context = task.contextUsedPercent, context >= 60 {
                        Text("ctx \(Int(context.rounded()))%")
                            .font(.system(size: 9.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(contextColor(context))
                    }
                    if showStartTime {
                        Text(formatStartTime(task.startedAt))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    } else {
                        Text(timerInterval: task.startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
                .padding(.horizontal, 18)
                .frame(height: 30)
            }
            if tasks.count > 4 {
                Text("…等 \(tasks.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 18)
            }

            if !idleTasks.isEmpty {
                Text("空闲会话 \(idleTasks.count)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 18)
                    .padding(.top, 5)
                ForEach(idleTasks.prefix(3)) { task in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 6, height: 6)
                        Text(taskDisplayName(task))
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let context = task.contextUsedPercent, context >= 60 {
                            Text("ctx \(Int(context.rounded()))%")
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(contextColor(context).opacity(0.7))
                        }
                        Text(relativeFormatter.localizedString(
                            for: task.lastActivityAt, relativeTo: Date()))
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 24)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusIcon(_ task: AgentTask) -> some View {
        if case .waiting = task.phase {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else {
            Circle().fill(Color.cyan).frame(width: 6, height: 6)
        }
    }

    private func contextColor(_ percent: Double) -> Color {
        switch percent {
        case ..<80: return .white.opacity(0.45)
        case ..<90: return .orange
        default: return .red
        }
    }
}

private let startTimeTodayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private let startTimeFullFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "M/d HH:mm"
    return formatter
}()

/// 任务开始的日期时间：今天只显时刻，跨天带日期
func formatStartTime(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? startTimeTodayFormatter.string(from: date)
        : startTimeFullFormatter.string(from: date)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return "\(total) 秒" }
    if total < 3600 {
        let m = total / 60, s = total % 60
        return s == 0 ? "\(m) 分钟" : "\(m) 分 \(s) 秒"
    }
    let h = total / 3600, m = (total % 3600) / 60
    return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
}
