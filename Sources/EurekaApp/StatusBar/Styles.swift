import EurekaIngest
import EurekaKit
import SwiftUI

/// 主题硬阴影辅助：raft = 零模糊偏移墨影（brutalist）；classic = 不投影（原样）。
extension View {
    /// 卡片级硬阴影（4/4）
    @ViewBuilder
    func themeCardShadow() -> some View {
        if let shadow = Theme.cardShadow {
            self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            self
        }
    }

    /// 小控件级硬阴影（2/2）；active = false 时不投（如未选中胶囊）
    @ViewBuilder
    func themeControlShadow(active: Bool = true) -> some View {
        if active, let shadow = Theme.controlShadow {
            self.shadow(color: shadow.color, radius: shadow.radius, x: shadow.x, y: shadow.y)
        } else {
            self
        }
    }
}

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
                    .font(Theme.font.themed(13, .semibold))
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
                            .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth)
                    )
                    .themeCardShadow()
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
                // 空标题 = 纯图标档（`LayoutToggle` 三档时如此）：连 Text 一起省掉，
                // 否则 HStack 的 spacing 会给图标留出一段不对称的空白
                if !title.isEmpty {
                    Text(title)
                        .font(Theme.font.themed(11, isSelected ? .semibold : .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
                    .overlay(
                        Group {
                            if isSelected, ThemeStyle.current == .raft {
                                Capsule().strokeBorder(Theme.ink, lineWidth: 2)
                            }
                        }
                    )
                    .themeControlShadow(active: isSelected)
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

/// 侧边栏导航条目：默认单色中性灰图标（「紫金」方案去彩虹色块）+ 中性文字；
/// 选中 = 品牌紫圆角胶囊白字白图标；未选中 = 灰字、悬停微高亮。
struct SidebarNavButton: View {
    let title: String
    let icon: String
    /// 图标块底色（传值则显示彩色圆角小方块；nil = 单色灰图标）
    var tileColor: Color?
    /// 尾部小徽标（如限额百分比），nil 不显示
    var badge: String?
    var badgeColor: Color = .secondary
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                if let tileColor {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tileColor.gradient)
                        .frame(width: 20, height: 20)
                        .overlay(
                            Image(systemName: icon)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 20, height: 20)
                }
                Text(title)
                    .font(Theme.font.themed(12, isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(Theme.font.themedMono(9.5, .semibold))
                        .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.9))
                                                    : AnyShapeStyle(badgeColor))
                }
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 8)
            // 4 而不是 5：12 个页签 + 5 个组标签 + 品牌脚注要挤进最小窗高的 ~512pt 内容区，
            // 每行省 2pt 就是 24pt。行高 28pt 仍高于 macOS 侧栏的最小可点尺寸。
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.sidebar).fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
                    .overlay(
                        Group {
                            if isSelected, ThemeStyle.current == .raft {
                                RoundedRectangle(cornerRadius: Theme.radius.sidebar)
                                    .strokeBorder(Theme.ink, lineWidth: 2)
                            }
                        }
                    )
                    .themeControlShadow(active: isSelected)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.sidebar))
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
                        .font(Theme.font.themedMono(17, .semibold))
                    if let sub {
                        Text(sub)
                            .font(Theme.font.themedMono(9.5))
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
                        .font(Theme.font.themed(10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            // 等宽均分：内容撑满分配宽度，HStack 中每片一样大
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .fill(isSelected ? Theme.brandFill(0.10) : Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container)
                    .strokeBorder(
                        ThemeStyle.current == .raft
                            ? (isSelected || hovering ? Theme.ink : Theme.cardBorder)
                            : (isSelected ? Theme.brand.opacity(0.7)
                                          : (hovering ? Theme.brand.opacity(0.35) : Theme.cardBorder)),
                        lineWidth: ThemeStyle.current == .raft ? 2 : (isSelected ? 1 : 0.5)))
            .themeControlShadow(active: isSelected)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.container))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 知识库统一卡片壳 & 悬停动作（Skills / Memory / Plans / Agents 卡片网格共用）

/// 卡片动作：悬停浮现的图标按钮（编辑 / Finder / 删除）。destructive 悬停自身时转红。
struct CardAction: Identifiable {
    let id = UUID()
    let icon: String
    var destructive = false
    var help: String?
    let action: () -> Void
}

