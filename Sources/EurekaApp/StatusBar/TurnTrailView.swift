import EurekaIngest
import SwiftUI

/// 一轮工具/检索轨迹行：默认折叠一行摘要（步数 + 分类速览），点击展开逐步列表。
///
/// **思考明文按源分级**（旧注释写的「本地一律不可得」只对 Claude 成立）：
/// Claude 的 `thinking` 块落盘时正文被剥离（只剩加密签名），轨迹是它「这一轮做了什么」的
/// 唯一替代；而 Codex / Kimi / Qwen 有真思考正文，走 `ThinkingRowView`。
struct TurnTrailRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    /// 展开态提升到 SessionDetailView（LazyVStack 回收不丢；切会话时清空）
    @Binding var expandedTrails: Set<Int>

    /// 搜索命中时自动展开（命中内容可能藏在步骤里）
    private var isExpanded: Bool {
        expandedTrails.contains(message.id) || (isMatch && !message.steps.isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) {
                    if expandedTrails.contains(message.id) {
                        expandedTrails.remove(message.id)
                    } else {
                        expandedTrails.insert(message.id)
                    }
                }
            } label: {
                // 金色浅底 pill（设计稿：轨迹折叠条去紫色，与全局强调区分）
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Image(systemName: "wrench.adjustable")
                        .font(.system(size: 8.5))
                    Text("本轮轨迹 · \(message.steps.count) 步")
                        .font(.system(size: 10, weight: .medium))
                    Text(kindSummary)
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.goldFg.opacity(0.75))
                        .lineLimit(1)
                    if errorCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 8.5))
                            Text("\(errorCount) 失败")
                                .font(.system(size: 9.5))
                        }
                        .foregroundStyle(Theme.failureRed)
                    }
                }
                .foregroundStyle(Theme.goldFg)
                .padding(.horizontal, 9)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Theme.gold.opacity(0.15)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 2.5) {
                    ForEach(Array(message.steps.enumerated()), id: \.offset) { _, step in
                        stepRow(step)
                    }
                }
                .padding(.leading, 13)
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isMatch ? Theme.gold.opacity(0.85) : .clear, lineWidth: 1.5))
    }

    private func stepRow(_ step: ToolStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: step.kind.icon)
                .font(.system(size: 8.5))
                .frame(width: 12)
                .foregroundStyle(step.isError ? Color.red.opacity(0.8) : Theme.brandFg.opacity(0.55))
            Text(step.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(step.isError ? Color.red.opacity(0.9) : Theme.brandFg.opacity(0.75))
                .lineLimit(1)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if step.isError {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 8.5))
                    .foregroundStyle(.red.opacity(0.8))
            }
            Spacer(minLength: 0)
        }
    }

    /// 分类速览："读取 5 · 命令 3 · 编辑 2"（按出现顺序，只列非零项）
    private var kindSummary: String {
        var order: [ToolStep.Kind] = []
        var counts: [ToolStep.Kind: Int] = [:]
        for step in message.steps {
            if counts[step.kind] == nil { order.append(step.kind) }
            counts[step.kind, default: 0] += 1
        }
        return order.map { "\($0.label) \(counts[$0]!)" }.joined(separator: " · ")
    }

    private var errorCount: Int {
        message.steps.lazy.filter(\.isError).count
    }
}

// MARK: - 思考正文行

/// 模型思考正文：默认折叠成一行首句预览，点开看全文。
///
/// 只有 Codex（`event_msg/agent_reasoning`）/ Kimi（`part.type == "think"`）/
/// Qwen（`{text, thought:true}`）会产出；Claude 落盘时已剥离，永远不出现。
/// 刻意做成**默认折叠 + 紫色虚线左脊**：思考不是回答，不该和正文抢视觉权重，
/// 但要能一眼认出「这一轮它想过什么」。
struct ThinkingRowView: View {
    let message: TranscriptMessage
    var isMatch = false
    /// 与轨迹共用一个展开集合（同为 `TranscriptMessage.id`，天然不撞号）
    @Binding var expanded: Set<Int>

    /// 搜索命中时自动展开（命中内容可能藏在折叠掉的后半段）
    private var isExpanded: Bool {
        expanded.contains(message.id) || isMatch
    }

    /// 折叠态预览：首句/首行，够看出思路走向即可
    private var preview: String {
        let firstLine = message.text
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? message.text
        return firstLine.count <= 72 ? firstLine : String(firstLine.prefix(72)) + "…"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // 虚线脊：与错误消息的实线红脊区分（那是事实，这是过程）
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.brand.opacity(0.35))
                .frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    withAnimation(.easeInOut(duration: 0.12)) {
                        if expanded.contains(message.id) {
                            expanded.remove(message.id)
                        } else {
                            expanded.insert(message.id)
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text("💭 思考")
                            .font(.system(size: 10, weight: .medium))
                        if !isExpanded {
                            Text(preview)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Theme.brandFg.opacity(0.7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isExpanded {
                    Text(message.text)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // 多行必须锁固有高度，否则会被压回一行（AuditView 踩过）
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.vertical, 3)
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isMatch ? Theme.gold.opacity(0.85) : .clear, lineWidth: 1.5))
    }
}

