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
                Text("第 \(diagnostics.turnIndex + 1) 轮")
                    .font(.system(size: 12, weight: .semibold))
                statChip("\(diagnostics.stepCount) 步")
                statChip("\(result.nodes.count) 节点")
                if diagnostics.rereadCount > 0 {
                    statChip("回读 \(diagnostics.rereadCount)", tint: Theme.brandFg)
                }
                if diagnostics.retryMax > 0 {
                    statChip("重试 \(diagnostics.retryMax)", tint: Theme.failureRed)
                }
                if diagnostics.reworkCount > 0 {
                    statChip("返工 \(diagnostics.reworkCount)", tint: Theme.goldFg)
                }
                Spacer(minLength: 0)
                if !hasThinking {
                    // 说清「为什么没有思考」，否则用户会以为是我们没抓到
                    Text("思考明文被该 CLI 剥离")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .help("Claude 落盘时会把 thinking 正文剥掉、只留加密签名；"
                            + "Codex / Kimi / Qwen 有明文，会直接显示为思考节点。")
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
            legendItem("推进", color: Theme.brandFg.opacity(0.45), dashed: false)
            legendItem("回读同一处", color: Theme.brandFg.opacity(0.7), dashed: true)
            legendItem("失败重试", color: Theme.failureRed.opacity(0.85), dashed: true)
            legendItem("改完回看", color: Theme.goldFg, dashed: true)
            legendItem("派生子代理", color: Theme.brandFg.opacity(0.6), dashed: false)
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
                        TagChip("出现 \(node.occurrences) 次", tint: Theme.goldFg)
                    }
                    if node.isError { TagChip("有失败", tint: Theme.failureRed) }
                    Spacer(minLength: 0)
                    if let messageId = node.messageId, let onJumpToMessage {
                        Button("跳到消息") { onJumpToMessage(messageId) }
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
                    Text("对应第 \(node.stepIndices.map { String($0 + 1) }.joined(separator: "、")) 步")
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
            text = "这一轮有 \(count) 个不同操作（上限 \(limit)），画成图反而看不清。"
                + "上面的诊断数字仍然有效；逐步明细见会话页的「本轮轨迹」。"
        case .tooWide(let width, let columns):
            text = "某一层有 \(width) 个并行操作，超过当前窗口能放下的 \(columns) 列。"
                + "把窗口拉宽，或用「紧凑」密度。"
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
