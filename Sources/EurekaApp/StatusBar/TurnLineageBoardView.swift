import EurekaKit
import SwiftUI

/// 一轮的血缘图「板」：诊断条 + 画布 + 图例 + 选中节点详情。
///
/// 独立成一个固定尺寸、无 ScrollView / 无 Lazy 容器的视图，是为了**离屏渲染风险最低** ——
/// `PreviewRenderer.renderLineage` 直接 snap 它，拿到可复现的验收基准图。
/// 外层页面（`TurnLineageView`）再给它套滚动与页头。
struct TurnLineageBoardView: View {
    let result: TurnGraphLayout.Result
    let diagnostics: TurnDiagnostics
    /// 本轮拿不拿得到思考明文（拿不到要明说原因，别让用户以为它没思考）
    var hasThinking: Bool = false
    var onJumpToMessage: ((Int) -> Void)?
    var onToggleSubagent: ((TurnGraph.Node) -> Void)?
    var onToggleFold: ((TurnGraph.NodeID) -> Void)?

    @State private var selected: TurnGraph.NodeID?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            diagnosticsStrip
            if let degraded = result.degraded {
                degradedNotice(degraded)
            } else {
                TurnGraphCanvasView(
                    result: result, selected: $selected,
                    onJumpToMessage: onJumpToMessage, onToggleFold: onToggleFold,
                    onToggleSubagent: onToggleSubagent)
                legend
            }
            if let node = selected.flatMap({ id in result.nodes.first { $0.id == id } }) {
                detailBar(node)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 诊断条（图上面那一行「这一轮出了什么问题」）

    private var diagnosticsStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.format("Turn %@", zhHans: "第 %@ 轮", String(diagnostics.turnIndex + 1)))
                    .font(.system(size: 12, weight: .semibold))
                statChip(L10n.format("%@ steps", zhHans: "%@ 步", String(diagnostics.stepCount)))
                statChip(L10n.format("%@ nodes", zhHans: "%@ 节点", String(result.nodes.count)))
                if diagnostics.rereadCount > 0 {
                    statChip(L10n.format("Reread %@", zhHans: "回读 %@", String(diagnostics.rereadCount)), tint: Theme.brandFg)
                }
                if diagnostics.retryMax > 0 {
                    statChip(L10n.format("Retry %@", zhHans: "重试 %@", String(diagnostics.retryMax)), tint: Theme.failureRed)
                }
                if diagnostics.reworkCount > 0 {
                    statChip(L10n.format("Rework %@", zhHans: "返工 %@", String(diagnostics.reworkCount)), tint: Theme.goldFg)
                }
                Spacer(minLength: 0)
                if !hasThinking {
                    // 说清「为什么没有思考」，否则用户会以为是我们没抓到
                    Text(L10n.text("Thinking text was stripped by this CLI", zhHans: "思考明文被该 CLI 剥离"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .help(L10n.text(
                            "Claude strips the thinking text when it writes the transcript and keeps only an encrypted signature. Codex / Kimi / Qwen keep the text, and it shows up here as a thinking node.",
                            zhHans: "Claude 落盘时会把 thinking 正文剥掉、只留加密签名；Codex / Kimi / Qwen 有明文，会直接显示为思考节点。"))
                }
            }
            ForEach(diagnostics.signals) { signal in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(severityColor(signal.severity))
                        .frame(width: 6, height: 6)
                        .padding(.top, 4)
                    Text(signal.title)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(severityColor(signal.severity))
                        .fixedSize()
                    // 这句才是用户要的：告诉他下次提示词怎么写
                    Text(signal.advice)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChip(_ text: String, tint: Color = .secondary) -> some View {
        Text(text)
            .font(.system(size: 9.5).monospacedDigit())
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }

    private func severityColor(_ severity: TurnDiagnostics.Severity) -> Color {
        switch severity {
        case .clean: return Theme.enabledGreen
        case .notice: return Theme.goldFg
        case .bad: return Theme.failureRed
        }
    }

    // MARK: - 图例（不解释就看不懂虚线在说什么）

    private var legend: some View {
        FlowLayout(spacing: 12, lineSpacing: 5) {
            legendItem(L10n.text("Progress", zhHans: "推进"), color: Theme.brandFg.opacity(0.45), dashed: false)
            legendItem(L10n.text("Reread the same place", zhHans: "回读同一处"), color: Theme.brandFg.opacity(0.7), dashed: true)
            legendItem(L10n.text("Failed retry", zhHans: "失败重试"), color: Theme.failureRed.opacity(0.85), dashed: true)
            legendItem(L10n.text("Read again after an edit", zhHans: "改完回看"), color: Theme.goldFg, dashed: true)
            legendItem(L10n.text("Spawn a subagent", zhHans: "派生子代理"), color: Theme.brandFg.opacity(0.6), dashed: false)
        }
    }

    private func legendItem(_ text: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            Rectangle()
                .fill(color)
                .frame(width: dashed ? 5 : 14, height: 1.5)
                .overlay(alignment: .leading) {
                    if dashed {
                        HStack(spacing: 3) {
                            Rectangle().fill(color).frame(width: 5, height: 1.5)
                            Rectangle().fill(color).frame(width: 5, height: 1.5)
                        }
                        .offset(x: 9)
                    }
                }
                .frame(width: 20, alignment: .leading)
            Text(text).font(.system(size: 9.5)).foregroundStyle(.tertiary)
        }
        .fixedSize()
    }

    // MARK: - 选中节点详情（内联条，不用 popover：popover 离屏渲不出来）

    private func detailBar(_ placed: TurnGraphLayout.PlacedNode) -> some View {
        let node = placed.node
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "chevron.right.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.brandFg)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.title).font(Theme.font.monoSkillName(11.5, weight: .semibold))
                    if node.occurrences > 1 {
                        TagChip(L10n.format("Seen %@ times", zhHans: "出现 %@ 次", String(node.occurrences)), tint: Theme.goldFg)
                    }
                    if node.isError { TagChip(L10n.text("Has failures", zhHans: "有失败"), tint: Theme.failureRed) }
                    Spacer(minLength: 0)
                    if let messageId = node.messageId, let onJumpToMessage {
                        Button(L10n.text("Jump to message", zhHans: "跳到消息")) { onJumpToMessage(messageId) }
                            .font(.system(size: 10))
                            .buttonStyle(.borderless)
                    }
                }
                if !node.subtitle.isEmpty {
                    Text(node.subtitle)
                        .font(.system(size: 10.5).monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // 多行必须锁固有高度，否则会被压回一行
                        .fixedSize(horizontal: false, vertical: true)
                }
                if node.stepIndices.count > 1 {
                    Text(L10n.format(
                        "Steps %@",
                        zhHans: "对应第 %@ 步",
                        node.stepIndices.map { String($0 + 1) }.joined(separator: L10n.text(", ", zhHans: "、"))))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.surfaceSecondary))
    }

    // MARK: - 降级

    private func degradedNotice(_ degraded: TurnGraphLayout.Degradation) -> some View {
        let text: String
        switch degraded {
        case .tooManyNodes(let count, let limit):
            text = L10n.format(
                "This turn has %@ different actions (limit %@), too many to draw clearly. The diagnostics above still apply; step-by-step detail is in This turn's trail on the session page.",
                zhHans: "这一轮有 %@ 个不同操作（上限 %@），画成图反而看不清。上面的诊断数字仍然有效；逐步明细见会话页的「本轮轨迹」。",
                String(count), String(limit))
        case .tooWide(let width, let columns):
            text = L10n.format(
                "One layer has %@ parallel actions, more than the %@ columns this window can fit. Widen the window, or switch to Compact density.",
                zhHans: "某一层有 %@ 个并行操作，超过当前窗口能放下的 %@ 列。把窗口拉宽，或用「紧凑」密度。",
                String(width), String(columns))
        }
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 12))
                .foregroundStyle(Theme.goldFg)
            Text(text)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.gold.opacity(0.10)))
    }
}