/// 悬停动作簇里的单个字形按钮：默认中性灰，悬停自身时高亮（删除 → 失败红）。
private struct CardGlyphButton: View {
    let action: CardAction
    @State private var hovering = false

    var body: some View {
        Button(action: action.action) {
            Image(systemName: action.icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(action.help ?? "")
    }

    private var tint: Color {
        if hovering { return action.destructive ? Theme.failureRed : .primary }
        return .secondary
    }
}

/// 悬停时浮现的动作簇（毛玻璃胶囊托底，浮于卡片右下角 meta 之上）。
private struct KnowledgeCardActions: View {
    let actions: [CardAction]

    var body: some View {
        HStack(spacing: 1) {
            ForEach(actions) { CardGlyphButton(action: $0) }
        }
        .padding(.horizontal, 2)
        .background(Capsule(style: .continuous).fill(.regularMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
    }
}

/// 知识库统一卡片壳：中性底 + 卡片圆角 + 柔和投影 + 悬停描边；停用态整卡变淡；**无色脊**；
/// 整卡点击进详情；操作按钮默认隐藏、悬停时右下角淡入；右键菜单由调用方按各页语义传入。
/// content 内推荐布局：`标题行(图标+名+尾附件) → 描述/副标题 → Spacer → meta 行`。
struct KnowledgeCard<Content: View, Menu: View>: View {
    var enabled = true
    /// 最小高度：0 = 随内容自适应（网格同行自动等高），避免固定高度造成中部空洞
    var minHeight: CGFloat = 0
    var actions: [CardAction] = []
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        content()
            .padding(12)
            .frame(minHeight: minHeight, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .fill(Theme.surface)
                    .opacity(enabled ? 1 : 0.6))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .strokeBorder(
                        ThemeStyle.current == .raft
                            ? Theme.ink
                            : (hovering ? Theme.brand.opacity(0.6) : Theme.cardBorder),
                        lineWidth: ThemeStyle.current == .raft ? 2 : (hovering ? 1 : 0.5)))
            .overlay(alignment: .bottomTrailing) {
                if hovering, !actions.isEmpty {
                    KnowledgeCardActions(actions: actions)
                        .padding(7)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
            .shadow(
                color: ThemeStyle.current == .raft ? .clear : .black.opacity(0.06),
                radius: ThemeStyle.current == .raft ? 0 : 3,
                y: ThemeStyle.current == .raft ? 0 : 1.5)
            .themeCardShadow()
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.card))
            .onTapGesture { onOpen() }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .contextMenu { menu() }
    }
}

// MARK: - 统一小标签 / 状态点 / 空状态 / 搜索框 / 分区头 / 文档卡

/// 统一小标签（项目名 = 金；中性 = 灰）。替换各页复制的项目 chip / 「只读」/「内置」pill。
struct TagChip: View {
    let text: String
    var tint: Color = Theme.gold
    var neutral = false

    init(_ text: String, tint: Color = Theme.gold, neutral: Bool = false) {
        self.text = text
        self.tint = tint
        self.neutral = neutral
    }

    var body: some View {
        Text(text)
            .font(Theme.font.themed(9, .medium))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(neutral ? Color.primary.opacity(0.06) : tint.opacity(0.15)))
            .foregroundStyle(neutral ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
    }
}

/// 启停小圆点（克制绿 = 启用 / 灰 = 停用），点击切换；替换饱和绿方块。
struct StatusDot: View {
    let enabled: Bool
    var size: CGFloat = 9
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Circle()
                .fill(enabled ? Theme.enabledGreen.opacity(0.9) : Color.secondary.opacity(0.4))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(enabled ? "已启用（点击停用）" : "已停用（点击启用）")
    }
}

/// 统一空状态：淡品牌色图标 + 标题 + 可选提示 + 可选主操作按钮（四页共用）。
struct EmptyStateView: View {
    let icon: String
    let title: String
    var hint: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.brand.opacity(0.5))
            Text(title)
                .font(Theme.font.themed(12))
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(Theme.font.themed(10))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.brand)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// 统一搜索框（紫金主张版）：紫金渐变放大镜方块 + 胶囊底 + 聚焦时紫金渐变环与柔光；
/// 搜索中右侧显示命中数胶囊 + 圆形清空键。四页共用（来源筛选由下方 chips 承担）。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var scanning = false
    /// 命中数（搜索时显示在右侧；nil = 不显示）
    var resultCount: Int?
    /// 最大宽度：设计稿里搜索框是中等宽度，不铺满整行（nil = 由父容器决定）
    var maxWidth: CGFloat? = 460

    @FocusState private var focused: Bool
    @State private var hovering = false

    private var searching: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 9) {
            glyph
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Theme.font.themed(12.5))
                .tint(Theme.brand)  // 紫色光标与选区
                .focused($focused)
            if scanning { ProgressView().controlSize(.mini) }
            trailing
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: maxWidth)
        .background(
            Capsule(style: .continuous)
                .fill(Theme.surface)
                .overlay(
                    Capsule(style: .continuous)
                        .fill(Theme.brandFill(focused ? 0.10 : (hovering ? 0.06 : 0.035)))))
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    ThemeStyle.current == .raft
                        ? AnyShapeStyle(Theme.ink)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Theme.brand.opacity(focused ? 1 : 0.5),
                                     Theme.gold.opacity(focused ? 1 : 0.5)],
                            startPoint: .leading, endPoint: .trailing)),
                    lineWidth: ThemeStyle.current == .raft
                        ? (focused ? 2.5 : 1.5)
                        : (focused ? 1.8 : 1)))
        .shadow(
            color: ThemeStyle.current == .raft ? .clear : Theme.brand.opacity(focused ? 0.22 : 0),
            radius: ThemeStyle.current == .raft ? 0 : 10,
            y: ThemeStyle.current == .raft ? 0 : 2)
        .themeControlShadow()
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.16), value: focused)
        .animation(.easeOut(duration: 0.16), value: hovering)
    }

    /// 品牌渐变放大镜方块（与品牌标 / logo 方块同一套方块语言；金色留给聚焦描边环）。
    /// raft = cyan 平色方块 + 墨色描边 + 硬影。
    private var glyph: some View {
        RoundedRectangle(cornerRadius: ThemeStyle.current == .raft ? 3 : 7, style: .continuous)
            .fill(Theme.brandTileGradient)
            .frame(width: 24, height: 24)
            .overlay(
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(Theme.onBrand))
            .overlay(
                Group {
                    if ThemeStyle.current == .raft {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Theme.ink, lineWidth: 1.5)
                    }
                }
            )
            .shadow(
                color: ThemeStyle.current == .raft ? .clear : Theme.brand.opacity(focused ? 0.38 : 0.18),
                radius: ThemeStyle.current == .raft ? 0 : 3,
                y: ThemeStyle.current == .raft ? 0 : 1)
            .themeControlShadow()
    }

    @ViewBuilder private var trailing: some View {
        if searching {
            if let resultCount {
                Text("\(resultCount)")
                    .font(Theme.font.themedMono(10.5, .semibold))
                    .foregroundStyle(Theme.brand)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brandFill(0.14)))
                    .help("匹配项数量")
            }
            Button { text = "" } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.brand)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(Theme.brandFill(0.14)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("清空搜索")
        }
    }
}

