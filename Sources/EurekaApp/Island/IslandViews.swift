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
        // 点按/拖拽由 IslandHostingView 的 AppKit 事件统一处理（拖动窗口需要 performDrag）
        UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
            .fill(Color.black)
            .frame(width: size.width, height: size.height)
            .overlay(content.clipShape(UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)))
            .shadow(color: .black.opacity(0.38), radius: 12, y: 5)
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
                centerGap: viewModel.pillCenterGap
            )
        case .card(let card):
            ExpandedCardView(card: card, queuedCount: viewModel.queuedCount)
        case .taskList:
            TaskListCardView(tasks: viewModel.activeTasks)
        }
    }
}

/// compact 胶囊：左翼状态 + 数量，右翼最早任务计时；中部为物理刘海留空
struct CompactPillView: View {
    let tasks: [AgentTask]
    let hasWaiting: Bool
    let centerGap: CGFloat

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
                    Text(timerInterval: earliest.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(hasWaiting ? .orange : Color(white: 0.85))
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
        case .finished(let task): return task.title
        case .waiting(let task): return task.title
        }
    }

    private var subtitle: String {
        let source: AgentSource
        let project: String?
        switch card {
        case .finished(let task):
            source = task.source
            project = task.projectName
        case .waiting(let task):
            source = task.source
            project = task.projectName
        }
        var parts = [source.displayName]
        if let project { parts.append(project) }
        if queuedCount > 0 { parts.append("还有 \(queuedCount) 条通知") }
        return parts.joined(separator: " · ")
    }
}

/// 点击胶囊展开的进行中任务列表
struct TaskListCardView: View {
    let tasks: [AgentTask]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("进行中 \(tasks.count) 个任务")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 18)
                .padding(.top, 10)
                .padding(.bottom, 4)

            ForEach(tasks.prefix(4)) { task in
                HStack(spacing: 8) {
                    statusIcon(task)
                    Text(task.title ?? task.projectName ?? task.sessionId)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Text(timerInterval: task.startedAt...Date.distantFuture, countsDown: false)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
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
