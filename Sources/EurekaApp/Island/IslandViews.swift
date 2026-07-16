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
        let scale = viewModel.uiScale
        switch viewModel.display {
        case .hidden:
            EmptyView()
        case .compact:
            CompactPillView(
                tasks: viewModel.activeTasks,
                hasWaiting: viewModel.hasWaiting,
                centerGap: viewModel.pillCenterGap,
                showStartTime: viewModel.showStartTime,
                scale: scale
            )
        case .card(let card):
            ExpandedCardView(card: card, queuedCount: viewModel.queuedCount, scale: scale)
        case .taskList:
            TaskListCardView(
                tasks: viewModel.activeTasks,
                idleTasks: viewModel.idleTasks,
                showStartTime: viewModel.showStartTime,
                scale: scale,
                expandedTaskId: viewModel.expandedSubagentTaskId,
                onToggleTimeMode: { viewModel.onToggleTimeMode?() },
                onToggleSubagents: { viewModel.toggleSubagentExpansion($0) }
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
    var scale: CGFloat = 1

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6 * scale) {
                if hasWaiting {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14 * scale, weight: .semibold))
                        .foregroundStyle(.orange)
                }
                // 在场来源各一枚「logo + claude/codex」标签
                PulsingSourceBadges(sources: distinctSources, scale: scale)
                Text("\(tasks.count)")
                    .font(.system(size: 14 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity)

            if centerGap > 0 {
                Color.clear.frame(width: centerGap, height: 1)
            }

            HStack(spacing: 5 * scale) {
                // 子 agent 聚合标识（有就显示总数，无则不占位）
                if subagentTotal > 0 {
                    HStack(spacing: 2 * scale) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 11 * scale, weight: .semibold))
                        Text("\(subagentTotal)")
                            .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
                if let earliest = tasks.first {
                    if showStartTime {
                        // 会话最初创建的时间（跨 turn/resume），缺数据退当前 turn 开始
                        Text(formatStartTime(earliest.sessionStartedAt ?? earliest.startedAt))
                            .font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
                            .foregroundStyle(hasWaiting ? .orange : Color(white: 0.85))
                    } else {
                        Text(timerInterval: earliest.startedAt...Date.distantFuture, countsDown: false)
                            .font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
                            .foregroundStyle(hasWaiting ? .orange : Color(white: 0.85))
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14 * scale)
    }

    /// 在场来源（保持稳定顺序：claude 前 codex 后）
    private var distinctSources: [AgentSource] {
        var seen = Set<AgentSource>()
        for task in tasks { seen.insert(task.source) }
        return AgentSource.allCases.filter { seen.contains($0) }
    }

    /// 在场子 agent 总数（compact 胶囊聚合标识）
    private var subagentTotal: Int {
        tasks.reduce(0) { $0 + $1.subagents.count }
    }
}

/// 运行中呼吸点
struct PulsingDot: View {
    var color: Color = .cyan
    var size: CGFloat = 7
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(on ? 1 : 0.35)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - 来源标识（全岛统一语言）

extension AgentSource {
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0.855, green: 0.467, blue: 0.337)  // Anthropic 橙 #DA7756
        case .codex: return Color(red: 0.08, green: 0.62, blue: 0.56)      // OpenAI 青绿
        case .opencode: return Color(red: 0.45, green: 0.42, blue: 0.90)   // opencode 靛紫
        case .grok: return Color(red: 0.129, green: 0.588, blue: 0.953)    // xAI Dodger 蓝 #2196F3
        case .antigravity: return Color(red: 0.898, green: 0.298, blue: 0.612)  // 品红/玫 #E54C9C
        }
    }
}

/// Claude 标记：8 根宽短花瓣，近似 Anthropic/Claude 品牌八芒星
/// 相比初版加宽了辐条（0.34）、缩短了内半径（0.28），花瓣更粗圆
struct ClaudeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        let inner = outer * 0.28
        let thickness = outer * 0.34
        var path = Path()
        for index in 0..<8 {
            let angle = CGFloat(index) * .pi / 4
            let spoke = Path(
                roundedRect: CGRect(
                    x: -thickness / 2, y: -outer,
                    width: thickness, height: outer - inner),
                cornerRadius: thickness / 2)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
            path.addPath(spoke, transform: transform)
        }
        return path
    }
}