/// 统一来源分区头：折叠箭头 + 来源徽标/金图标 + 标题 + 可选副标题 + 中性计数 + 可选备注 + 贯通分隔线。
/// 收编 Skills / Memory / Plans / Agents 三份重复实现（计数统一为中性灰胶囊，去掉金/紫不一致）。
struct SourceSectionHeader: View {
    var source: AgentSource?
    var icon: String?
    let title: String
    var subtitle: String?
    let count: Int
    var trailingNote: String?
    let collapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Button(action: onToggle) {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(collapsed ? 0 : 90))
                    if let source {
                        SourceBadge(source: source, size: 12)
                    } else if let icon {
                        Image(systemName: icon)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.gold)
                    }
                    Text(title)
                        .font(Theme.font.themed(12, .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.font.themed(11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text("\(count)")
                        .font(Theme.font.themedMono(10, .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceSecondary))
                    if let trailingNote {
                        Text(trailingNote)
                            .font(Theme.font.themed(10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            VStack { Divider() }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 详情页统一 Markdown 文档卡（限宽居中 + 宽松内边距）。四个详情页共用，替换逐字复制的卡块。
struct MarkdownDocumentCard: View {
    let text: String

    var body: some View {
        ScrollView {
            MarkdownRichText(text: text)
                .padding(24)
                .frame(maxWidth: 720, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .fill(Theme.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radius.card)
                                .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                        .themeCardShadow())
                .frame(maxWidth: .infinity)
                .padding(Theme.spacing.page)
        }
    }
}

// MARK: - 卡片 / 列表行 / 详情工具条共用小控件
// （原分散在 SkillMemoryView.swift，收敛至此以便 Skills / Memory / Plans / Agents 各页共用）

/// 统一方块规格：浅色染底 + 同色浅描边 + 圆角 8（参考稿简约风）。
/// logo 块 / 计划图标块都按这一套渲染，保证全站方块协调。
struct TileSpec {
    /// 填充底色（tint 10%）
    static func fill(_ tint: Color, hovering: Bool = false) -> Color {
        tint.opacity(hovering ? 0.18 : 0.10)
    }
    /// 描边（tint 16%）
    static func border(_ tint: Color) -> Color {
        tint.opacity(0.16)
    }
    /// 圆角：26pt 方块 ≈ 8，随尺寸略缩
    static func radius(_ size: CGFloat) -> CGFloat {
        min(Theme.radius.tile, size * 0.32)
    }
}

/// 26×26 紫底浅框 logo 小块（技能卡片 / 列表行 / 详情工具条共用）
struct SourceLogoTile: View {
    let source: AgentSource
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        ThemeStyle.current == .raft ? Theme.ink : TileSpec.border(Theme.brand),
                        lineWidth: ThemeStyle.current == .raft ? 1.5 : 0.5))
            .overlay(SourceBadge(source: source, size: size * 0.55))
    }
}

/// 迷你启用开关（30×17）：绿 = 开 / 灰 = 关，圆头右/左；技能卡片 / 列表行 / 详情工具条共用
struct MiniSwitch: View {
    let isOn: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            Capsule()
                .fill(isOn ? Theme.enabledGreen : Theme.disabledGray)
                .frame(width: 30, height: 17)
                .overlay(
                    Group {
                        if ThemeStyle.current == .raft {
                            Capsule().strokeBorder(Theme.ink, lineWidth: 1.5)
                        }
                    }
                )
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(ThemeStyle.current == .raft ? Color(hex: "FFFAEF") : .white)
                        .shadow(
                            color: ThemeStyle.current == .raft ? .clear : .black.opacity(0.18),
                            radius: ThemeStyle.current == .raft ? 0 : 1,
                            y: ThemeStyle.current == .raft ? 0 : 0.5)
                        .overlay(
                            Group {
                                if ThemeStyle.current == .raft {
                                    Circle().strokeBorder(Theme.ink, lineWidth: 1.5)
                                }
                            }
                        )
                        .frame(width: 13, height: 13)
                        .padding(2)
                }
        }
        .buttonStyle(.plain)
        .help(isOn ? "已启用（点击停用）" : "已停用（点击启用）")
    }
}

