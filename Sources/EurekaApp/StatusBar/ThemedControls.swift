import EurekaKit
import SwiftUI

// Compact themed controls for dense dashboards (usage, limits). Each one keeps its classic
// branch byte-for-byte what the call sites drew before, so classic stays pixel-identical;
// only hard-edged styles get the brutal vocabulary: ink outline, flat brand fill and a
// zero-blur shadow on the shape layer (never on text).

/// Segmented picker. Classic is the system `.segmented` picker at the given width and
/// control size; brutal is an outlined capsule tray whose selected segment is a flat brand
/// capsule. The brutal tray hugs its content instead of taking the classic fixed width.
struct ThemedSegmentedPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    var classicWidth: CGFloat?
    var controlSize: ControlSize = .small

    var body: some View {
        if ThemeStyle.current.isHardEdged {
            brutalTray
        } else {
            Picker("", selection: $selection) {
                ForEach(options, id: \.self) { Text(label($0)) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: classicWidth)
            .controlSize(controlSize)
        }
    }

    private var fontSize: CGFloat { controlSize == .mini ? 10 : 11 }

    private var brutalTray: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { selection = option } label: {
                    Text(label(option))
                        .font(Theme.font.themed(fontSize, selected ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Theme.onBrand : .secondary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, controlSize == .mini ? 2 : 3.5)
                        .background(
                            Capsule()
                                .fill(selected ? Theme.brand : .clear)
                                .overlay(Capsule().strokeBorder(
                                    selected ? Theme.cardBorder : .clear, lineWidth: 1.5)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Capsule()
                .fill(Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .themeControlShadow())
        .fixedSize()
    }
}

/// Small filter chip with an optional source badge. Classic is the tinted capsule the usage
/// page always drew; brutal outlines every chip in ink and fills the selected one with the
/// brand color plus a control shadow.
struct CompactFilterChip: View {
    let label: String
    var source: AgentSource?
    var verticalPadding: CGFloat = 4
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            if ThemeStyle.current.isHardEdged { brutal } else { classic }
        }
        .buttonStyle(.plain)
    }

    private var classic: some View {
        HStack(spacing: 4) {
            if let source { SourceBadge(source: source, size: 10) }
            Text(label)
                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, verticalPadding)
        .background(Capsule().fill(
            isSelected ? Theme.brandFill(0.16) : Color.primary.opacity(0.05)))
        .foregroundStyle(isSelected ? Theme.brandFg : .secondary)
        .contentShape(Capsule())
    }

    private var brutal: some View {
        HStack(spacing: 4) {
            if let source { SourceBadge(source: source, size: 11) }
            Text(label)
                .font(Theme.font.themed(10.5, isSelected ? .semibold : .medium))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, verticalPadding + 1)
        .foregroundStyle(isSelected ? Theme.onBrand : .primary)
        .background(
            Capsule()
                .fill(isSelected ? Theme.brand : Theme.surface)
                .overlay(Capsule().strokeBorder(Theme.cardBorder, lineWidth: 1.5))
                .themeControlShadow(active: isSelected))
        .contentShape(Capsule())
    }
}

extension Theme {
    /// Fill for a progress / proportion bar: classic keeps its leading-to-trailing gradient,
    /// hard-edged styles paint the flat color (brutal has no gradients).
    static func barFill(_ color: Color, from startOpacity: Double) -> AnyShapeStyle {
        ThemeStyle.current.isHardEdged
            ? AnyShapeStyle(color)
            : AnyShapeStyle(LinearGradient(
                colors: [color.opacity(startOpacity), color],
                startPoint: .leading, endPoint: .trailing))
    }
}

extension View {
    /// Dashboard card (usage, limits): the outline and hard shadow are painted on the background shape,
    /// so no text ever lands in the shadow layer. Only hard-edged styles get the outline;
    /// classic and the palette themes keep the plain fill they always had (classic must stay
    /// pixel-identical).
    func dashboardCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(
                            ThemeStyle.current.isHardEdged ? Theme.cardBorder : .clear,
                            lineWidth: Theme.cardBorderWidth)
                )
                .themeCardShadow()
        )
    }
}
