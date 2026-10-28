import EurekaKit
import SwiftUI

/// Toolbar chip naming the template the next run uses; opens the template list
struct SummaryTemplateChip: View {
    @ObservedObject var summaries: SessionSummaryService

    @State private var showList = false
    @State private var editing: SummaryTemplateSpec?

    var body: some View {
        let hard = ThemeStyle.current.isHardEdged
        Button { showList.toggle() } label: {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack")
                    .font(Theme.font.themed(10, .semibold))
                Text(summaries.selectedTemplate.name)
                    .font(Theme.font.themed(11.5, .semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(Theme.font.themed(8, .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(hard ? Theme.ink : Theme.brandFg)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(hard ? Theme.surface : Theme.brandFill(0.10)).themeControlShadow())
            .overlay(Capsule().strokeBorder(
                hard ? Theme.ink : Theme.brand.opacity(0.25),
                lineWidth: hard ? Theme.cardBorderWidth : 0.8))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L10n.text("Template for the next summary", zhHans: "下次总结使用的模板"))
        .themedPopup(isPresented: $showList) {
            SummaryTemplateList(summaries: summaries) { template in
                showList = false
                editing = template
            }
        }
        .sheet(item: $editing) { template in
            SummaryTemplateEditor(summaries: summaries, original: template) { editing = nil }
        }
    }
}

/// Template choices: each with its one-line purpose; built-ins can be copied, the person's own
/// edited; a new blank template can be started
struct SummaryTemplateList: View {
    @ObservedObject var summaries: SessionSummaryService
    /// Opens the editor (with a copy for built-ins, a blank one for "New")
    let onEdit: (SummaryTemplateSpec) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Summary template", zhHans: "总结模板"))
                .font(Theme.font.themed(9.5, .semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 7)
                .padding(.bottom, 2)
            ForEach(summaries.templates) { template in
                row(template)
            }
            Divider().padding(.vertical, 3)
            Button {
                onEdit(SummaryTemplateSpec(
                    id: "custom-" + UUID().uuidString,
                    name: L10n.text("My template", zhHans: "我的模板"), summary: "",
                    sections: [.init(heading: SummaryTemplateSpec.Heading.tldr, guidance: "")],
                    focus: ""))
            } label: {
                Label(L10n.text("New template", zhHans: "新建模板"), systemImage: "plus")
                    .font(Theme.font.themed(11))
                    .modifier(PickerRowChrome(selected: false))
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .frame(width: 320)
        .background(
            ThemeStyle.current.isHardEdged
                ? AnyShapeStyle(Theme.surface)
                : AnyShapeStyle(LinearGradient(
                    colors: [Theme.brand.opacity(0.06), Theme.gold.opacity(0.05)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    private func row(_ template: SummaryTemplateSpec) -> some View {
        let selected = summaries.selectedTemplateId == template.id
        return HStack(alignment: .top, spacing: 8) {
            Button {
                summaries.selectedTemplateId = template.id
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(Theme.font.themed(11))
                        .foregroundStyle(selected ? Theme.brandFg : .secondary)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(template.name)
                                .font(Theme.font.themed(11.5, selected ? .semibold : .medium))
                            if template.isBuiltIn {
                                Text(L10n.text("Built-in", zhHans: "内置"))
                                    .font(Theme.font.themed(9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !template.summary.isEmpty {
                            Text(template.summary)
                                .font(Theme.font.themed(10))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                onEdit(template.isBuiltIn
                    ? template.duplicated(name: L10n.format("%@ (mine)", zhHans: "%@（我的）", template.name))
                    : template)
            } label: {
                Image(systemName: template.isBuiltIn ? "plus.square.on.square" : "pencil")
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(template.isBuiltIn
                ? L10n.text("Copy and edit", zhHans: "复制一份再编辑")
                : L10n.text("Edit", zhHans: "编辑"))
        }
        .modifier(PickerRowChrome(selected: selected))
    }
}

/// Template editor: name, purpose, the sections in order (heading + what to write) and focus
/// instructions. The fixed safety rules are stated, not editable.
struct SummaryTemplateEditor: View {
    @ObservedObject var summaries: SessionSummaryService
    let original: SummaryTemplateSpec
    let onClose: () -> Void

    @State private var draft: SummaryTemplateSpec
    @State private var confirmingDelete = false

    init(summaries: SessionSummaryService, original: SummaryTemplateSpec, onClose: @escaping () -> Void) {
        self.summaries = summaries
        self.original = original
        self.onClose = onClose
        _draft = State(initialValue: original)
    }

    private var isExisting: Bool { summaries.customTemplates.contains { $0.id == original.id } }
    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !draft.usableSections.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isExisting
                    ? L10n.text("Edit template", zhHans: "编辑模板")
                    : L10n.text("New template", zhHans: "新建模板"))
                    .font(Theme.font.themed(15, .bold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    field(L10n.text("Name", zhHans: "名称")) {
                        input(text: $draft.name, placeholder: L10n.text("e.g. Weekly reflection", zhHans: "例如：每周复盘"))
                    }
                    field(L10n.text("What it is for", zhHans: "用途")) {
                        input(text: $draft.summary, placeholder: L10n.text("One line shown in the template list", zhHans: "在模板列表里显示的一句话"))
                    }
                    field(L10n.text("Sections, in order", zhHans: "章节（按顺序）")) {
                        VStack(spacing: 8) {
                            ForEach($draft.sections) { $section in
                                sectionRow($section)
                            }
                            Button {
                                draft.sections.append(.init(heading: ""))
                            } label: {
                                Label(L10n.text("Add a section", zhHans: "添加章节"), systemImage: "plus")
                                    .font(Theme.font.themed(11, .medium))
                                    .foregroundStyle(Theme.brandFg)
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    field(L10n.text("Focus", zhHans: "关注点")) {
                        editor(text: $draft.focus, minHeight: 64)
                        Text(L10n.text(
                            "Perspective, emphasis or length, e.g. \"Write in the first person; keep it under one screen\".",
                            zhHans: "视角、侧重或篇幅，例如「用第一人称写；控制在一屏以内」。"))
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                    }
                    Label {
                        Text(L10n.text(
                            "Always applied and not editable: the conversation is treated as data, citations must point at real messages, and nothing (including your reasons) is made up.",
                            zhHans: "始终生效、不能修改的规则：对话只当作数据、引用必须指向真实消息、不编造任何内容（包括你的理由）。"))
                    } icon: {
                        Image(systemName: "lock")
                    }
                    .font(Theme.font.themed(10.5))
                    .foregroundStyle(.secondary)
                }
                .padding(20)
            }
            Divider()
            HStack(spacing: 8) {
                if isExisting {
                    SecondaryButton(title: L10n.text("Delete", zhHans: "删除"), icon: "trash", destructive: true) {
                        confirmingDelete = true
                    }
                }
                Spacer()
                SecondaryButton(title: L10n.text("Cancel", zhHans: "取消")) { onClose() }
                PrimaryButton(title: L10n.text("Save and use", zhHans: "保存并使用"), icon: "checkmark") {
                    var saved = draft
                    saved.sections = saved.usableSections
                    summaries.saveTemplate(saved)
                    summaries.selectedTemplateId = saved.id
                    onClose()
                }
                .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 580, height: 640)
        .background(Theme.windowBackground)
        .themedConfirm(
            L10n.format("Delete the template \"%@\"?", zhHans: "删除模板「%@」？", original.name),
            isPresented: $confirmingDelete,
            confirm: L10n.text("Delete", zhHans: "删除"), destructive: true
        ) {
            summaries.deleteTemplate(id: original.id)
            onClose()
        }
    }

    private func sectionRow(_ section: Binding<SummaryTemplateSpec.Section>) -> some View {
        let index = draft.sections.firstIndex { $0.id == section.wrappedValue.id } ?? 0
        return HStack(alignment: .top, spacing: 8) {
            Text("\(index + 1)")
                .font(Theme.font.themedMono(11, .semibold))
                .foregroundStyle(Theme.brandFg)
                .frame(width: 18, alignment: .trailing)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 6) {
                input(text: section.heading, placeholder: L10n.text("Heading", zhHans: "章节标题"), mono: false, weight: .semibold)
                input(text: section.guidance, placeholder: L10n.text("What to write here (optional)", zhHans: "这一节写什么（可选）"), axis: .vertical)
            }
            VStack(spacing: 2) {
                iconButton("chevron.up", disabled: index == 0) {
                    draft.sections.swapAt(index, index - 1)
                }
                iconButton("chevron.down", disabled: index >= draft.sections.count - 1) {
                    draft.sections.swapAt(index, index + 1)
                }
                iconButton("minus.circle", disabled: draft.sections.count <= 1) {
                    draft.sections.remove(at: index)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                .fill(Theme.surfaceSecondary))
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(Theme.font.themed(11.5, .semibold))
            content()
        }
    }

    private func input(
        text: Binding<String>, placeholder: String, mono: Bool = false,
        weight: Font.Weight = .regular, axis: Axis = .horizontal
    ) -> some View {
        let hard = ThemeStyle.current.isHardEdged
        return TextField(placeholder, text: text, axis: axis)
            .textFieldStyle(.plain)
            .font(mono ? Theme.font.themedMono(11.5, weight) : Theme.font.themed(12, weight))
            .lineLimit(axis == .vertical ? 1...4 : 1...1)
            .tint(Theme.brand)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous)
                    .strokeBorder(hard ? Theme.ink : Theme.hairline, lineWidth: 1))
    }

    private func editor(text: Binding<String>, minHeight: CGFloat) -> some View {
        let hard = ThemeStyle.current.isHardEdged
        return TextEditor(text: text)
            .font(Theme.font.themed(12))
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight, maxHeight: 120)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous).fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: hard ? 0 : 6, style: .continuous)
                    .strokeBorder(hard ? Theme.ink : Theme.hairline, lineWidth: 1))
    }

    private func iconButton(_ icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(Theme.font.themed(10))
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
    }
}
