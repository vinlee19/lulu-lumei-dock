import EurekaKit
import SwiftUI

/// Dynamic Island root view: a single black rounded shape that spring-morphs with state; content
/// switches with state
struct IslandRootView: View {
    @ObservedObject var viewModel: IslandViewModel

    /// Background for floating / no-notch screens #1C1C20 (design mock agent-dock-final)
    private static let floatingFill = Color(red: 0.110, green: 0.110, blue: 0.125)

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
        // When the session link arrives after the card is up, the card grows and the button fades in
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: viewModel.cardJump)
        // Rebuild the whole island on language change so already-projected copy picks up the new
        // language
        .id(viewModel.language)
    }

    private func island(size: CGSize) -> some View {
        // Dragging lives in IslandHostingView (performDrag); clicks go back to SwiftUI -- inner
        // buttons consume first, only background taps reach islandTapped
        let shape = UnevenRoundedRectangle(cornerRadii: cornerRadii, style: .continuous)
        let fused = viewModel.fuseWithNotch
        return shape
            // Must be pure black when fused with the notch (top edge meets the physical notch);
            // floating / no-notch screens use a dark gray fill + thin border
            .fill(fused ? Color.black : Self.floatingFill)
            .overlay(shape.stroke(Color.white.opacity(fused ? 0 : 0.09), lineWidth: 1))
            .frame(width: size.width, height: size.height)
            .overlay(content.clipShape(shape))
            .shadow(color: .black.opacity(0.38), radius: 12, y: 5)
            .contentShape(Rectangle())
            .onTapGesture { viewModel.islandTapped() }
    }

    /// Notch-merged: square top edge; floating / regular screen: all four corners rounded
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
                idleTasks: viewModel.idleTasks,
                unread: viewModel.unreadFinished,
                centerGap: viewModel.pillCenterGap,
                showStartTime: viewModel.showStartTime,
                scale: scale
            )
        case .card(.question):
            if let draft = viewModel.questionDraft {
                QuestionCardView(
                    draft: draft,
                    sessionLabel: viewModel.questionSessionLabel,
                    scale: scale,
                    topInset: viewModel.questionTopInset,
                    questionLines: viewModel.questionLines,
                    onChoose: { viewModel.chooseOption($0) },
                    onToggle: { viewModel.toggleOption($0) },
                    onConfirm: { viewModel.confirmSelection() },
                    onBeginOther: { viewModel.beginOther() },
                    onCancelOther: { viewModel.cancelOther() },
                    onSubmitOther: { viewModel.submitOther($0) },
                    onDismiss: { viewModel.dismissQuestion() })
            }
        case .card(let card):
            ExpandedCardView(
                card: card, queuedCount: viewModel.queuedCount, scale: scale,
                jump: viewModel.cardJump, onJump: { viewModel.openSessionFromCard() })
        case .taskList:
            TaskListCardView(
                tasks: viewModel.activeTasks,
                idleTasks: viewModel.idleTasks,
                showStartTime: viewModel.showStartTime,
                scale: scale,
                centerGap: viewModel.pillCenterGap,
                expandedTaskId: viewModel.expandedSubagentTaskId,
                onToggleTimeMode: { viewModel.onToggleTimeMode?() },
                onToggleSubagents: { viewModel.toggleSubagentExpansion($0) },
                jumpOption: { viewModel.jumpOption(for: $0) },
                onJump: { viewModel.openSession($0) }
            )
        }
    }
}

/// Compact pill (the "menu bar strip" in design mock agent-dock-final), with the middle left empty
/// for the physical notch:
/// - left wing: present source icons (lit with a cyan dot when a session is running, dimmed when
///   only idle sessions remain) + running count;
/// - right wing: alert slot, waiting for permission/input > ctx ≥ 90% > unread finished, see
///   `IslandPill.alert`; with no alert it shows the oldest task's timer.
struct CompactPillView: View {
    let tasks: [AgentTask]
    var idleTasks: [AgentTask] = []
    var unread = IslandUnreadFinished()
    let centerGap: CGFloat
    var showStartTime = false
    var scale: CGFloat = 1

    private static let accent = Color(red: 0.353, green: 0.784, blue: 0.980)      // #5AC8FA
    private static let alertRed = Color(red: 1.0, green: 0.420, blue: 0.392)      // #FF6B64

    var body: some View {
        // Each wing is a fixed share of a fixed-width pill, and nothing in it may wrap: a
        // two-digit count once became a vertical "3/0" and a cross-day start time a two-line
        // date. Every text is `fixedSize`, and when a wing still cannot fit, ViewThatFits drops
        // its least important piece (dimmed idle sources on the left, the alert icon or the
        // subagent marker on the right) instead of letting SwiftUI break a line.
        let marks = IslandPill.sourceMarks(active: tasks, idle: idleTasks)
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                leftWing(marks)
                leftWing(marks.filter(\.isActive))
                leftWing([])
            }
            .frame(maxWidth: .infinity)

            if centerGap > 0 {
                Color.clear.frame(width: centerGap, height: 1)
            }