/// 启用状态文字（已启用绿 / 已停用灰）+ 迷你开关（详情工具条 / 列表行用；卡面只用 MiniSwitch）
struct EnableToggle: View {
    let enabled: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(enabled ? "已启用" : "已停用")
                .font(Theme.font.themed(9.5, .medium))
                .foregroundStyle(enabled ? Theme.enabledGreen : .secondary)
            MiniSwitch(isOn: enabled, onToggle: onToggle)
        }
    }
}

/// 卡片动作图标按钮（编辑/目录/删除）：中性简约风——浅灰底 + 细灰边 + 灰图标，
/// 仅删除用红色图标（无红底）；hover 底色加深。列表行 / 详情等常驻动作处用。
struct CardActionButton: View {
    let icon: String
    var color: Color = .secondary
    var size: CGFloat = 24
    var help: String?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.44, weight: .medium))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                        .fill(Color.primary.opacity(hovering ? 0.08 : 0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .contentShape(RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - 布局切换（卡片 / 列表；Skills / Memory / Plans / Agents 四页共用）

/// 知识库视图模式：通栏列表 / 图标（卡片网格）。顺序即分段控件顺序（列表在左，默认）。
enum KnowledgeLayout: String, CaseIterable {
    case list = "列表"
    case cards = "图标"
    /// 关系图谱：目前只有 Memory 页有（记忆之间有 `[[链接]]`、还指向来源会话；
    /// 技能/计划/agent 之间没有这种关系，给它们这一档只会是个空图）
    case graph = "图谱"

    var icon: String {
        switch self {
        case .list: return "list.bullet"
        case .cards: return "square.grid.2x2"
        case .graph: return "point.3.filled.connected.trianglepath.dotted"
        }
    }

    /// 有关系图的页面用它，其余页面用 `withoutGraph`
    static let withoutGraph: [KnowledgeLayout] = [.list, .cards]
}

/// 顶部工具条右侧的「卡片 / 列表 / 图谱」分段切换（与全站分段控件同款）。
/// `cases` 由调用方给：没有关系可画的页面不该凭空多出一档图谱。
struct LayoutToggle: View {
    @Binding var layout: KnowledgeLayout
    var cases: [KnowledgeLayout] = KnowledgeLayout.withoutGraph

    var body: some View {
        // 三档时只留图标：顶栏在最小窗宽（840）下本就紧，带文字会把「列表」挤成省略号
        let iconOnly = cases.count > 2
        CapsuleTabTray {
            ForEach(cases, id: \.self) { item in
                CapsuleTabButton(
                    title: iconOnly ? "" : item.rawValue, icon: item.icon, fillWidth: false,
                    isSelected: layout == item
                ) { layout = item }
                    .help(item.rawValue)
            }
        }
    }
}

/// 扫描状态标签（Skills / Memory / Plans / Agents 顶栏共用，紧挨刷新按钮）。
///
/// 为什么需要：这四页的数据在应用启动时就后台扫好了，进页面不再盲扫 —— 那么「现在到底在不在扫」
/// 与「数据有多旧」就必须显式说出来。原来 `scanning` 只体现在搜索框里一个 mini spinner 和
/// **空状态**文案上，列表一旦有数据，重扫时几乎看不出来。
/// 又因为不做文件系统监听（外部新增技能不会自动出现），「上次扫描 X 前」是用户判断该不该点刷新的唯一依据。
struct ScanStatusLabel: View {
    let scanning: Bool
    /// 扫描阶段文案（Plans 会在物化/索引之间切换）
    var phase: String?
    var lastScanAt: Date?

    var body: some View {
        if scanning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(phase ?? "正在扫描…")
                    .font(Theme.font.themed(11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .transition(.opacity)
        } else if let lastScanAt {
            Text("上次扫描 " + relativeFormatter.localizedString(for: lastScanAt, relativeTo: Date()))
                .font(Theme.font.themed(9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .help("进页面不再自动重扫；点刷新可强制全量重扫")
        }
    }
}

/// 统一刷新按钮：紫图标 + 淡紫圆底（各管理页顶栏共用）。
/// 明显但紧凑——作为次级动作，不与「新建」文字胶囊抢戏。
struct RefreshButton: View {
    var help = "刷新"
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.brand)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.brandFill(hovering ? 0.18 : 0.10)))
                .overlay(Circle().strokeBorder(Theme.brand.opacity(0.35), lineWidth: 0.8))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// lulu-lumei-dock 品牌标：紫金渐变圆角块 + 金色「Lu」描边（与 Dock 图标同源的 LuluMark）。
/// 侧栏底部品牌区 / 设置→关于 卡片共用，按 size 等比缩放。
///
/// 比例**全部照 `AppIconView` 的 1024 母版换算**（`IconRenderer.swift:44-95`），
/// 以前这里是另一套手调数值：字标只占 `0.42` 字高（母版是 `430/824 ≈ 0.522`），
/// 金色是纯色而非三段渐变，也没有左上白高光与投影 —— 放大后就是一块扁方块。
///
/// 唯二不照抄的地方（且都有理由）：
///  - 高光描边与投影按母版换算是 `0.007×size` / `0.034×size`，在 26pt 上不到 0.2pt，
///    2x 屏也画不出一条线 → 给下限并按 size 放大到肉眼可辨；
///  - 母版的 824 底板外还有 100px 透明留白（阴影画在留白里），这里 `size` 就是底板本身。
struct LuluLogoTile: View {
    var size: CGFloat = 26

    /// 母版：字高 430 / 底板 824
    private var glyphHeight: CGFloat { size * 0.522 }
    /// 母版：笔画粗 = 字高 / φ³
    private var stroke: CGFloat { max(1, glyphHeight * 0.2361) }
    private var corner: CGFloat { size * 0.2237 }

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.55, blue: 0.96),
                        Color(red: 0.36, green: 0.36, blue: 0.89),
                        Color(red: 0.16, green: 0.13, blue: 0.45),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            // 中心暖金柔光，托起金色字标（母版 640/824 直径、300/824 半径）
            .overlay(
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(red: 1.0, green: 0.9, blue: 0.6).opacity(0.18), .clear,
                            ],
                            center: .center, startRadius: 0, endRadius: size * 0.364))
                    .frame(width: size * 0.777, height: size * 0.777))
            .overlay(
                LuluMark()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 0.98, green: 0.87, blue: 0.55),
                                Color(red: 0.89, green: 0.74, blue: 0.38),
                                Color(red: 0.76, green: 0.58, blue: 0.18),
                            ],
                            startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(
                            lineWidth: stroke, lineCap: .round, lineJoin: .round))
                    // 宽度给满：LuluMark 自己按 rect 水平居中（母版也是给满底板宽）
                    .frame(width: size, height: glyphHeight)
                    .shadow(
                        color: Color(red: 0.10, green: 0.07, blue: 0.30).opacity(0.45),
                        radius: size * 0.035, y: size * 0.025))
            // 左上白高光描边：把平面染色块变成有厚度的实体
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.42), .white.opacity(0.02)],
                            startPoint: .top, endPoint: .bottom),
                        lineWidth: max(0.75, size * 0.015)))
            .shadow(color: .black.opacity(0.28), radius: size * 0.045, y: size * 0.022)
    }
}