/// Codex 标记：5 根细叶片 + 切向偏移，近似 OpenAI 品牌五瓣风车形
/// 每个叶片在其局部坐标系内向右偏移（切向），5 个叶片旋转后形成风车视觉
struct CodexMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let outer = R * 0.96
        let inner = R * 0.20
        let width = R * 0.26
        // 切向偏移：叶片基线不穿过圆心，产生风车叶片感
        let tangentOffset = R * 0.20
        var path = Path()
        for index in 0..<5 {
            let angle = CGFloat(index) * 2 * .pi / 5 - .pi / 2
            let spoke = Path(
                roundedRect: CGRect(
                    x: tangentOffset - width / 2, y: -outer,
                    width: width, height: outer - inner),
                cornerRadius: width / 2)
            let transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: angle)
            path.addPath(spoke, transform: transform)
        }
        return path
    }
}

/// opencode 标记：圆角方框内嵌一个「>」终端提示符，呼应其终端 agent 气质
struct OpencodeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        var path = Path()
        // 外框（圆角方）
        path.addRoundedRect(in: box, cornerSize: CGSize(width: side * 0.24, height: side * 0.24))
        // 内挖一个略小的方，形成描边环
        let innerInset = side * 0.16
        let inner = box.insetBy(dx: innerInset, dy: innerInset)
        path.addRoundedRect(in: inner, cornerSize: CGSize(width: side * 0.14, height: side * 0.14))
        // 中间的「>」：两段折线组成的箭头
        let cx = box.midX - side * 0.06
        let cy = box.midY
        let arm = side * 0.16
        var caret = Path()
        caret.move(to: CGPoint(x: cx - arm, y: cy - arm))
        caret.addLine(to: CGPoint(x: cx + arm, y: cy))
        caret.addLine(to: CGPoint(x: cx - arm, y: cy + arm))
        path.addPath(caret.strokedPath(.init(lineWidth: side * 0.11, lineCap: .round, lineJoin: .round)))
        return path
    }
}

/// Grok 标记：圆角方内挖一道对角斜杠，呼应 xAI/Grok 的「方块 + 斜杠」品牌符号
struct GrokMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        var path = Path()
        // 实心圆角方
        path.addRoundedRect(in: box, cornerSize: CGSize(width: side * 0.26, height: side * 0.26))
        // 对角斜杠「/」：一根粗圆角竖条绕中心顺时针旋转 ~36°，eoFill 挖空成透空斜杠
        let bar = Path(
            roundedRect: CGRect(
                x: box.midX - side * 0.10, y: box.midY - side * 0.44,
                width: side * 0.20, height: side * 0.88),
            cornerRadius: side * 0.10)
        let transform = CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: .pi / 5)
            .translatedBy(x: -box.midX, y: -box.midY)
        path.addPath(bar, transform: transform)
        return path
    }
}

/// Antigravity 标记：双层上升人字（⌃⌃），呼应「反重力 / 上升」
struct AntigravityMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let cx = rect.midX
        let hw = side * 0.30
        let arm = side * 0.26
        var path = Path()
        for apexY in [rect.midY - side * 0.20, rect.midY + side * 0.06] {
            path.move(to: CGPoint(x: cx - hw, y: apexY + arm))
            path.addLine(to: CGPoint(x: cx, y: apexY))
            path.addLine(to: CGPoint(x: cx + hw, y: apexY + arm))
        }
        return path.strokedPath(.init(lineWidth: side * 0.13, lineCap: .round, lineJoin: .round))
    }
}

/// 来源徽标：Claude = 橙色八芒星；Codex = 青绿五瓣风车；opencode = 靛紫终端方框；
/// Grok = 蓝色斜杠方；Antigravity = 品红上升人字
struct SourceBadge: View {
    let source: AgentSource
    var size: CGFloat = 12

    var body: some View {
        switch source {
        case .claude:
            ClaudeMarkShape()
                .fill(source.brandColor)
                .frame(width: size, height: size)
        case .codex:
            CodexMarkShape()
                .fill(source.brandColor)
                .frame(width: size, height: size)
        case .opencode:
            OpencodeMarkShape()
                .fill(source.brandColor, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        case .grok:
            GrokMarkShape()
                .fill(source.brandColor, style: FillStyle(eoFill: true))
                .frame(width: size, height: size)
        case .antigravity:
            AntigravityMarkShape()
                .fill(source.brandColor)
                .frame(width: size, height: size)
        }
    }
}

/// logo + 小写来源名（claude / codex），全岛统一来源语言
struct SourceLabelBadge: View {
    let source: AgentSource
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            SourceBadge(source: source, size: size)
            Text(source.rawValue)  // rawValue 即 "claude"/"codex"
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(source.brandColor)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// 胶囊左翼：呼吸的来源标签（在场来源各一枚 logo + 文字）
struct PulsingSourceBadges: View {
    let sources: [AgentSource]
    var scale: CGFloat = 1
    @State private var on = false