            Group {
                if let alert = IslandPill.alert(active: tasks, idle: idleTasks, unread: unread) {
                    ViewThatFits(in: .horizontal) {
                        alertBadge(alert, showIcon: true, showText: true)
                        alertBadge(alert, showIcon: false, showText: true)
                        alertBadge(alert, showIcon: true, showText: false)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        rightWing(showSubagents: true)
                        rightWing(showSubagents: false)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 14 * scale)
    }

    /// Left wing: source icons + running count (count hidden when nothing is running)
    private func leftWing(_ marks: [IslandPill.SourceMark]) -> some View {
        HStack(spacing: 7 * scale) {
            ForEach(marks, id: \.source) { mark in
                sourceIcon(mark)
            }
            if !tasks.isEmpty {
                Text("\(tasks.count)")
                    .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.accent)
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 1 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 5 * scale).fill(Self.accent.opacity(0.14)))
                    .fixedSize()
            }
        }
    }

    private func sourceIcon(_ mark: IslandPill.SourceMark) -> some View {
        SourceBadge(source: mark.source, size: 15 * scale, onDark: true)
            .opacity(mark.isActive ? 1 : 0.4)
            .overlay(alignment: .topTrailing) {
                if mark.isActive {
                    RunningSourceDot(color: Self.accent, size: 6.5 * scale)
                        .offset(x: 1 * scale, y: -1 * scale)
                }
            }
    }

    /// Right-wing alert badge; when it doesn't fit, drop the icon first, then keep only the icon
    private func alertBadge(
        _ alert: IslandPill.Alert, showIcon: Bool, showText: Bool
    ) -> some View {
        let style = alertStyle(alert)
        return HStack(spacing: 4 * scale) {
            if showIcon {
                Image(systemName: style.icon)
                    .font(.system(size: 10 * scale, weight: .bold))
            }
            if showText {
                Text(style.text)
            }
        }
        .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
        .foregroundStyle(style.color)
        .padding(.horizontal, 7 * scale)
        .padding(.vertical, 2 * scale)
        .background(RoundedRectangle(cornerRadius: 6 * scale).fill(style.color.opacity(0.16)))
        .fixedSize()
    }

    /// Unread-finished icon and color match the finished card (success green ✓ / error red /
    /// interrupted gray)
    private func alertStyle(_ alert: IslandPill.Alert) -> (icon: String, text: String, color: Color) {
        switch alert {
        case .waiting(.permission):
            return ("hand.raised.fill", L10n.text("Needs permission", zhHans: "等待授权"), .orange)
        case .waiting(.idle):
            return ("ellipsis.bubble.fill", L10n.text("Waiting for input", zhHans: "等待输入"), .orange)
        case .context(let percent):
            return ("exclamationmark.triangle.fill", "ctx \(Int(percent.rounded()))%", Self.alertRed)
        case .unread(let count, .success):
            return ("checkmark.circle.fill", "\(count)", .green)
        case .unread(let count, .error):
            return ("xmark.octagon.fill", "\(count)", Self.alertRed)
        case .unread(let count, .interrupted):
            return ("minus.circle.fill", "\(count)", .gray)
        }
    }

    /// Right wing: aggregate subagent marker + the earliest task's timer / start time
    private func rightWing(showSubagents: Bool) -> some View {
        HStack(spacing: 5 * scale) {
            // Aggregated subagent marker (shows the total if any, takes no space otherwise)
            if showSubagents, subagentTotal > 0 {
                HStack(spacing: 2 * scale) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 11 * scale, weight: .semibold))
                    Text("\(subagentTotal)")
                        .font(.system(size: 12 * scale, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize()
            }
            if let earliest = tasks.first {
                Group {
                    if showStartTime {
                        // When the session was first created (across turns/resume); falls back to
                        // the current turn start if missing
                        Text(formatStartTime(earliest.sessionStartedAt ?? earliest.startedAt))
                    } else {
                        Text(timerInterval: earliest.startedAt...Date.distantFuture, countsDown: false)
                    }
                }
                .font(.system(size: 13 * scale, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(white: 0.85))
                .lineLimit(1)
                .fixedSize()
            }
        }
    }

    /// Total present subagents (aggregate marker on the compact pill)
    private var subagentTotal: Int {
        tasks.reduce(0) { $0 + $1.subagents.count }
    }
}

/// Running dot at the top-right of a pill source icon: an outer ring in the background color "cuts"
/// it out of the icon; it glows and breathes slowly
struct RunningSourceDot: View {
    let color: Color
    let size: CGFloat
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(Color.black, lineWidth: size * 0.23))
            .shadow(color: color.opacity(0.9), radius: size * 0.4)
            .opacity(on ? 1 : 0.55)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Breathing running dot
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

// MARK: - Source badges (one visual language across the island)

extension AgentSource {
    var brandColor: Color {
        switch self {
        case .claude: return Color(red: 0.855, green: 0.467, blue: 0.337)  // Anthropic orange #DA7756
        case .codex: return Color(red: 0.08, green: 0.62, blue: 0.56)      // OpenAI teal
        // OpenCode's official logo is black-and-white → dynamic color: near-black #211E1E in light
        // mode, light grey in dark mode (visible on the island)
        case .opencode: return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.85, green: 0.85, blue: 0.85, alpha: 1)
                : NSColor(srgbRed: 0.129, green: 0.118, blue: 0.118, alpha: 1)
        }))
        case .grok: return Color(red: 0.129, green: 0.588, blue: 0.953)    // xAI Dodger blue #2196F3
        case .antigravity: return Color(red: 0.898, green: 0.298, blue: 0.612)  // magenta/rose #E54C9C
        case .kimi: return Color(red: 0.090, green: 0.514, blue: 1.0)      // Moonshot azure #1783FF
        case .gemini: return Color(red: 0.259, green: 0.522, blue: 0.957)  // Google blue #4285F4
        case .qwen: return Color(red: 0.38, green: 0.36, blue: 0.93)       // Tongyi purple #615CED
        // Hermes (Nous Research) official artwork is black-and-white line art → dynamic ink like
        // OpenCode: near-black #1A1A1E in light, light grey #E4E4E8 in dark (must stay visible on
        // the always-dark island). To make it colored, change only this spot.
        case .hermes: return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.894, green: 0.894, blue: 0.909, alpha: 1)
                : NSColor(srgbRed: 0.102, green: 0.102, blue: 0.118, alpha: 1)
        }))
        // CodeBuddy's official logo is a teal→purple radial gradient (#2EA99D → #6C4DFF) → use the
        // dominant purple
        case .codebuddy: return Color(red: 0.424, green: 0.302, blue: 1.0)  // CodeBuddy purple #6C4DFF
        case .qoder: return Color(red: 0.165, green: 0.859, blue: 0.361)    // Qoder green #2ADB5C
        // Cursor's official mark is a pure black-and-white cube → dynamic ink like OpenCode /
        // Hermes; hardcoded black would vanish entirely on the always-dark island
        case .cursor: return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.92, green: 0.92, blue: 0.94, alpha: 1)
                : NSColor(srgbRed: 0.07, green: 0.07, blue: 0.08, alpha: 1)
        }))
        // TRAE's official mark is mint-green brackets. Same green family as Qoder's #2ADB5C but
        // more cyan; the two must stay distinguishable side by side -- after changing this, check
        // visually with `--render-badges`.
        case .trae: return Color(red: 0.196, green: 0.941, blue: 0.549)      // TRAE green #32F08C
        // ZCode (Z.ai) official mark is a monochrome currentColor Z → dynamic ink like
        // OpenCode/Cursor, paired with the two-variant logo-zcode{,-dark}.svg assets
        case .zcode: return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.894, green: 0.894, blue: 0.909, alpha: 1)
                : NSColor(srgbRed: 0.102, green: 0.102, blue: 0.118, alpha: 1)
        }))
        }
    }
}