// MARK: - 知识库统一列表行（列表模式共用，对标会话页 SessionRow）

/// 通栏精致行：内容槽（左 logo + 两行文字 + 右侧状态）+ 悬停浮现动作；
/// 悬停高亮 + 左缘紫细条；整行点击进详情；右键菜单由调用方按各页语义传入。
/// content 内推荐布局：`HStack { 图标; VStack{ 标题行; 描述行 }; Spacer; 尾附件 }`。
struct KnowledgeRow<Content: View, Menu: View>: View {
    var enabled = true
    var actions: [CardAction] = []
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .opacity(enabled ? 1 : 0.6)
            .background(
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(hovering ? Theme.brandFill(0.06) : Color.clear)
                    if hovering {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Theme.brand)
                            .frame(width: 3)
                            .padding(.vertical, 5)
                    }
                })
            .overlay(alignment: .trailing) {
                if hovering, !actions.isEmpty {
                    KnowledgeCardActions(actions: actions)
                        .padding(.trailing, 8)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            .contextMenu { menu() }
    }
}

/// 列表模式分组容器：白卡圆角 + 细描边 + 柔和投影，把同一分区的行收进一张「表格」卡
/// （macOS 系统设置式分组列表）；分隔线由调用方按行内文字起始位置缩进。
struct KnowledgeListContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .fill(Theme.surface))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous)
                    .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous))
            .shadow(
                color: ThemeStyle.current == .raft ? .clear : .black.opacity(0.05),
                radius: ThemeStyle.current == .raft ? 0 : 3,
                y: ThemeStyle.current == .raft ? 0 : 1.5)
            .themeCardShadow()
    }
}

