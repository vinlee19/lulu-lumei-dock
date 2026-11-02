import EurekaKit
import SwiftUI

/// Popover behind the usage dashboard's custom-period button: one-click presets on the left,
/// a start and an end calendar on the right. Presets apply at once; picked days apply on
/// "Apply" (or Return), so the dashboard reloads once per choice instead of once per click.
struct UsageRangePicker: View {
    let onApply: (UsageRangeSelection) -> Void
    let onCancel: () -> Void
    @State private var draft: UsageRangeSelection

    init(
        selection: UsageRangeSelection,
        onApply: @escaping (UsageRangeSelection) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onApply = onApply
        self.onCancel = onCancel
        _draft = State(initialValue: selection)
    }

    private var range: UsageDateRange { draft.resolve() }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            presets
                .frame(width: 120)
                .padding(.vertical, 10)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 14) {
                    calendar(L10n.text("Start", zhHans: "开始"), selection: startBinding,
                             in: Date.distantPast...range.lastDay)
                    calendar(L10n.text("End", zhHans: "结束"), selection: endBinding,
                             in: range.firstDay...Date())
                }
                Divider()
                HStack(spacing: 8) {
                    Text(UsageRangeText.span(range))
                        .font(Theme.font.themed(11, .medium))
                        .monospacedDigit()
                    Spacer(minLength: 12)
                    SecondaryButton(
                        title: L10n.text("Cancel", zhHans: "取消"), classic: .push, action: onCancel)
                        .keyboardShortcut(.cancelAction)
                    PrimaryButton(
                        title: L10n.text("Apply", zhHans: "应用"),
                        shortcut: .defaultAction) { onApply(draft) }
                }
            }
            .padding(14)
        }
        .fixedSize()
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.text("Quick ranges", zhHans: "快捷选择"))
                .font(Theme.font.themed(10, .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.bottom, 4)
            ForEach(UsageDateRange.Preset.allCases, id: \.self) { preset in
                PresetRow(
                    title: UsageRangeText.title(preset),
                    isSelected: draft == .preset(preset)
                ) { onApply(.preset(preset)) }
            }
        }
        .padding(.horizontal, 6)
    }

    private func calendar(
        _ title: String, selection: Binding<Date>, in bounds: ClosedRange<Date>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Theme.font.themed(10, .semibold))
                .foregroundStyle(.secondary)
            DatePicker("", selection: selection, in: bounds, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
        }
    }

    // Picking a day turns a preset into those exact days
    private var startBinding: Binding<Date> {
        Binding(
            get: { range.firstDay },
            set: { draft = .days(UsageDateRange($0, range.lastDay)) })
    }

    private var endBinding: Binding<Date> {
        Binding(
            get: { range.lastDay },
            set: { draft = .days(UsageDateRange(range.firstDay, $0)) })
    }
}

private struct PresetRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.font.themed(11, isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Theme.brandFg : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.tile)
                        .fill(isSelected
                              ? Theme.brandFill(0.16)
                              : (hovering ? Color.primary.opacity(0.06) : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Wording for custom ranges, shared by the picker, its button and the dashboard headings
enum UsageRangeText {
    static func title(_ preset: UsageDateRange.Preset) -> String {
        switch preset {
        case .yesterday: return L10n.text("Yesterday", zhHans: "昨天")
        case .last7Days: return L10n.text("Last 7 days", zhHans: "近 7 天")
        case .last30Days: return L10n.text("Last 30 days", zhHans: "近 30 天")
        case .last90Days: return L10n.text("Last 90 days", zhHans: "近 90 天")
        case .lastWeek: return L10n.text("Last week", zhHans: "上周")
        case .lastMonth: return L10n.text("Last month", zhHans: "上月")
        case .thisYear: return L10n.text("This year", zhHans: "今年")
        }
    }

    /// "10/23 – 10/29", or a single day; years appear once the range leaves the current year
    static func dates(_ range: UsageDateRange, calendar: Calendar = .current, now: Date = Date()) -> String {
        let year = calendar.component(.year, from: now)
        let withYear = calendar.component(.year, from: range.firstDay) != year
            || calendar.component(.year, from: range.lastDay) != year
        let style = withYear
            ? Date.FormatStyle().year().month(.defaultDigits).day()
            : Date.FormatStyle().month(.defaultDigits).day()
        if range.firstDay == range.lastDay { return range.firstDay.formatted(style) }
        return "\(range.firstDay.formatted(style)) – \(range.lastDay.formatted(style))"
    }

    /// "10/23 – 10/29 · 7 days"
    static func span(_ range: UsageDateRange) -> String {
        L10n.format("%1$@ · %2$@ days", zhHans: "%1$@ · 共 %2$@ 天",
                    dates(range), String(range.dayCount()))
    }

    /// The custom-period button: a preset says its name, picked days say how many
    static func button(_ selection: UsageRangeSelection) -> String {
        let range = selection.resolve()
        switch selection {
        case .preset(let preset): return "\(title(preset)) · \(dates(range))"
        case .days: return span(range)
        }
    }
}