/// Claude mark: 8 wide, short petals approximating the Anthropic/Claude eight-pointed star.
/// Compared with the first version the spokes are wider (0.34) and the inner radius shorter (0.28),
/// so petals are fuller
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

/// Codex mark: 5 thin blades with tangential offset, approximating OpenAI's five-blade pinwheel.
/// Each blade is offset rightward (tangentially) in its local frame; rotating 5 blades yields the
/// pinwheel look
struct CodexMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let R = min(rect.width, rect.height) / 2
        let outer = R * 0.96
        let inner = R * 0.20
        let width = R * 0.26
        // Tangential offset: the blade baseline misses the center, giving a pinwheel-blade feel
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

/// OpenCode mark: official logo -- a tall solid frame with a window cut out (32×40 viewbox); the
/// lower 2/3 of the window is filled back semi-transparently by OpencodeWindowShape, a monochrome
/// take on the original black frame / grey window. eoFill.
struct OpencodeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let box = Self.logoBox(in: rect)
        var path = Path()
        path.addRect(box)
        // Window hole: x 8→24 / 32, y 8→32 / 40
        path.addRect(CGRect(
            x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.2,
            width: box.width * 0.5, height: box.height * 0.6))
        return path
    }

    /// Fit the 32×40 viewbox proportionally, centered
    static func logoBox(in rect: CGRect) -> CGRect {
        let height = min(rect.height, rect.width / 0.8)
        let width = height * 0.8
        return CGRect(
            x: rect.midX - width / 2, y: rect.midY - height / 2,
            width: width, height: height)
    }
}

/// Lower half of the OpenCode window (original #BCBBBB grey): y 16→32 / 40
struct OpencodeWindowShape: Shape {
    func path(in rect: CGRect) -> Path {
        let box = OpencodeMarkShape.logoBox(in: rect)
        return Path(CGRect(
            x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.4,
            width: box.width * 0.5, height: box.height * 0.4))
    }
}

/// Grok mark: rounded square with a diagonal slash cut out, echoing xAI/Grok's "square + slash"
/// brand symbol
struct GrokMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let box = CGRect(
            x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        var path = Path()
        // Solid rounded square
        path.addRoundedRect(in: box, cornerSize: CGSize(width: side * 0.26, height: side * 0.26))
        // Diagonal slash "/": a thick rounded vertical bar rotated ~36° clockwise about the center,
        // eoFill cuts it out as a see-through slash
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

/// Kimi mark: geometric "K" in three strokes (stem + upper arm + lower leg, round caps) + top-right
/// dot, echoing the Moonshot/Kimi wordmark (K reaching up, blue dot on top). Close to Grok's blue,
/// so the K shape tells them apart.
struct KimiMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let x0 = rect.midX - side / 2
        let y0 = rect.midY - side / 2
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: x0 + fx * side, y: y0 + fy * side)
        }
        var strokes = Path()
        // Stem
        strokes.move(to: point(0.19, 0.17))
        strokes.addLine(to: point(0.19, 0.83))
        // Upper arm (from mid-stem toward the upper right)
        strokes.move(to: point(0.19, 0.50))
        strokes.addLine(to: point(0.72, 0.20))
        // Lower leg (from mid-stem toward the lower right)
        strokes.move(to: point(0.19, 0.50))
        strokes.addLine(to: point(0.71, 0.83))
        var path = strokes.strokedPath(
            .init(lineWidth: side * 0.13, lineCap: .round, lineJoin: .round))
        // Top-right dot (the K's "moon" on top)
        let r = side * 0.075
        let nub = point(0.87, 0.11)
        path.addEllipse(in: CGRect(x: nub.x - r, y: nub.y - r, width: r * 2, height: r * 2))
        return path
    }
}

