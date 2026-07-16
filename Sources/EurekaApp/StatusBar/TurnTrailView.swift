import EurekaIngest
import SwiftUI

/// 一轮工具/检索轨迹行：默认折叠一行摘要（步数 + 分类速览），点击展开逐步列表。
/// 思考明文本地不可得（Claude 落盘剥离、Codex 新版加密），轨迹即"这一轮做了什么"的可视化。
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
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text("本轮轨迹（\(message.steps.count) 步）")
                        .font(.system(size: 9.5, weight: .medium))
                    Text(kindSummary)
                        .font(.system(size: 9))
                        .foregroundStyle(.purple.opacity(0.55))
                        .lineLimit(1)
                    if errorCount > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "exclamationmark.circle")
                                .font(.system(size: 8.5))
                            Text("\(errorCount) 失败")
                                .font(.system(size: 9))
                        }
                        .foregroundStyle(.red.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.purple.opacity(0.75))

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
                .strokeBorder(isMatch ? Color.yellow.opacity(0.9) : .clear, lineWidth: 1.5))
    }

    private func stepRow(_ step: ToolStep) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Image(systemName: step.kind.icon)
                .font(.system(size: 8.5))
                .frame(width: 12)
                .foregroundStyle(step.isError ? Color.red.opacity(0.8) : .purple.opacity(0.6))
            Text(step.name)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(step.isError ? Color.red.opacity(0.9) : .purple.opacity(0.8))
                .lineLimit(1)
            if !step.detail.isEmpty {
                Text(step.detail)
                    .font(.system(size: 9.5))
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

extension ToolStep.Kind {
    /// SF Symbol 图标（轨迹步骤行用）
    var icon: String {
        switch self {
        case .read: return "doc.text"
        case .search: return "magnifyingglass"
        case .command: return "terminal"
        case .edit: return "pencil"
        case .web: return "globe"
        case .mcp: return "puzzlepiece.extension"
        case .agent: return "person.2"
        case .skill: return "wand.and.stars"
        case .other: return "wrench.adjustable"
        }
    }
}
