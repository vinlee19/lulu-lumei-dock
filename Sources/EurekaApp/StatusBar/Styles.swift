import EurekaIngest
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

/// 知识库统一卡片壳：中性底 + 卡片圆角 + 柔和投影 + 悬停描边；停用态整卡变淡；**无色脊**；
/// 整卡点击进详情；操作按钮默认隐藏、悬停时右下角淡入；右键菜单由调用方按各页语义传入。
/// content 内推荐布局：`标题行(图标+名+尾附件) → 描述/副标题 → Spacer → meta 行`。
struct KnowledgeCard<Content: View, Menu: View>: View {
    var enabled = true
    /// 最小高度：0 = 随内容自适应（网格同行自动等高），避免固定高度造成中部空洞
    var minHeight: CGFloat = 0
    /// 左侧色脊（Memory 按范围染色：全局紫 / 项目金）；nil = 无脊（默认）
    var leadingEdge: Color? = nil
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
            .overlay(alignment: .leading) {
                if let leadingEdge {
                    Rectangle().fill(leadingEdge).frame(width: 3)
                }
            }
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
            .shadow(color: .black.opacity(0.06), radius: 3, y: 1.5)
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

/// 知识库视图模式：通栏列表 / 图标（卡片网格）。顺序即分段控件顺序（列表在左，默认）。
enum KnowledgeLayout: String, CaseIterable {
    case list = "列表"
    case cards = "图标"
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
/// 侧栏头部 / 侧栏底部 / 设置→关于 卡片共用，按 size 等比缩放。
struct LuluLogoTile: View {
    var size: CGFloat = 18

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color(red: 0.55, green: 0.55, blue: 0.96),
                        Color(red: 0.36, green: 0.36, blue: 0.89),
                        Color(red: 0.16, green: 0.13, blue: 0.45),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                LuluMark()
                    .stroke(Theme.gold, style: StrokeStyle(
                        lineWidth: max(1, size * 0.1), lineCap: .round, lineJoin: .round))
                    .frame(width: size * 0.66, height: size * 0.42)
            )
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
                    .strokeBorder(Theme.cardBorder, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius.container, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 3, y: 1.5)
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
                    Text(unit).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11).monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
            .frame(minWidth: 120, alignment: .leading)

            Rectangle().fill(Theme.hairline).frame(width: 1, height: 46)

            VStack(alignment: .leading, spacing: 9) {
                Text(distributionTitle)
                    .font(.system(size: 12, weight: .semibold))
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
                            Text(seg.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            Text("\(seg.count)")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }
                    }
                    Spacer(minLength: 8)
                    if let trailingNote {
                        Text(trailingNote).font(.system(size: 11).monospacedDigit())
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
                        .strokeBorder(Theme.cardBorder, lineWidth: 0.5)))
        .shadow(color: .black.opacity(0.05), radius: 2, y: 1)
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
                    .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85))
                                                : AnyShapeStyle(.secondary))
            }
            .foregroundStyle(isSelected ? .white : (hovering ? .primary : .secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.brand)
                        : AnyShapeStyle(hovering ? Theme.brandFill(0.06) : Theme.surface)))
            .overlay(
                Capsule().strokeBorder(
                    isSelected ? Color.clear : Theme.cardBorder, lineWidth: 0.8))
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

/// Plans 图标卡进度环：完成→绿满环+✓；文档→金文档图标；否则紫弧 + 中心 %（草稿 0 灰）。
struct ProgressRing: View {
    let status: PlanMaterializer.PlanStatus
    let progress: Double?
    var size: CGFloat = 44

    private let lineWidth: CGFloat = 3.5

    var body: some View {
        ZStack {
            Circle().stroke(Theme.hairline, lineWidth: lineWidth)
            content
        }
        .padding(lineWidth / 2)
        .frame(width: size, height: size)
    }

    @ViewBuilder private var content: some View {
        switch status {
        case .complete:
            Circle().stroke(Theme.enabledGreen, lineWidth: lineWidth)
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(Theme.enabledGreen)
        case .document:
            Image(systemName: "doc.text")
                .font(.system(size: size * 0.34))
                .foregroundStyle(Theme.gold)
        case .draft, .inProgress:
            let fraction = progress ?? 0
            Circle()
                .trim(from: 0, to: max(0.0001, fraction))
                .stroke(Theme.brand, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))")
                .font(.system(size: size * 0.3, weight: .bold).monospacedDigit())
                .foregroundStyle(status == .draft ? AnyShapeStyle(.secondary) : AnyShapeStyle(Theme.brand))
        }
    }
}

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
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(tint.opacity(0.65), lineWidth: 1))
    }
}

/// Agents 角色头像：角色色浅底圆角方块 + 角色单字（通/探/实/审/规/建/文）。
struct RoleAvatar: View {
    let role: AgentRole
    var size: CGFloat = 28

    var body: some View {
        let color = Theme.roleColor(role)
        RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
            .fill(color.opacity(0.14))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: TileSpec.radius(size), style: .continuous)
                    .strokeBorder(color.opacity(0.18), lineWidth: 0.5))
            .overlay(
                Text(role.glyph)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(color))
    }
}

/// Agents 角色标签：角色色浅底小胶囊。
struct RoleTag: View {
    let role: AgentRole

    var body: some View {
        let color = Theme.roleColor(role)
        Text(role.displayName)
            .font(.system(size: 9.5, weight: .medium))
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
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Theme.surfaceSecondary))
    }
}