/// Hermes mark: winged helmet (Hermes' petasos) -- solid dome + brim + swept-back wings on both
/// sides. Nous' official artwork is a 512px black-and-white illustration (opaque white background +
/// black outline); shrunk to the badge's real 9-15pt it blurs into a dark square, so like OpenCode
/// it is drawn proportionally in code. **Solid silhouette, not thin strokes**: the marks in this
/// set that stay clear at 9pt (Claude star / Gemini four-point star / Kimi K) are all solid; thin
/// lines blur into waves at 18px.
struct HermesMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        /// Normalized point: relative to the rect center, centered even when not square
        func point(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + side * (fx - 0.5), y: rect.midY + side * (fy - 0.5))
        }
        var path = Path()
        // Dome: upper arc + bottom edge closed = solid semicircle (y points down; 180°→360° via
        // 270° is straight up)
        path.move(to: point(0.27, 0.62))
        path.addArc(
            center: point(0.50, 0.62), radius: side * 0.23,
            startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        path.closeSubpath()
        // Brim: rounded bar slightly wider than the dome
        let brimOrigin = point(0.20, 0.62)
        path.addRoundedRect(
            in: CGRect(x: brimOrigin.x, y: brimOrigin.y,
                       width: side * 0.60, height: side * 0.09),
            cornerSize: CGSize(width: side * 0.045, height: side * 0.045))
        // Swept-back wings: flare outward and up from both brim ends; wingtips must clear the brim
        // clearly to read as "wings"
        for direction in [CGFloat(-1), 1] {
            let inner = 0.5 + direction * 0.27
            let tip = 0.5 + direction * 0.50
            path.move(to: point(inner, 0.625))
            path.addLine(to: point(tip, 0.40))
            path.addLine(to: point(inner, 0.735))
            path.closeSubpath()
        }
        return path
    }
}

/// Antigravity mark: double rising chevrons (⌃⌃), echoing "anti-gravity / rising"
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

/// Official logo assets (Resources/source-logos/*, vectors rendered natively by NSImage on macOS
/// 14). Grok / Qoder / Cursor official marks are pure black (or currentColor) → use the white
/// variant in dark appearance; OpenCode is drawn in code (see OpencodeMarkShape). Hermes only ships
/// a bitmap officially (no vector) → load by extension; PNG and SVG share the same NSImage decode
/// path.
enum SourceLogo {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    static func image(for source: AgentSource, dark: Bool) -> NSImage? {
        let name: String
        var ext = "svg"
        switch source {
        case .claude: name = "logo-claude"
        case .codex: name = "logo-codex"
        case .grok: name = dark ? "logo-grok-dark" : "logo-grok"
        case .antigravity: name = "logo-antigravity"
        case .kimi: name = "logo-kimi"
        case .gemini: name = "logo-gemini"
        case .qwen: name = "logo-qwen"
        case .hermes:
            name = "logo-hermes"
            ext = "png"  // Nous' official artwork is a 512×512 bitmap
        case .codebuddy: name = "logo-codebuddy"
        case .qoder: name = dark ? "logo-qoder-dark" : "logo-qoder"
        case .cursor: name = dark ? "logo-cursor-dark" : "logo-cursor"
        // TRAE's official mark is itself mint green (#32F08C), visible on light and dark → no -dark
        // variant needed
        case .trae: name = "logo-trae"
        // ZCode (Z.ai) official mark is monochrome currentColor → two variants: dark ink for light,
        // light grey for dark
        case .zcode: name = dark ? "logo-zcode-dark" : "logo-zcode"
        case .opencode: return nil  // No asset: SourceBadge takes the code-drawn branch
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        guard let url = AppResources.bundle.url(
            forResource: name, withExtension: ext, subdirectory: "source-logos"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        cache[name] = image
        return image
    }
}

/// Source badge: official logo (SVG vector); OpenCode is a code drawing of the official geometry;
/// falls back to the old brand-color shapes when an asset is missing. Old notes: Claude = orange
/// eight-pointed star; Codex = teal five-blade pinwheel; Grok = blue slashed square; Antigravity =
/// magenta rising chevrons
struct SourceBadge: View {
    let source: AgentSource
    var size: CGFloat = 12
    /// Force the dark-appearance logo variant (the Dynamic Island is always dark, regardless of
    /// system appearance)
    var onDark: Bool?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if source == .opencode {
            ZStack {
                OpencodeWindowShape()
                    .fill(source.brandColor.opacity(0.45))
                OpencodeMarkShape()
                    .fill(source.brandColor, style: FillStyle(eoFill: true))
            }
            .frame(width: size, height: size)
        } else if let image = SourceLogo.image(
            for: source, dark: onDark ?? (colorScheme == .dark)) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            fallbackShape
                .frame(width: size, height: size)
        }
    }

    /// Fallback when an asset is missing: keep the old brand-color geometric marks
    @ViewBuilder
    private var fallbackShape: some View {
        switch source {
        case .claude:
            ClaudeMarkShape().fill(source.brandColor)
        case .codex:
            CodexMarkShape().fill(source.brandColor)
        case .grok:
            GrokMarkShape().fill(source.brandColor, style: FillStyle(eoFill: true))
        case .antigravity:
            AntigravityMarkShape().fill(source.brandColor)
        case .kimi:
            KimiMarkShape().fill(source.brandColor)
        case .gemini:
            GeminiMarkShape().fill(source.brandColor)
        case .qwen:
            GeminiMarkShape().fill(source.brandColor)  // Fallback also uses the four-point star (only when the asset is missing)
        case .hermes:
            HermesMarkShape().fill(source.brandColor)  // Fallback only when logo-hermes.png is missing
        case .codebuddy:
            // Fallback rounded square (close to the official rounded-rectangle base; only when the
            // asset is missing)
            RoundedRectangle(cornerRadius: size * 0.28).fill(source.brandColor)
        case .qoder:
            Circle().fill(source.brandColor)  // Fallback dot (only when the asset is missing)
        case .cursor:
            // Fallback solid hexagon (the official mark is an isometric cube; thin strokes blur at
            // 9pt, so use a solid silhouette)
            CursorMarkShape().fill(source.brandColor)
        case .trae:
            // Fallback square (the official mark is a bracket viewfinder; like CursorMarkShape,
            // solid rather than stroked; only reached when logo-trae.svg is missing)
            RoundedRectangle(cornerRadius: size * 0.18).fill(source.brandColor)
        case .zcode:
            // Fallback Z silhouette (the official Z is built from three chevron bands; solid
            // silhouette at 9pt)
            ZcodeMarkShape().fill(source.brandColor)
        case .opencode:
            EmptyView()
        }
    }
}

