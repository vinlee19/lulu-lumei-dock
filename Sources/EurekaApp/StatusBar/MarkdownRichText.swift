import AppKit
import EurekaKit
import SwiftUI

// MARK: - 富文本正文（Markdown 块渲染，会话/记忆/技能/计划共用）

/// Markdown 富文本：块级结构自绘（代码块/标题/列表/引用/分隔线/表格），
/// 行内样式（粗体/行内代码/链接）走 AttributedString(markdown:)。
struct MarkdownRichText: View {
    let blocks: [MarkdownBlock]
    /// false = 宽度紧贴内容（聊天气泡用）；true = 撑满可用宽度（正文/文档页用）
    let fillWidth: Bool

    init(text: String, fillWidth: Bool = true) {
        blocks = MarkdownBlockParser.parse(text)
        self.fillWidth = fillWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: fillWidth ? .infinity : nil, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            if text.hasPrefix("|") {
                // 表格降级：等宽渲染保持列对齐
                Text(text)
                    .font(.system(size: 11.5).monospaced())
                    .textSelection(.enabled)
            } else {
                Text(Self.inline(text))
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        case .heading(let level, let text):
            VStack(alignment: .leading, spacing: 5) {
                Text(Self.inline(text))
                    .font(.system(
                        size: level == 1 ? 17 : (level == 2 ? 15 : 13.5),
                        weight: .semibold))
                    .textSelection(.enabled)
                if level <= 2 {
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
            }
            .padding(.top, level == 1 ? 10 : (level == 2 ? 8 : 6))
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .listItem(let ordered, let index, let text, let indent, let check):
            HStack(alignment: .top, spacing: 6) {
                if let check {
                    Image(systemName: Self.checkIcon(check))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Self.checkColor(check))
                        .padding(.top, 1.5)
                } else {
                    Text(ordered ? "\(index)." : "•")
                        .font(.system(size: 12.5).monospacedDigit())
                        .foregroundStyle(Theme.brand.opacity(0.8))
                }
                Text(Self.inline(text))
                    .font(.system(size: 13))
                    .lineSpacing(2.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(check == .done ? AnyShapeStyle(.secondary)
                                                    : AnyShapeStyle(.primary))
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 14)
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.brand.opacity(0.4))
                    .frame(width: 3)
                Text(Self.inline(text))
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(.primary.opacity(0.8))
                    .textSelection(.enabled)
            }
        case .divider:
            Rectangle().fill(Theme.hairline).frame(height: 1).padding(.vertical, 4)
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
        }
    }

    private static func checkIcon(_ check: MarkdownBlock.TaskCheck) -> String {
        switch check {
        case .todo: return "square"
        case .inProgress: return "square.lefthalf.filled"
        case .done: return "checkmark.square.fill"
        }
    }

    private static func checkColor(_ check: MarkdownBlock.TaskCheck) -> Color {
        switch check {
        case .todo: return .secondary
        case .inProgress: return .orange
        case .done: return .green
        }
    }

    @ViewBuilder
    private func tableView(header: [String], rows: [[String]]) -> some View {
        let columns = max(header.count, rows.map(\.count).max() ?? 0)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                GridRow {
                    ForEach(0..<columns, id: \.self) { col in
                        Text(Self.inline(col < header.count ? header[col] : ""))
                            .font(.system(size: 12, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            Text(Self.inline(col < row.count ? row[col] : ""))
                                .font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    Divider().opacity(0.3)
                }
            }
            .padding(8)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    /// 行内 Markdown（粗体/斜体/行内代码/链接）；解析失败回退纯文本。
    /// 行内代码 → 等宽 + 淡底 chip；链接 → 品牌色下划线。
    static func inline(_ text: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in attributed.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                attributed[run.range].font = .system(size: 12, design: .monospaced)
                attributed[run.range].backgroundColor = Color.primary.opacity(0.07)
            }
            if run.link != nil {
                attributed[run.range].foregroundColor = Theme.brand
                attributed[run.range].underlineStyle = .single
            }
        }
        return attributed
    }
}

/// 围栏代码块：语言标签 + 复制按钮 + 等宽代码
struct CodeBlockView: View {
    let language: String?
    let code: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("复制代码")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            Divider().opacity(0.5)
            Text(code)
                .font(.system(size: 11.5).monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