    var body: some View {
        HStack(spacing: 5 * scale) {
            ForEach(sources, id: \.self) { source in
                // 单来源：logo + 文字（胶囊够宽）；多来源并存：只放 logo（刘海两翼放不下两组文字，
                // 完整 claude/codex 文字在展开任务列表里每行都有）
                if sources.count == 1 {
                    SourceLabelBadge(source: source, size: 13 * scale)
                } else {
                    SourceBadge(source: source, size: 13 * scale)
                }
            }
        }
        .opacity(on ? 1 : 0.45)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
        .onAppear { on = true }
    }
}

/// 展开卡片：完成/出错/中断/等待确认。
/// φ 黄金比竖式：图标 + 来源标签在上，文字居中在下。
struct ExpandedCardView: View {
    let card: IslandState.Card
    let queuedCount: Int
    var scale: CGFloat = 1

    var body: some View {
        VStack(spacing: 7 * scale) {
            if case .notice(let notice) = card {
                Text(notice.emoji)
                    .font(.system(size: 38 * scale))
            } else {
                Image(systemName: iconName)
                    .font(.system(size: 34 * scale, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            // 来源标识：logo + claude/codex（notice 无来源）
            if let source = cardSource {
                SourceLabelBadge(source: source, size: 12 * scale)
            }

            VStack(spacing: 3 * scale) {
                Text(headline)
                    .font(.system(size: 14 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                if let title {
                    Text(title)
                        .font(.system(size: 12 * scale))
                        .foregroundStyle(.white.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                Text(subtitle)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 16 * scale)
        .padding(.vertical, 12 * scale)
    }

    private var cardSource: AgentSource? {
        switch card {
        case .finished(let task): return task.source
        case .waiting(let task): return task.source
        case .alert(let alert): return alert.source
        case .notice: return nil
        }
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
        case .alert:
            return "exclamationmark.shield.fill"
        case .notice:
            return "heart.fill"  // 不会走到（notice 渲染 emoji），兜底
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
        case .alert: return .red
        case .notice: return .pink
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
        case .alert(let alert):
            return "高危操作 · \(alert.ruleTitle)"
        case .notice(let notice):
            return notice.headline
        }
    }

    private var title: String? {
        switch card {
        case .finished(let task): return task.title ?? task.projectName
        case .waiting(let task): return taskDisplayName(task)
        case .alert(let alert):
            let firstLine = alert.detail.split(separator: "\n", maxSplits: 1).first.map(String.init)
                ?? alert.detail
            return "\(alert.tool)：\(firstLine)"
        case .notice(let notice): return notice.body
        }
    }

    private var subtitle: String {
        // 来源已由 SourceLabelBadge 表达，副标题只给项目 / 会话号 / 排队数
        let project: String?
        let sessionId: String
        switch card {
        case .finished(let task):
            project = task.projectName
            sessionId = task.sessionId
        case .waiting(let task):
            project = task.projectName
            sessionId = task.sessionId
        case .alert(let alert):
            var parts = ["到「审计」页查看"]
            parts.append("#\(alert.sessionId.prefix(6))")
            if queuedCount > 0 { parts.append("还有 \(queuedCount) 条") }
            return parts.joined(separator: " · ")
        case .notice:
            var parts = ["lulu-lumei-dock 健康提示"]
            if queuedCount > 0 { parts.append("还有 \(queuedCount) 条通知") }
            return parts.joined(separator: " · ")
        }
        var parts: [String] = []
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
    var scale: CGFloat = 1
    /// 当前展开子 agent 框的任务 id（nil = 全收起）
    var expandedTaskId: String? = nil
    var onToggleTimeMode: () -> Void = {}
    var onToggleSubagents: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("进行中 \(tasks.count) 个任务")
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                // 切换右侧时间显示：已持续时长 ↔ 开始时间
                Button(action: onToggleTimeMode) {
                    HStack(spacing: 3 * scale) {
                        Image(systemName: showStartTime ? "calendar.badge.clock" : "stopwatch")
                            .font(.system(size: 9 * scale))
                        Text(showStartTime ? "开始时间" : "耗时")
                            .font(.system(size: 9.5 * scale))
                    }
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 2 * scale)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18 * scale)
            .padding(.top, 10 * scale)
            .padding(.bottom, 4 * scale)

            ForEach(tasks.prefix(4)) { task in
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8 * scale) {
                        statusIcon(task)
                        SourceLabelBadge(source: task.source, size: 10 * scale)
                        Text(taskDisplayName(task))
                            .font(.system(size: 12 * scale))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        Spacer(minLength: 8 * scale)
                        // 子 agent 数量徽标（可点开/收起；无子 agent 不显示）
                        if !task.subagents.isEmpty {
                            subagentBadge(task)
                        }
                        if let activity = task.currentActivity {
                            Text(activity)
                                .font(.system(size: 9.5 * scale).monospaced())
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                        if let context = task.contextUsedPercent, context >= 60 {
                            Text("ctx \(Int(context.rounded()))%")
                                .font(.system(size: 9.5 * scale, weight: .medium).monospacedDigit())
                                .foregroundStyle(contextColor(context))
                        }
                        if showStartTime {
                            Text(formatStartTime(task.sessionStartedAt ?? task.startedAt))
                                .font(.system(size: 11 * scale).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        } else {
                            Text(timerInterval: task.startedAt...Date.distantFuture, countsDown: false)
                                .font(.system(size: 11 * scale).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    .frame(height: 30 * scale)

                    if expandedTaskId == task.id, !task.subagents.isEmpty {
                        subagentBox(task)
                    }
                }
                .padding(.horizontal, 18 * scale)
            }
            if tasks.count > 4 {
                Text("…等 \(tasks.count) 个")
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 18 * scale)
            }

            if !idleTasks.isEmpty {
                Text("空闲会话 \(idleTasks.count)")
                    .font(.system(size: 10 * scale, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 18 * scale)
                    .padding(.top, 5 * scale)
                ForEach(idleTasks.prefix(3)) { task in
                    HStack(spacing: 8 * scale) {
                        Circle()
                            .fill(Color.white.opacity(0.45))
                            .frame(width: 6 * scale, height: 6 * scale)
                        SourceLabelBadge(source: task.source, size: 9 * scale)
                            .opacity(0.75)
                        Text(taskDisplayName(task))
                            .font(.system(size: 11 * scale))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 8 * scale)
                        if let context = task.contextUsedPercent, context >= 60 {
                            Text("ctx \(Int(context.rounded()))%")
                                .font(.system(size: 9.5 * scale).monospacedDigit())
                                .foregroundStyle(contextColor(context).opacity(0.7))
                        }
                        Text(relativeFormatter.localizedString(
                            for: task.lastActivityAt, relativeTo: Date()))
                            .font(.system(size: 10 * scale))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .padding(.horizontal, 18 * scale)
                    .frame(height: 24 * scale)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func statusIcon(_ task: AgentTask) -> some View {
        if case .waiting = task.phase {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10 * scale))
                .foregroundStyle(.orange)
        } else {
            Circle().fill(Color.cyan).frame(width: 6 * scale, height: 6 * scale)
        }
    }

    /// 行尾子 agent 徽标：chevron + 数量，点击展开/收起（内层按钮消费点击）
    private func subagentBadge(_ task: AgentTask) -> some View {
        Button(action: { onToggleSubagents(task.id) }) {
            HStack(spacing: 2 * scale) {
                Image(systemName: expandedTaskId == task.id ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8 * scale, weight: .bold))
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 9 * scale))
                Text("\(task.subagents.count)")
                    .font(.system(size: 9.5 * scale, weight: .semibold).monospacedDigit())
            }
            .foregroundStyle(.white.opacity(0.6))
            .padding(.horizontal, 5 * scale)
            .padding(.vertical, 2 * scale)
            .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
    }

    /// 展开的子 agent 嵌套框：每行 类型 + 描述 + 状态点 + 当前工具
    private func subagentBox(_ task: AgentTask) -> some View {
        VStack(alignment: .leading, spacing: 4 * scale) {
            ForEach(task.subagents.prefix(6)) { sub in
                HStack(spacing: 7 * scale) {
                    subagentStatusDot(sub.status)
                    Text(sub.agentType)
                        .font(.system(size: 10.5 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .fixedSize()
                    Text(sub.description)
                        .font(.system(size: 10 * scale))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    Spacer(minLength: 6 * scale)
                    if let tool = sub.currentActivity {
                        Text(tool)
                            .font(.system(size: 9 * scale).monospaced())
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                }
                .frame(height: 22 * scale)
            }
            if task.subagents.count > 6 {
                Text("…等 \(task.subagents.count) 个子 agent")
                    .font(.system(size: 9.5 * scale))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(height: 16 * scale)
            }
        }
        .padding(.leading, 22 * scale)
        .padding(.trailing, 12 * scale)
        .padding(.vertical, 8 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8 * scale).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder
    private func subagentStatusDot(_ status: SubagentInfo.Status) -> some View {
        switch status {
        case .running:
            PulsingDot(color: .cyan, size: 6 * scale)
        case .completed:
            Circle().fill(Color.green).frame(width: 6 * scale, height: 6 * scale)
        case .failed:
            Circle().fill(Color.red).frame(width: 6 * scale, height: 6 * scale)
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