/// ZCode fallback mark: thick Z silhouette (used only when logo-zcode{,-dark}.svg is missing). The
/// official Z.ai mark forms a Z from three chevron bands; approximated here by two bars + one
/// slash; solid, not stroked.
struct ZcodeMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let bar = side * 0.22
        let inset = side * 0.1
        var path = Path()
        // Top bar / bottom bar (square-cornered rectangles; rounded corners are pointless at 9pt)
        path.addRect(CGRect(
            x: rect.minX + inset, y: rect.minY + inset,
            width: side - inset * 2, height: bar))
        path.addRect(CGRect(
            x: rect.minX + inset, y: rect.maxY - inset - bar,
            width: side - inset * 2, height: bar))
        // Slash (parallelogram joining top right to bottom left)
        let skew = side * 0.14
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: rect.maxX - inset - skew, y: rect.minY + inset + bar))
        diagonal.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.minY + inset + bar * 0.4))
        diagonal.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY - inset - bar * 0.4))
        diagonal.addLine(to: CGPoint(x: rect.minX + inset + skew, y: rect.maxY - inset - bar))
        diagonal.closeSubpath()
        path.addPath(diagonal)
        return path
    }
}

/// Cursor fallback mark: solid regular hexagon (orthographic outline of the official isometric
/// cube; used only when the asset is missing). Like HermesMarkShape, solid rather than thin strokes
/// -- thin lines blur into a blob at 9pt.
struct CursorMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let r = side / 2
        var path = Path()
        for index in 0..<6 {
            // Clockwise from straight up, vertex on top (matching the official cube's stance)
            let angle: Double = Double(index) / 6 * 2 * Double.pi - Double.pi / 2
            let point = CGPoint(
                x: cx + r * CGFloat(Foundation.cos(angle)),
                y: cy + r * CGFloat(Foundation.sin(angle)))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// Gemini fallback mark: four-point star (minimal geometric approximation of the official spark;
/// used only when the asset is missing)
struct GeminiMarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let side = min(rect.width, rect.height)
        let cx = rect.midX, cy = rect.midY
        let r = side / 2
        let inner = r * 0.28
        var path = Path()
        path.move(to: CGPoint(x: cx, y: cy - r))
        path.addQuadCurve(
            to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + inner, y: cy - inner))
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + inner, y: cy + inner))
        path.addQuadCurve(
            to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - inner, y: cy + inner))
        path.addQuadCurve(
            to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - inner, y: cy - inner))
        path.closeSubpath()
        return path
    }
}

/// logo + lowercase source name (claude / codex), one source language across the island
struct SourceLabelBadge: View {
    let source: AgentSource
    var size: CGFloat = 11

    var body: some View {
        HStack(spacing: 3) {
            SourceBadge(source: source, size: size, onDark: true)
            Text(source.rawValue)  // rawValue is "claude"/"codex"
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(source.brandColor)
                .lineLimit(1)
                .fixedSize()
        }
    }
}


/// Expanded card: finished / error / interrupted / awaiting confirmation.
/// φ golden-ratio vertical layout: icon + source label on top, text centered below; an "open
/// session" button at the bottom when the session can be reached.
struct ExpandedCardView: View {
    let card: IslandState.Card
    let queuedCount: Int
    var scale: CGFloat = 1
    /// "Open session" button; nil = no button (IslandViewModel sizes the card from the same value)
    var jump: SessionJumpOption? = nil
    var onJump: () -> Void = {}

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

            // Source marker: logo + claude/codex (notices have no source)
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

            if let jump {
                OpenSessionButton(option: jump, scale: scale, action: onJump)
                    // The VStack already adds 7; top up to actionGap
                    .padding(.top, (IslandGeometry.ExpandedCard.actionGap - 7) * scale)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
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
        case .question(let question): return question.source
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
        case .question:
            return "questionmark.bubble.fill"  // rendered by QuestionCardView; here only for exhaustiveness
        case .notice:
            return "heart.fill"  // Never reached (notices render an emoji); fallback
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
        case .question: return .cyan
        case .notice: return .pink
        }
    }

    private var headline: String {
        switch card {
        case .finished(let task):
            let verb: String
            switch task.outcome {
            case .success: verb = L10n.text("Task completed", zhHans: "任务完成")
            case .error: verb = L10n.text("Task failed", zhHans: "任务出错")
            case .interrupted: verb = L10n.text("Task interrupted", zhHans: "任务中断")
            }
            if let duration = task.duration {
                return L10n.format("%@ · Duration %@", zhHans: "%@ · 耗时 %@", String(verb), String(formatDuration(duration)))
            }
            return verb
        case .waiting(let task):
            if case .waiting(let reason, _) = task.phase { return reason.displayName }
            return L10n.text("Waiting", zhHans: "等待中")
        case .alert(let alert):
            return L10n.format("High-risk operation · %@", zhHans: "高危操作 · %@", String(alert.ruleTitle))
        case .question:
            return L10n.text("Waiting for your answer", zhHans: "等你回答")
        case .notice(let notice):
            return notice.headline
        }
    }

    private var title: String? {
        switch card {
        case .finished(let task): return task.title ?? task.projectName
        case .waiting(let task):
            // While awaiting permission, what matters most is "what is being requested" (the tool +
            // target from PreToolUse); session identity goes to the subtitle's project + #session
            // id -- same convention as the high-risk operation card. With no target string
            // (PreToolUse hook not installed / tool has no args) fall back to the session name,
            // never empty.
            if case .waiting(.permission, _) = task.phase, let tool = task.currentActivity {
                return task.currentToolDetail.map { L10n.format("%@: %@", zhHans: "%@：%@", String(tool), String($0)) } ?? tool
            }
            return taskDisplayName(task)
        case .alert(let alert):
            let firstLine = alert.detail.split(separator: "\n", maxSplits: 1).first.map(String.init)
                ?? alert.detail
            return L10n.format("%@: %@", zhHans: "%@：%@", String(alert.tool), String(firstLine))
        case .question(let question): return question.questions.first?.question
        case .notice(let notice): return notice.body
        }
    }

    private var subtitle: String {
        // The source is already shown by SourceLabelBadge; the subtitle only carries project /
        // session id / queue count
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
            var parts = [L10n.text("View on the Audit page", zhHans: "到「审计」页查看")]
            parts.append("#\(alert.sessionId.prefix(6))")
            if queuedCount > 0 { parts.append(L10n.format("%@ more", zhHans: "还有 %@ 条", String(queuedCount))) }
            return parts.joined(separator: " · ")
        case .notice:
            var parts = [L10n.text("lulu-lumei-dock wellness tip", zhHans: "lulu-lumei-dock 健康提示")]
            if queuedCount > 0 { parts.append(L10n.format("%@ more notifications", zhHans: "还有 %@ 条通知", String(queuedCount))) }
            return parts.joined(separator: " · ")
        case .question(let question):
            project = question.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            sessionId = question.sessionId ?? question.id
        }
        var parts: [String] = []
        if let project { parts.append(project) }
        parts.append("#\(sessionId.prefix(6))")  // Tells sessions apart when several share a project
        if queuedCount > 0 { parts.append(L10n.format("%@ more notifications", zhHans: "还有 %@ 条通知", String(queuedCount))) }
        return parts.joined(separator: " · ")
    }
}