// MARK: - 紫金改版：统计概览卡 / 来源筛选 chips / 流式布局

/// 换行流式布局（chips 超宽自动折行；macOS 13+ Layout 协议）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 10
    var lineSpacing: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(maxWidth, widest), height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 顶部统计概览卡：左「大数 + 单位 + 副标题」，竖分隔线，右「分布标题 + 可选堆叠段条 + 图例」。
/// 四页共用；Agents 传 `showBar: false`（只有模型分布图例，无条）。结构性颜色只用语义/品牌色。
struct StatOverviewCard: View {
    struct Segment: Identifiable {
        let id = UUID()
        let label: String
        let count: Int
        let color: Color
    }

    let value: String
    let unit: String
    var subtitle: String?
    let distributionTitle: String
    let segments: [Segment]
    var showBar = true
    var trailingNote: String?

    private var total: Int { max(1, segments.reduce(0) { $0 + $1.count }) }

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(Theme.font.statNumber(28))
                    Text(unit).font(Theme.font.themed(12.5, .medium)).foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(Theme.font.themedMono(11)).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 46)

            VStack(alignment: .leading, spacing: 9) {
                Text(distributionTitle)
                    .font(Theme.font.themed(12, .semibold))
                    .foregroundStyle(.secondary)
                if showBar {
                    GeometryReader { geo in
                        HStack(spacing: 1.5) {
                            ForEach(segments.filter { $0.count > 0 }) { seg in
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(seg.color)
                                    .frame(width: barWidth(seg, in: geo.size.width))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipShape(Capsule())
                    }
                    .frame(height: 8)
                }
                HStack(spacing: 14) {
                    ForEach(segments) { seg in
                        HStack(spacing: 5) {
                            Circle().fill(seg.color).frame(width: 8, height: 8)
                            Text(seg.label).font(Theme.font.themed(11)).foregroundStyle(.secondary)
                            Text("\(seg.count)")
                                .font(Theme.font.themedMono(11, .semibold))
                        }
                        // 兜底：图例条目过多时宁可整体溢出裁掉，也不能让「命令」「16,911」
                        // 逐字竖着折成一列（审计页 9 个 ToolKind 曾真实撞出这个形态）。
                        // 收口是调用方的责任（照 AgentsView 折成「前 4 + 其他」）。
                        .lineLimit(1)
                        .fixedSize()
                    }
                    Spacer(minLength: 8)
                    if let trailingNote {
                        Text(trailingNote).font(Theme.font.themedMono(11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius.card)
                .fill(Theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius.card)
                        .strokeBorder(Theme.cardBorder, lineWidth: Theme.cardBorderWidth))
                .themeCardShadow())
        .shadow(
            color: ThemeStyle.current == .raft ? .clear : .black.opacity(0.05),
            radius: ThemeStyle.current == .raft ? 0 : 2,
            y: ThemeStyle.current == .raft ? 0 : 1)
    }

    private func barWidth(_ seg: Segment, in width: CGFloat) -> CGFloat {
        let usable = width - CGFloat(max(0, segments.filter { $0.count > 0 }.count - 1)) * 1.5
        return max(3, usable * CGFloat(seg.count) / CGFloat(total))
    }
}

/// 来源筛选 chip：nil = 全部（用页内图标）；否则显来源 logo + 名 + 数。
/// 选中 = 品牌紫底白字；未选 = 白底细边、悬停微染。
struct SourceFilterChip: View {
    var source: AgentSource?
    var allIcon: String
    let label: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                if let source {
                    SourceBadge(source: source, size: 14)
                } else {
                    Image(systemName: allIcon).font(.system(size: 11, weight: .semibold))
                }
                Text(label)
                    .font(Theme.font.themed(11.5, isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(Theme.font.themedMono(10.5, .medium))
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.onBrand.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? Theme.onBrand : (hovering ? .primary : .secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(hovering ? Theme.brandFill(0.06) : Theme.surface)))
            .overlay(
                Capsule().strokeBorder(
                    ThemeStyle.current == .raft
                        ? Theme.ink
                        : (isSelected ? Color.clear : Theme.cardBorder),
                    lineWidth: ThemeStyle.current == .raft ? 2 : 0.8))
            .themeControlShadow(active: isSelected)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 来源筛选条：「全部」+ 各来源 chips（换行）。绑定 selectedSource（nil=全部），再点选中项取消。
struct SourceFilterBar: View {
    @Binding var selected: AgentSource?
    let allLabel: String
    let allIcon: String
    let totalCount: Int
    let sources: [AgentSource]
    let count: (AgentSource) -> Int

    var body: some View {
        FlowLayout(spacing: 10, lineSpacing: 10) {
            SourceFilterChip(
                source: nil, allIcon: allIcon, label: allLabel,
                count: totalCount, isSelected: selected == nil
            ) { selected = nil }
            ForEach(sources, id: \.self) { source in
                SourceFilterChip(
                    source: source, allIcon: allIcon, label: source.displayName,
                    count: count(source), isSelected: selected == source
                ) { selected = (selected == source ? nil : source) }
            }
        }
    }
}

// MARK: - 紫金改版：进度环 / 进度条 / 范围徽标 / 角色头像 / 角色标签 / 模型芯片

/// Plans 列表行进度条：灰轨 + 紫填充（固定宽度胶囊；% 文字由调用方另附）。
struct PlanProgressBar: View {
    let progress: Double
    var width: CGFloat = 88

    var body: some View {
        Capsule().fill(Theme.hairline)
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(Theme.brand)
                    .frame(width: max(3, width * progress), height: 6)
            }
    }
}

/// Memory 范围徽标：全局=紫描边 / 项目=金描边（描边胶囊，无实底）。
struct ScopeBadge: View {
    let isGlobal: Bool

    var body: some View {
        let tint = isGlobal ? Theme.brand : Theme.gold
        Text(isGlobal ? "全局" : "项目")
            .font(Theme.font.themed(9.5, .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1))
    }
}

/// 终端归属标签：「iTerm2 · ttys004」。与 ScopeBadge 同一套胶囊描边规格。
///
/// 探测来源（`origin == .probe`）用虚线描边并在 tooltip 里说明精度较低 —— 那是按 cwd
/// 匹配进程上溯推出来的，不像 hook 那样确定；不该让用户误以为两者一样可靠。
struct TerminalBadge: View {
    let binding: TerminalBinding
    /// 终端应用当前是否还在运行（决定要不要显示成"已退出"的灰态）
    var isRunning: Bool = true

    var body: some View {
        let tint: Color = isRunning ? Theme.brand : .secondary
        HStack(spacing: 3) {
            Image(systemName: "terminal")
                .font(.system(size: 8, weight: .semibold))
            Text(binding.displayName)
                .font(Theme.font.themed(9.5, .medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay {
            let shape = Capsule()
            if binding.origin == .probe {
                shape.strokeBorder(
                    tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
            } else {
                shape.strokeBorder(tint.opacity(0.6), lineWidth: 1)
            }
        }
        .help(helpText)
    }

    private var helpText: String {
        var lines = [binding.origin == .probe
            ? "按工作目录匹配运行中的进程推断（精度低于 hook 采集）"
            : "由 hook 在会话所在终端内采集"]
        if let tty = binding.tty { lines.append("终端设备 \(tty)") }
        if !isRunning { lines.append("该终端应用当前未在运行") }
        return lines.joined(separator: "\n")
    }
}

/// Agents 角色方块：与 SourceLogoTile 同一套方块规格（紫底浅框圆角方块），内容换成角色单字
/// （通/探/实/审/规/建/文）。四页的方块形状 / 线条 / 配色因此完全一致；角色色只留在 RoleTag 上。
struct RoleAvatar: View {
    let role: AgentRole
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(TileSpec.fill(Theme.brand))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(
                        ThemeStyle.current == .raft ? Theme.ink : TileSpec.border(Theme.brand),
                        lineWidth: ThemeStyle.current == .raft ? 1.5 : 0.5))
            .overlay(
                Text(role.glyph)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(Theme.brand))
    }
}

/// Agents 角色标签：角色色浅底小胶囊。
struct RoleTag: View {
    let role: AgentRole

    var body: some View {
        let color = Theme.roleColor(role)
        Text(role.displayName)
            .font(Theme.font.themed(9.5, .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// Agents 模型芯片：中性灰底小胶囊显规整后的模型名。
struct ModelChip: View {
    let model: String

    var body: some View {
        Text(model)
            .font(Theme.font.themed(10, .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.surfaceSecondary))
    }
}
