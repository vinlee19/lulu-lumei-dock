import EurekaKit
import SwiftUI

// MARK: - Themed dialog
//
// `.alert` and `.confirmationDialog` are drawn by AppKit: a system sheet with system fonts and
// a blue default button, whatever the selected style. Every dialog in the main window has the
// same shape (a title, an optional message, one confirm button and Cancel, sometimes a name
// field), so one in-window card replaces them all. Views attach `themedConfirm` /
// `themedPrompt` where they used the system modifiers; `ThemedDialogHost`, placed once over
// the whole window in `PopoverRootView`, draws whichever dialog is current.

struct ThemedDialogModel: Identifiable {
    var id = UUID()
    var title: String
    var message: String?
    var confirmTitle: String
    var destructive = false
    /// Present for a name prompt: the field edits the caller's text directly.
    var text: Binding<String>?
    var placeholder = ""
    var onConfirm: () -> Void
    var onCancel: () -> Void = {}
}

/// One dialog at a time, like the system's window-modal sheets.
@MainActor
final class ThemedDialogCenter: ObservableObject {
    static let shared = ThemedDialogCenter()
    @Published private(set) var current: ThemedDialogModel?

    func present(_ model: ThemedDialogModel) {
        withAnimation(.easeOut(duration: 0.12)) { current = model }
    }

    func dismiss(id: UUID) {
        guard current?.id == id else { return }
        withAnimation(.easeOut(duration: 0.12)) { current = nil }
    }
}

extension View {
    /// A themed confirmation: `title`, optional `message`, `confirm` and Cancel. Same
    /// presentation contract as `.confirmationDialog(isPresented:)`.
    func themedConfirm(
        _ title: String, isPresented: Binding<Bool>, message: String? = nil,
        confirm: String, destructive: Bool = false,
        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}
    ) -> some View {
        modifier(ThemedDialogPresenter(isPresented: isPresented) {
            ThemedDialogModel(
                title: title, message: message, confirmTitle: confirm, destructive: destructive,
                onConfirm: onConfirm, onCancel: onCancel)
        })
    }

    /// A themed name prompt: `title`, a text field bound to `text`, `confirm` and Cancel.
    /// Confirm stays disabled while the trimmed text is empty.
    func themedPrompt(
        _ title: String, isPresented: Binding<Bool>, text: Binding<String>,
        placeholder: String, message: String? = nil, confirm: String,
        onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void = {}
    ) -> some View {
        modifier(ThemedDialogPresenter(isPresented: isPresented) {
            ThemedDialogModel(
                title: title, message: message, confirmTitle: confirm, text: text,
                placeholder: placeholder, onConfirm: onConfirm, onCancel: onCancel)
        })
    }
}

@MainActor
private struct ThemedDialogPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let make: () -> ThemedDialogModel
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { _, shown in
                if shown { present() } else { ThemedDialogCenter.shared.dismiss(id: id) }
            }
            .onAppear { if isPresented { present() } }
            .onDisappear { ThemedDialogCenter.shared.dismiss(id: id) }
    }

    private func present() {
        var model = make()
        model.id = id
        let binding = $isPresented
        let confirm = model.onConfirm
        let cancel = model.onCancel
        // The action runs first, then the binding resets: callers read their pending item
        // (`deleting`, `installTarget`, …) inside the action, as with the system dialogs.
        model.onConfirm = {
            confirm()
            binding.wrappedValue = false
        }
        model.onCancel = {
            cancel()
            binding.wrappedValue = false
        }
        ThemedDialogCenter.shared.present(model)
    }
}

/// Dims the window and shows the current dialog. Clicks on the dim layer do nothing: like
/// the system sheets it replaces, the dialog is answered with a button, Return or Esc.
struct ThemedDialogHost: View {
    @ObservedObject private var center = ThemedDialogCenter.shared

    var body: some View {
        if let model = center.current {
            ZStack {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}
                ThemedDialogCard(model: model)
                    .id(model.id)
            }
            .transition(.opacity)
        }
    }
}

struct ThemedDialogCard: View {
    let model: ThemedDialogModel
    @FocusState private var fieldFocused: Bool

    private var hard: Bool { ThemeStyle.current.isHardEdged }

    private var canConfirm: Bool {
        guard let text = model.text else { return true }
        return !text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title)
                .font(Theme.font.themed(14, .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if let message = model.message {
                Text(message)
                    .font(Theme.font.themed(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let text = model.text {
                TextField(model.placeholder, text: text)
                    .textFieldStyle(.plain)
                    .font(Theme.font.themed(13))
                    .focused($fieldFocused)
                    .onSubmit { if canConfirm { model.onConfirm() } }
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .fill(Theme.surfaceSecondary))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                            .strokeBorder(
                                fieldFocused ? Theme.brand : Theme.cardBorder,
                                lineWidth: hard ? Theme.cardBorderWidth : (fieldFocused ? 1.5 : 0.5)))
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                PaneButton(L10n.text("Cancel", zhHans: "取消"), action: model.onCancel)
                    .keyboardShortcut(.cancelAction)
                PaneButton(model.confirmTitle, kind: model.destructive ? .destructive : .primary,
                           action: model.onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
                    .opacity(canConfirm ? 1 : 0.5)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 400, alignment: .leading)
        .background(
            shape.fill(Theme.surface)
                .shadow(color: hard ? .clear : .black.opacity(0.22), radius: hard ? 0 : 18, y: hard ? 0 : 8)
                .themeCardShadow())
        .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: hard ? Theme.cardBorderWidth : 0.5))
        .onAppear { if model.text != nil { fieldFocused = true } }
    }
}