/// "Open session" capsule at the bottom of a card: target app icon + action + outbound arrow.
///
/// Follows the button language of the expanded Dynamic Island on iOS: neutral translucent white
/// fill, no stroke, semibold label, shrinks and dims while pressed. The icon is the target app's
/// own icon, so where the click goes reads at a glance.
/// The inner Button consumes the click, so it never triggers the card's tap-to-dismiss.
struct OpenSessionButton: View {
    let option: SessionJumpOption
    var scale: CGFloat = 1
    let action: () -> Void

    private typealias M = IslandGeometry.ExpandedCard

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6 * scale) {
                if let appURL = option.appURL {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18 * scale, height: 18 * scale)
                }
                Text(option.title)
                    .font(.system(size: 12.5 * scale, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 9.5 * scale, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            // The icon sits in the capsule's round end: less leading than trailing padding keeps
            // it concentric with the arc
            .padding(.leading, (option.appURL == nil ? 14 : 7) * scale)
            .padding(.trailing, 13 * scale)
            .frame(height: M.actionHeight * scale)
            .background(Capsule().fill(Color.white.opacity(0.14)))
            .contentShape(Capsule())
        }
        .buttonStyle(IslandPressButtonStyle())
        .help(option.title)
    }
}

/// Press feedback for island buttons: shrink and dim while pressed, spring back on release (the
/// same feel as system buttons)
struct IslandPressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Task identity: title → project name → short session id, so the session is always recognizable
func taskDisplayName(_ task: AgentTask) -> String {
    task.title ?? task.projectName ?? L10n.format("Session %@", zhHans: "会话 %@", String(task.sessionId.prefix(8)))
}

/// In-progress task list shown when the capsule is clicked (including the idle-session group)
struct TaskListCardView: View {
    let tasks: [AgentTask]
    var idleTasks: [AgentTask] = []
    var showStartTime = false
    var scale: CGFloat = 1
    /// Physical notch width: the title row is split across both sides of the notch (0 when floating
    /// / no notch)
    var centerGap: CGFloat = 0
    /// Id of the task whose subagent box is currently expanded (nil = all collapsed)
    var expandedTaskId: String? = nil
    var onToggleTimeMode: () -> Void = {}
    var onToggleSubagents: (String) -> Void = { _ in }
    /// Trailing "open session" badge, same targets as the card button; nil = no badge on that row
    var jumpOption: (AgentTask) -> SessionJumpOption? = { _ in nil }
    var onJump: (SessionJumpOption) -> Void = { _ in }

    /// Row heights/spacing shared with `IslandGeometry.taskListHeight`
    private typealias M = IslandGeometry.TaskList

