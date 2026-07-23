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
                            .strokeBorder(Theme.cardBorder, lineWidth: 0.5)
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
                RoundedRectangle(cornerRadius: Theme.radius.sidebar).fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand.gradient)
                        : AnyShapeStyle(hovering ? Color.primary.opacity(0.06) : .clear))
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
                                   : (hovering ? Theme.brand.opacity(0.35) : Theme.cardBorder),
                        lineWidth: isSelected ? 1 : 0.5))
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
        .overlay(Capsule(style: .continuous).strokeBorder(Theme.cardBorder, lineWidth: 0.5))
    }
}

/// 知识库统一卡片壳：中性底 + 卡片圆角 + 悬停描边；停用态整卡变淡；**无色脊**；
/// 整卡点击进详情；操作按钮默认隐藏、悬停时右下角淡入；右键菜单由调用方按各页语义传入。
/// content 内推荐布局：`标题行(图标+名+尾附件) → 描述/副标题 → Spacer → meta 行`。
struct KnowledgeCard<Content: View, Menu: View>: View {
    var enabled = true
    var height: CGFloat = 108
    var actions: [CardAction] = []
    let onOpen: () -> Void
    @ViewBuilder var content: () -> Content
    @ViewBuilder var menu: () -> Menu

    @State private var hovering = false

    var body: some View {
        content()
            .padding(EdgeInsets(top: 13, leading: 14, bottom: 12, trailing: 13))
            .frame(height: height, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .fill(Theme.surface)
                    .opacity(enabled ? 1 : 0.6))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.radius.card)
                    .strokeBorder(
                        hovering ? Theme.brand.opacity(0.6) : Theme.cardBorder,
                        lineWidth: hovering ? 1 : 0.5))
            .overlay(alignment: .bottomTrailing) {
                if hovering, !actions.isEmpty {
                    KnowledgeCardActions(actions: actions)
                        .padding(7)
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.card))
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
            .font(.system(size: 9, weight: .medium))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let hint {
                Text(hint)
                    .font(.system(size: 10))
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

/// 统一搜索框：紫色放大镜 + 清空按钮 + 聚焦时紫金渐变描边（沿用会话页 searchPanel 观感，
/// 但不含来源选择器——四页来源筛选由统计瓦片行承担）。
struct SearchField: View {
    let placeholder: String
    @Binding var text: String
    var scanning = false

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(focused ? AnyShapeStyle(Theme.brand) : AnyShapeStyle(.tertiary))
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .focused($focused)
            if scanning { ProgressView().controlSize(.mini) }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("清空搜索")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surface))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.brand.opacity(focused ? 1 : 0.45),
                                 Theme.gold.opacity(focused ? 1 : 0.45)],
                        startPoint: .leading, endPoint: .trailing),
                    lineWidth: focused ? 1.2 : 0.8))
        .shadow(color: focused ? Theme.brand.opacity(0.12) : .clear, radius: 4, y: 1)
        .animation(.easeOut(duration: 0.15), value: focused)
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
                        .font(.system(size: 12, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Theme.surfaceSecondary))
                    if let trailingNote {
                        Text(trailingNote)
                            .font(.system(size: 10))
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
                                .strokeBorder(Theme.cardBorder, lineWidth: 0.5)))
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
                    .strokeBorder(TileSpec.border(Theme.brand), lineWidth: 0.5))
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
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
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
                .font(.system(size: 9.5, weight: .medium))
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
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5))
                .contentShape(RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

// MARK: - 布局切换（卡片 / 列表；Skills / Memory / Plans / Agents 四页共用）

/// 知识库视图模式：卡片网格 / 通栏列表
enum KnowledgeLayout: String, CaseIterable {
    case cards = "卡片"
    case list = "列表"
    var icon: String { self == .cards ? "square.grid.2x2" : "list.bullet" }
}

/// 顶部工具条右侧的「卡片 / 列表」分段切换（与全站分段控件同款）
struct LayoutToggle: View {
    @Binding var layout: KnowledgeLayout

    var body: some View {
        CapsuleTabTray {
            ForEach(KnowledgeLayout.allCases, id: \.self) { item in
                CapsuleTabButton(
                    title: item.rawValue, icon: item.icon, fillWidth: false,
                    isSelected: layout == item
                ) { layout = item }
            }
        }
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
            .padding(.vertical, 9)
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
