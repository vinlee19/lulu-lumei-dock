import EurekaKit
import SwiftUI

/// 提问卡：agent 的选择题（AskUserQuestion），在岛上点选作答。
///
/// - 单选题点一下选项就记下答案；多选题勾选后点「确定」；
/// - 「其他…」展开成输入框（这时岛临时接管键盘，回车发送）；
/// - 多个问题逐个回答，全部答完才交给 hook，agent 随即继续；
/// - Claude 自己的确认界面（终端选择框 / 桌面端确认卡）同时开着，哪边先答用哪边；
///   「在 Claude 里回答」只收起岛上这张卡。
///
/// 行高与间距来自 `IslandGeometry.QuestionCard`，卡片高度按同一组值算。
struct QuestionCardView: View {
    let draft: QuestionDraft
    /// 哪个会话在问（会话标题 / 项目名）
    var sessionLabel: String?
    var scale: CGFloat = 1
    /// 让开刘海的高度（1.0× 基准；不与刘海融合时 0）
    var topInset: CGFloat = 0
    /// 问题原文排出来的行数（IslandViewModel.questionLines 测量），问题区按它定高
    var questionLines = 1
    var onChoose: (String) -> Void = { _ in }
    var onToggle: (String) -> Void = { _ in }
    var onConfirm: () -> Void = {}
    var onBeginOther: () -> Void = {}
    var onCancelOther: () -> Void = {}
    var onSubmitOther: (String) -> Void = { _ in }
    var onDismiss: () -> Void = {}

    @State private var otherText = ""
    @FocusState private var otherFocused: Bool

    private typealias M = IslandGeometry.QuestionCard
    /// 左右内边距（1.0× 基准）；IslandViewModel 量问题行数时按同一宽度
    static let horizontalPadding: CGFloat = 14
    private static let accent = Color(red: 0.353, green: 0.784, blue: 0.980)  // #5AC8FA
    private static let secondaryText = Color(red: 0.596, green: 0.596, blue: 0.616)  // #98989D