    // Palette (design mock agent-dock-final)
    private static let accent = Color(red: 0.353, green: 0.784, blue: 0.980)        // #5AC8FA running
    private static let labelGray = Color(red: 0.557, green: 0.557, blue: 0.576)     // #8E8E93 section header
    private static let primaryText = Color(red: 0.961, green: 0.961, blue: 0.969)   // #F5F5F7
    private static let secondaryText = Color(red: 0.596, green: 0.596, blue: 0.616) // #98989D timer
    private static let sourceText = Color(red: 0.780, green: 0.780, blue: 0.800)    // #C7C7CC
    private static let idleText = Color(red: 0.820, green: 0.820, blue: 0.839)      // #D1D1D6
    private static let idleSourceText = Color(red: 0.682, green: 0.682, blue: 0.698) // #AEAEB2
    private static let idleDot = Color(red: 0.282, green: 0.282, blue: 0.298)       // #48484C
    private static let contextOrange = Color(red: 1.0, green: 0.624, blue: 0.039)   // #FF9F0A

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: M.headerHeight * scale)
                .padding(.top, M.topPadding * scale)
                .padding(.bottom, M.headerGap * scale)

            VStack(spacing: M.activeRowSpacing * scale) {
                ForEach(tasks.prefix(M.maxActiveRows)) { task in
                    VStack(spacing: M.subagentBoxGap * scale) {
                        activeRow(task)
                        if expandedTaskId == task.id, !task.subagents.isEmpty {
                            subagentBox(task)
                        }
                    }
                }
            }
            if tasks.count > M.maxActiveRows {
                Text(L10n.format("…%@ total", zhHans: "…等 %@ 个", "\(tasks.count)"))
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(Self.labelGray)
                    .padding(.leading, 16 * scale)
                    .frame(height: M.overflowLineHeight * scale)
            }

            if IslandGeometry.taskListShowsIdle(
                idleCount: idleTasks.count, expandedSubagentCount: expandedSubagentCount) {
                if !tasks.isEmpty {
                    Rectangle()
                        .fill(Color.white.opacity(0.07))
                        .frame(height: 1)
                        .padding(.horizontal, 4 * scale)
                        .frame(height: M.dividerHeight * scale)
                }
                idleHeader
                ForEach(idleTasks.prefix(M.maxIdleRows)) { task in
                    idleRow(task)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12 * scale)
        .padding(.bottom, M.bottomPadding * scale)
    }

    /// Same rule as IslandViewModel.expandedSubagentCount: the expanded task must be in the visible
    /// rows
    private var expandedSubagentCount: Int {
        guard let id = expandedTaskId else { return 0 }
        return tasks.prefix(M.maxActiveRows).first { $0.id == id }?.subagents.count ?? 0
    }

    // MARK: Title row

    /// On notched screens the title row sits on both sides of the notch (content flush to the
    /// screen top), leaving the notch width in the middle; when the wings don't fit, ViewThatFits
    /// shortens the text first, never letting text slide behind the notch
    private var header: some View {
        HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                headerTitle(L10n.text("Running tasks", zhHans: "进行中任务"))
                headerTitle(L10n.text("In progress", zhHans: "进行中"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if centerGap > 0 {
                Color.clear.frame(width: centerGap, height: 1)
            }

            ViewThatFits(in: .horizontal) {
                timeModeToggle(showLabel: true, showChevron: true)
                timeModeToggle(showLabel: true, showChevron: false)
                timeModeToggle(showLabel: false, showChevron: true)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4 * scale)
    }

    private func headerTitle(_ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8 * scale) {
            Text(label)
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Self.labelGray)
                .fixedSize()
            Text("\(tasks.count)")
                .font(.system(size: 22 * scale, weight: .bold).monospacedDigit())
                .foregroundStyle(Self.primaryText)
                .fixedSize()
        }
    }

    /// Toggle the right-side time display: elapsed duration ↔ start time (the inner button consumes
    /// the click, so the island doesn't collapse)
    private func timeModeToggle(showLabel: Bool, showChevron: Bool) -> some View {
        Button(action: onToggleTimeMode) {
            HStack(spacing: 5 * scale) {
                Image(systemName: showStartTime ? "calendar" : "stopwatch")
                    .font(.system(size: 12 * scale))
                if showLabel {
                    Text(showStartTime ? L10n.text("Start time", zhHans: "开始时间") : L10n.text("Duration", zhHans: "耗时"))
                        .font(.system(size: 12 * scale))
                }
                if showChevron {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8 * scale, weight: .semibold))
                        .foregroundStyle(Self.secondaryText.opacity(0.7))
                }
            }
            .foregroundStyle(Self.secondaryText)
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(showStartTime
            ? L10n.text("Show elapsed time instead", zhHans: "改为显示耗时")
            : L10n.text("Show start time instead", zhHans: "改为显示开始时间"))
    }

    // MARK: Running rows

    /// Running row: light fill + glowing left bar + status dot; a waiting task turns the whole row
    /// orange
    private func activeRow(_ task: AgentTask) -> some View {
        let tint = rowTint(task)
        let shape = RoundedRectangle(cornerRadius: 10 * scale, style: .continuous)
        return HStack(spacing: 10 * scale) {
            statusMark(task, tint: tint)
            sourceLabel(task.source, textColor: Self.sourceText, weight: .medium)
            VStack(alignment: .leading, spacing: 1 * scale) {
                Text(taskDisplayName(task))
                    .font(.system(size: 13 * scale))
                    .foregroundStyle(Self.primaryText)
                    .lineLimit(1)
                activityLine(task)
            }
            Spacer(minLength: 6 * scale)
            // Open the session: desktop-app sessions open directly, terminal / IDE sessions switch
            // to the host app (hidden when there is nowhere to go)
            if let jump = jumpOption(task) {
                jumpBadge(jump)
            }
            // Subagent count badge (click to expand/collapse; hidden with no subagents)
            if !task.subagents.isEmpty {
                subagentBadge(task)
            }
            if let context = task.contextUsedPercent, context >= 60 {
                contextBadge(context)
            }
            // The trailing part must be fixedSize: otherwise the title in the middle pushes it onto
            // a new line (the Plans row hit the same pitfall -- fix the trailing part and let the
            // middle give way)
            Group {
                if showStartTime {
                    Text(formatStartTime(task.sessionStartedAt ?? task.startedAt))
                } else {
                    Text(timerInterval: task.startedAt...Date.distantFuture, countsDown: false)
                }
            }
            .font(.system(size: 12 * scale).monospacedDigit())
            .foregroundStyle(Self.secondaryText)
            .fixedSize()
        }
        .padding(.leading, 14 * scale)
        .padding(.trailing, 12 * scale)
        .frame(height: M.activeRowHeight * scale)
        .background(shape.fill(tint.opacity(0.08)))
        .overlay(alignment: .leading) {
            Capsule()
                .fill(tint)
                .frame(width: 3 * scale)
                .padding(.vertical, 8 * scale)
                .shadow(color: tint.opacity(0.9), radius: 5 * scale)
        }
        .clipShape(shape)
    }

    private func rowTint(_ task: AgentTask) -> Color {
        if case .waiting = task.phase { return .orange }
        return Self.accent
    }

    /// Status marker: a haloed dot when running, an orange exclamation mark when awaiting
    /// confirmation (same width, title column aligned)
    @ViewBuilder
    private func statusMark(_ task: AgentTask, tint: Color) -> some View {
        Group {
            if case .waiting = task.phase {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(tint)
            } else {
                Circle()
                    .fill(tint)
                    .frame(width: 9 * scale, height: 9 * scale)
                    .background(
                        Circle()
                            .fill(tint.opacity(0.18))
                            .frame(width: 15 * scale, height: 15 * scale))
            }
        }
        .frame(width: 15 * scale)
    }

    /// Second line under the title: compacting context / current tool (takes no line if neither,
    /// title vertically centered)
    @ViewBuilder
    private func activityLine(_ task: AgentTask) -> some View {
        if task.isCompacting {
            // No other events arrive while compacting; without a marker it would look frozen
            Text(L10n.text("Compacting context", zhHans: "压缩上下文"))
                .font(.system(size: 10 * scale))
                .foregroundStyle(Theme.gold.opacity(0.85))
                .lineLimit(1)
        } else if let activity = task.currentActivity {
            // Show the target too when there is one: "Edit main.swift" is far more useful than just
            // "Edit"
            Text(compactToolLabel(tool: activity, detail: task.currentToolDetail))
                .font(.system(size: 10 * scale).monospaced())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    // MARK: Idle section

    private var idleHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7 * scale) {
            Text(L10n.text("Idle sessions", zhHans: "空闲会话"))
                .font(.system(size: 11 * scale, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Self.labelGray)
            Text("\(idleTasks.count)")
                .font(.system(size: 13 * scale, weight: .semibold).monospacedDigit())
                .foregroundStyle(Self.idleSourceText)
        }
        .padding(.horizontal, 4 * scale)
        .frame(height: M.idleHeaderHeight * scale)
    }

    private func idleRow(_ task: AgentTask) -> some View {
        HStack(spacing: 10 * scale) {
            Circle()
                .fill(Self.idleDot)
                .frame(width: 9 * scale, height: 9 * scale)
                .frame(width: 15 * scale)
            sourceLabel(task.source, textColor: Self.idleSourceText, weight: .regular)
            Text(taskDisplayName(task))
                .font(.system(size: 13 * scale))
                .foregroundStyle(Self.idleText)
                .lineLimit(1)
            Spacer(minLength: 6 * scale)
            if let context = task.contextUsedPercent, context >= 60 {
                contextBadge(context)
            }
            Text(relativeFormatter.localizedString(for: task.lastActivityAt, relativeTo: Date()))
                .font(.system(size: 12 * scale).monospacedDigit())
                .foregroundStyle(Self.labelGray)
                .fixedSize()
        }
        .padding(.leading, 14 * scale)
        .padding(.trailing, 12 * scale)
        .frame(height: M.idleRowHeight * scale)
    }

    // MARK: Inline parts

    /// Source: brand-color logo + gray lowercase source name
    private func sourceLabel(
        _ source: AgentSource, textColor: Color, weight: Font.Weight
    ) -> some View {
        HStack(spacing: 5 * scale) {
            SourceBadge(source: source, size: 14 * scale, onDark: true)
            Text(source.rawValue)
                .font(.system(size: 12 * scale, weight: weight))
                .foregroundStyle(textColor)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// Context usage badge (appears only at ≥60%): orange from 80%
    private func contextBadge(_ percent: Double) -> some View {
        let color = contextColor(percent)
        return Text("ctx \(Int(percent.rounded()))%")
            .font(.system(size: 10 * scale, weight: .semibold).monospacedDigit())
            .foregroundStyle(color)
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, 2 * scale)
            .background(RoundedRectangle(cornerRadius: 5 * scale).fill(color.opacity(0.16)))
            .fixedSize()
    }

    /// Trailing jump badge (inner button consumes the click, so the island doesn't
    /// expand/collapse). Terminals are only activated, the tab is not selected -- see
    /// TerminalActivator for the trade-off.
    private func jumpBadge(_ option: SessionJumpOption) -> some View {
        Button(action: { onJump(option) }) {
            Image(systemName: "arrow.up.forward.app")
                .font(.system(size: 9.5 * scale, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 5 * scale)
                .padding(.vertical, 2 * scale)
                .background(Capsule().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(.plain)
        .help(option.title)
    }

    /// Trailing subagent badge: chevron + count, click to expand/collapse (inner button consumes
    /// the click)
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

    /// Expanded nested subagent box: each row is type + description + status dot + current tool
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
                Text(L10n.format("…%@ subagents total", zhHans: "…等 %@ 个子 agent", String(task.subagents.count)))
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

    /// In the list, orange from 80%; red is reserved for the compact pill's right-wing ctx ≥ 90%
    /// alert
    private func contextColor(_ percent: Double) -> Color {
        percent < 80 ? Self.secondaryText : Self.contextOrange
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

/// Task start date-time: time only for today, with the date across days
func formatStartTime(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? startTimeTodayFormatter.string(from: date)
        : startTimeFullFormatter.string(from: date)
}

func formatDuration(_ seconds: TimeInterval) -> String {
    let total = Int(seconds.rounded())
    if total < 60 { return L10n.format("%@ sec", zhHans: "%@ 秒", String(total)) }
    if total < 3600 {
        let m = total / 60, s = total % 60
        return s == 0 ? L10n.format("%@ min", zhHans: "%@ 分钟", String(m)) : L10n.format("%@ min %@ sec", zhHans: "%@ 分 %@ 秒", String(m), String(s))
    }
    let h = total / 3600, m = (total % 3600) / 60
    return m == 0 ? L10n.format("%@ hr", zhHans: "%@ 小时", String(h)) : L10n.format("%@ hr %@ min", zhHans: "%@ 小时 %@ 分", String(h), String(m))
}


