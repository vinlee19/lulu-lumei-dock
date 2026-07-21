import SwiftUI

/// 统一区块卡片：可选标题 + 中性底圆角容器（主窗口各页签共用）。
/// 替代改版前各页签自带的彩色 cardFill / settingCard / card helper。
struct SectionCard<Content: View>: View {
    let title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: Theme.spacing.row) {
                content
            }
            .padding(Theme.spacing.card)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius.card)
                            .strokeBorder(Theme.hairline, lineWidth: 0.5)
                    )
            )
        }
    }
}

/// 灰底胶囊子页签：选中 = 品牌色底白字；未选中 = 灰字、悬停微高亮。
/// 主窗口页签条 / 设置子栏目 / 仪表盘子页签共用。
struct CapsuleTabButton: View {
    let title: String
    var icon: String?
    /// true = 均分填满父容器（主窗口页签条）；false = 自适应内容宽度（子页签条）
    var fillWidth = true
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? .white : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 胶囊标签条容器：灰底圆角托盘（仿系统设置的分段控件）。
struct CapsuleTabTray<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 3) { content }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.surfaceSecondary))
    }
}

/// 侧边栏导航条目：选中 = 品牌色圆角胶囊白字；未选中 = 灰字、悬停微高亮（主窗口左侧边栏用）。
struct SidebarNavButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? .white : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8).fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
