import EurekaKit
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
    /// 图标块底色（侧边栏式彩色小方块；nil = 图标随文字色）
    var tileColor: Color?
    /// true = 均分填满父容器（主窗口页签条）；false = 自适应内容宽度（子页签条）
    var fillWidth = true
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                if let icon {
                    if let tileColor {
                        RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                            .fill(tileColor.gradient)
                            .frame(width: 14, height: 14)
                            .overlay(
                                Image(systemName: icon)
                                    .font(.system(size: 7.5, weight: .semibold))
                                    .foregroundStyle(.white))
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                    }
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

/// 侧边栏导航条目（macOS 系统设置式）：左侧彩色圆角小方块图标 + 中性文字；
/// 选中 = 品牌色圆角胶囊白字（图标块颜色保持）；未选中 = 灰字、悬停微高亮。
struct SidebarNavButton: View {
    let title: String
    let icon: String
    /// 图标块底色（每个条目一色，系统设置式）
    let tileColor: Color
    /// 尾部小徽标（如限额百分比），nil 不显示
    var badge: String?
    var badgeColor: Color = .secondary
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(tileColor.gradient)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                    )
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.9))
                                                    : AnyShapeStyle(badgeColor))
                }
            }
            .foregroundStyle(isSelected ? .white : (hovering ? .primary : .secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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

// MARK: - 统计瓦片（Skills / Memory / Plans / Agents 页共用，点击即筛选）

/// 顶部统计瓦片：大数字 + 来源徽标/图标 + 标签。放在 HStack 中等宽均分，
/// 保证各 CLI 的瓦片在 UI 上一样大小；选中态品牌描边 + 品牌浅底。
struct StatTile: View {
    let value: String
    var sub: String?
    let label: String
    var icon: String?
    var source: AgentSource?
    let tint: Color
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold).monospacedDigit())
                    if let sub {
                        Text(sub)
                            .font(.system(size: 9.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                HStack(spacing: 4) {
                    if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 9))
                            .foregroundStyle(tint)
                    }
                    if let source {
                        SourceBadge(source: source, size: 10)
                    }
                    Text(label)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            // 等宽均分：内容撑满分配宽度，HStack 中每片一样大
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(isSelected ? Theme.brandFill(0.10) : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(
                        isSelected ? Theme.brand.opacity(0.7)
                                   : (hovering ? Theme.brand.opacity(0.35) : Theme.hairline),
                        lineWidth: isSelected ? 1 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