    private var question: AskQuestion { draft.current }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: M.headerHeight * scale)
            Spacer().frame(height: M.sectionGap * scale)
            Text(question.question)
                .font(.system(size: 14 * scale, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(questionLines)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(
                    height: IslandGeometry.questionTextHeight(lines: questionLines) * scale,
                    alignment: .leading)
            Spacer().frame(height: M.sectionGap * scale)
            VStack(spacing: M.optionSpacing * scale) {
                ForEach(Array(question.options.prefix(M.maxOptions).enumerated()), id: \.offset) {
                    _, option in
                    optionRow(option)
                }
            }
            Spacer().frame(height: M.optionSpacing * scale)
            otherRow
                .frame(height: M.otherRowHeight * scale)
            Spacer().frame(height: M.sectionGap * scale)
            footer
                .frame(height: M.footerHeight * scale)
            Spacer(minLength: 0)
        }
        .padding(.top, max(topInset + 6, M.plainTopPadding) * scale)
        .padding(.bottom, M.bottomPadding * scale)
        .padding(.horizontal, Self.horizontalPadding * scale)
        .onChange(of: draft.index) { _, _ in otherText = "" }
    }

    // MARK: 标题行

    private var header: some View {
        HStack(spacing: 7 * scale) {
            Image(systemName: "questionmark.bubble.fill")
                .font(.system(size: 12 * scale, weight: .semibold))
                .foregroundStyle(Self.accent)
            SourceBadge(source: draft.question.source, size: 13 * scale, onDark: true)
            if !question.header.isEmpty {
                Text(question.header)
                    .font(.system(size: 10.5 * scale, weight: .semibold))
                    .foregroundStyle(Self.accent)
                    .padding(.horizontal, 6 * scale)
                    .padding(.vertical, 1.5 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: 5 * scale).fill(Self.accent.opacity(0.14)))
                    .lineLimit(1)
                    .fixedSize()
            }
            if let sessionLabel {
                Text(sessionLabel)
                    .font(.system(size: 11 * scale))
                    .foregroundStyle(Self.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4 * scale)
            if draft.progress.total > 1 {
                Text("\(draft.progress.current)/\(draft.progress.total)")
                    .font(.system(size: 11 * scale, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Self.secondaryText)
                    .fixedSize()
            }
        }
    }

    // MARK: 选项

    private func optionRow(_ option: AskOption) -> some View {
        let isSelected = question.multiSelect && draft.selected.contains(option.label)
        return Button {
            if question.multiSelect {
                onToggle(option.label)
            } else {
                onChoose(option.label)
            }
        } label: {
            HStack(spacing: 10 * scale) {
                Image(systemName: indicator(selected: isSelected))
                    .font(.system(size: 13 * scale, weight: .medium))
                    .foregroundStyle(isSelected ? Self.accent : .white.opacity(0.45))
                VStack(alignment: .leading, spacing: 1 * scale) {
                    Text(option.label)
                        .font(.system(size: 13 * scale, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if !option.description.isEmpty {
                        Text(option.description)
                            .font(.system(size: 10.5 * scale))
                            .foregroundStyle(Self.secondaryText)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10 * scale)
            .frame(height: M.optionHeight * scale)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(isSelected ? Self.accent.opacity(0.2) : Color.white.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .stroke(isSelected ? Self.accent.opacity(0.7) : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(option.description.isEmpty ? option.label : option.description)
    }

    private func indicator(selected: Bool) -> String {
        if question.multiSelect {
            return selected ? "checkmark.square.fill" : "square"
        }
        return "circle"
    }

    // MARK: 其他（自由输入）

    @ViewBuilder
    private var otherRow: some View {
        if draft.isTypingOther {
            HStack(spacing: 8 * scale) {
                TextField("输入你的回答，回车发送", text: $otherText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5 * scale))
                    .foregroundStyle(.white)
                    .focused($otherFocused)
                    .onSubmit { onSubmitOther(otherText) }
                Button {
                    onSubmitOther(otherText)
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 16 * scale))
                        .foregroundStyle(
                            otherText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? .white.opacity(0.25) : Self.accent)
                }
                .buttonStyle(.plain)
                Button(action: onCancelOther) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10 * scale, weight: .bold))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help("取消输入")
            }
            .padding(.horizontal, 10 * scale)
            .frame(maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .fill(Color.white.opacity(0.07)))
            .overlay(
                RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                    .stroke(Self.accent.opacity(0.6), lineWidth: 1))
            .onAppear {
                // panel 刚成为 key window，下一轮 runloop 再给焦点才接得住
                DispatchQueue.main.async { otherFocused = true }
            }
        } else {
            Button(action: onBeginOther) {
                HStack(spacing: 8 * scale) {
                    Image(systemName: "pencil")
                        .font(.system(size: 11 * scale, weight: .medium))
                    Text(question.multiSelect ? "其他…（与已勾选的一起提交）" : "其他…")
                        .font(.system(size: 12 * scale))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Self.secondaryText)
                .padding(.horizontal, 10 * scale)
                .frame(maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 9 * scale, style: .continuous)
                        .stroke(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: 底部按钮

    private var footer: some View {
        HStack(spacing: 8 * scale) {
            Button(action: onDismiss) {
                Text("在 Claude 里回答")
                    .font(.system(size: 11.5 * scale, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 10 * scale)
                    .frame(maxHeight: .infinity)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("收起这张卡，到 Claude 的确认框里回答")
            Spacer(minLength: 0)
            if question.multiSelect {
                let count = draft.selected.count
                Button(action: onConfirm) {
                    Text(count > 0 ? "确定（\(count)）" : "确定")
                        .font(.system(size: 11.5 * scale, weight: .semibold))
                        .foregroundStyle(count > 0 ? Color.black : .white.opacity(0.35))
                        .padding(.horizontal, 14 * scale)
                        .frame(maxHeight: .infinity)
                        .background(
                            Capsule().fill(count > 0 ? Self.accent : Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .disabled(count == 0)
            }
        }
    }
}
