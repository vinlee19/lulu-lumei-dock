import AppKit
import EurekaKit
import SwiftUI

// MARK: - 富文本正文（Markdown 块渲染，会话/记忆/技能/计划共用）

/// Markdown 富文本：块级结构自绘（代码块/标题/列表/引用/分隔线/表格），
/// 行内样式（粗体/行内代码/链接）走 AttributedString(markdown:)。
struct MarkdownRichText: View {
    let blocks: [MarkdownBlock]

    init(text: String) {
        blocks = MarkdownBlockParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            if text.hasPrefix("|") {
                // 表格降级：等宽渲染保持列对齐
                Text(text)
                    .font(.system(size: 10.5).monospaced())
                    .textSelection(.enabled)
            } else {
                Text(Self.inline(text))
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
            }
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(.system(
                    size: level == 1 ? 13.5 : (level == 2 ? 12.8 : 12),
                    weight: .semibold))
                .padding(.top, 3)
                .textSelection(.enabled)
        case .codeBlock(let language, let code):
            CodeBlockView(language: language, code: code)
        case .listItem(let ordered, let index, let text, let indent):
            HStack(alignment: .top, spacing: 5) {
                Text(ordered ? "\(index)." : "•")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.brand.opacity(0.8))
                Text(Self.inline(text))
                    .font(.system(size: 11.5))
                    .textSelection(.enabled)
            }
            .padding(.leading, CGFloat(indent) * 12)
        case .quote(let text):
            HStack(alignment: .top, spacing: 7) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Theme.brand.opacity(0.4))
                    .frame(width: 2.5)
                Text(Self.inline(text))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        case .divider:
            Divider()
        case .table(let header, let rows):
            tableView(header: header, rows: rows)
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
                            .font(.system(size: 11, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columns, id: \.self) { col in
                            Text(Self.inline(col < row.count ? row[col] : ""))
                                .font(.system(size: 11))
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

    /// 行内 Markdown（粗体/斜体/行内代码/链接）；解析失败回退纯文本
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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
                .font(.system(size: 10.5).monospaced())
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
    }
}
