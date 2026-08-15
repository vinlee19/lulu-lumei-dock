import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// 界面风格：classic = 经典靛紫金（默认）/ brutal = 新粗野主义 Neo-Brutalism
///（奶油底、2px 墨色描边、零模糊硬阴影、Space Grotesk/Mono 字体、平色不用渐变；
/// 视觉参考 raft.build 的 brutalist 设计语言）。
/// 其余枚举值是**配色主题**（GitHub 社区高 star 配色生态，官方 palette、MIT/Apache 许可）：
/// 结构随 classic（圆角/柔影/细边不变），只换颜色。
/// 用户偏好在 设置 → 通用 切换，存 AppSettings.themeStyle。
enum ThemeStyle: String {
    case classic
    case brutal
    case catppuccin
    case gruvbox
    case nord
    case solarized
    case rosepine
    case onedark
    case kanagawa

    /// 当前风格。仅主线程读写（AppSettings didSet 与 SwiftUI body 求值都在主线程），
    /// 与本文件其余静态成员同等处理。切风格后由根视图 .id 强制整树重建、重新取值。
    static var current: ThemeStyle = .classic

    /// 解析持久化 / CLI 传入的风格 id；「raft」是 0.20.x 短暂使用过的旧 id，兼容映射。
    static func resolve(_ raw: String) -> ThemeStyle {
        ThemeStyle(rawValue: raw) ?? (raw == "raft" ? .brutal : .classic)
    }

    /// 是否主题化风格（classic 之外；颜色全部走各派 token）
    var isThemed: Bool { self != .classic }

    /// 是否结构派（硬边/平色/硬影）。配色主题返回 false —— 结构随 classic，只换颜色
    var isHardEdged: Bool { self == .brutal }
}

/// 配色主题 palette（hex 浅色 / 深色；结构随 classic，只换颜色）。
private struct ThemePalette {
    var windowBackground: (String, String)
    var surface: (String, String)
    var surfaceSecondary: (String, String)
    var surfaceTertiary: (String, String)
    var cardBorder: (String, String)
    var brand: (String, String)
    var gold: (String, String)
    var ink: (String, String)
    var onBrand: (String, String)
    var green: (String, String)
    var red: (String, String)
    var warn: (String, String)
}

/// 全局设计令牌：品牌强调色、语义状态色、中性底色、间距。
/// UI 颜色/间距统一从这里取，避免同一语义在各视图各写一套。
/// 多主题机制：token 按 ThemeStyle.current 派发；classic 分支保持「紫金」稿原值逐字不变。
enum Theme {
    // MARK: - 配色主题 palette 表（官方 palette 值；dark 列为该主题的官方暗色风味）

    private static let palettes: [ThemeStyle: ThemePalette] = [
        // Catppuccin：Latte（浅）/ Mocha（深）
        .catppuccin: ThemePalette(
            windowBackground: ("EFF1F5", "1E1E2E"), surface: ("FFFFFF", "313244"),
            surfaceSecondary: ("E6E9EF", "292C3C"), surfaceTertiary: ("DCE0E8", "181825"),
            cardBorder: ("CCD0DA", "45475A"),
            brand: ("8839EF", "CBA6F7"), gold: ("FE640B", "FAB387"),
            ink: ("4C4F69", "CDD6F4"), onBrand: ("FFFFFF", "11111B"),
            green: ("40A02B", "A6E3A1"), red: ("D20F39", "F38BA8"), warn: ("DF8E1D", "F9E2AF")),
        // Gruvbox：light / dark
        .gruvbox: ThemePalette(
            windowBackground: ("FBF1C7", "282828"), surface: ("F9F5D7", "3C3836"),
            surfaceSecondary: ("EBDBB2", "32302F"), surfaceTertiary: ("D5C4A1", "282828"),
            cardBorder: ("D5C4A1", "504945"),
            brand: ("B16286", "D3869B"), gold: ("D65D0E", "FE8019"),
            ink: ("3C3836", "EBDBB2"), onBrand: ("FBF1C7", "282828"),
            green: ("98971A", "B8BB26"), red: ("CC241D", "FB4934"), warn: ("D79921", "FABD2F")),
        // Nord：Snow Storm（浅）/ Polar Night（深）
        .nord: ThemePalette(
            windowBackground: ("ECEFF4", "2E3440"), surface: ("FFFFFF", "3B4252"),
            surfaceSecondary: ("E5E9F0", "434C5E"), surfaceTertiary: ("D8DEE9", "2E3440"),
            cardBorder: ("D8DEE9", "4C566A"),
            brand: ("5E81AC", "81A1C1"), gold: ("D08770", "D08770"),
            ink: ("2E3440", "D8DEE9"), onBrand: ("ECEFF4", "2E3440"),
            green: ("A3BE8C", "A3BE8C"), red: ("BF616A", "BF616A"), warn: ("D08770", "D08770")),
        // Solarized：light / dark（同一组低对比强调色）
        .solarized: ThemePalette(
            windowBackground: ("EEE8D5", "002B36"), surface: ("FDF6E3", "073642"),
            surfaceSecondary: ("E8E0C8", "073642"), surfaceTertiary: ("EEE8D5", "002B36"),
            cardBorder: ("DDD6C1", "586E75"),
            brand: ("268BD2", "268BD2"), gold: ("CB4B16", "CB4B16"),
            ink: ("657B83", "839496"), onBrand: ("FDF6E3", "002B36"),
            green: ("859900", "859900"), red: ("DC322F", "DC322F"), warn: ("B58900", "B58900")),
        // Rosé Pine：Dawn（浅）/ Main（深）
        .rosepine: ThemePalette(
            windowBackground: ("FAF4ED", "191724"), surface: ("FFFAF3", "1F1D2E"),
            surfaceSecondary: ("F2E9E1", "26233A"), surfaceTertiary: ("F4EDE8", "191724"),
            cardBorder: ("DFDAD9", "26233A"),
            brand: ("907AA9", "C4A7E7"), gold: ("EA9D34", "F6C177"),
            ink: ("575279", "E0DEF4"), onBrand: ("FAF4ED", "191724"),
            green: ("286983", "31748F"), red: ("B4637A", "EB6F92"), warn: ("EA9D34", "F6C177")),
        // One Dark / One Light（Atom 遗产）
        .onedark: ThemePalette(
            windowBackground: ("FAFAFA", "282C34"), surface: ("FFFFFF", "2C313A"),
            surfaceSecondary: ("F0F0F0", "21252B"), surfaceTertiary: ("EAEAEA", "282C34"),
            cardBorder: ("E0E0E0", "3B4048"),
            brand: ("4078F2", "61AFEF"), gold: ("C18401", "E5C07B"),
            ink: ("383A42", "ABB2BF"), onBrand: ("FAFAFA", "282C34"),
            green: ("50A14F", "98C379"), red: ("E45649", "E06C75"), warn: ("986801", "D19A66")),
        // Kanagawa：Lotus（浅）/ Wave（深），浮世绘调
        .kanagawa: ThemePalette(
            windowBackground: ("F2ECBC", "1F1F28"), surface: ("FAF3D2", "2A2A37"),
            surfaceSecondary: ("E5DDB0", "232329"), surfaceTertiary: ("DCD5A8", "16161D"),
            cardBorder: ("D5CEA3", "363646"),
            brand: ("4D699B", "7E9CD8"), gold: ("CC6D00", "FFA066"),
            ink: ("545464", "DCD7BA"), onBrand: ("F2ECBC", "1F1F28"),
            green: ("6F894E", "98BB6C"), red: ("C84053", "E46876"), warn: ("77713F", "FF9E3B")),
    ]

    // MARK: - 品牌强调色

    /// 主强调色：classic = 靛紫（取自 App 图标，深色模式自动提亮）；brutal = cyan；配色主题 = 各派 brand
    static var brand: Color {
        switch ThemeStyle.current {
        case .classic: return classicBrand
        case .brutal: return Color(hex: "27CCF3")  // 深浅色同值，奶油/暗底上都成立
        default: return themedColor(\.brand)
        }
    }

    private static let classicBrand = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.55, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.89, alpha: 1)
    }))

    /// 辅助强调色：classic = 金（取自 App 图标）；brutal = pink；配色主题 = 各派 gold
    static var gold: Color {
        switch ThemeStyle.current {
        case .classic: return classicGold
        case .brutal: return Color(hex: "FE7DA8")
        default: return themedColor(\.gold)
        }
    }

    private static let classicGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.89, green: 0.74, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.62, blue: 0.15, alpha: 1)
    }))

    /// 强调色文字档：细字 / 图标前景用（色块底继续用 brand / gold 本体）。
    /// brutal 的荧光 cyan/pink 在奶油底上只有 1.8–2.4:1，做前景必须加深到 ≥4.5:1；
    /// classic / 配色主题与本体同值（逐像素不变），brutal 深色本体已达标、沿用。
    static var brandFg: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("0E7490"), dark: hexRGB("27CCF3"))
            : brand
    }

    static var goldFg: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("C2185B"), dark: hexRGB("FE7DA8"))
            : gold
    }

    /// 金额蓝：classic / 配色主题恒系统蓝（沿用既有约定）；
    /// brutal 用平色钴蓝（浅 6.7:1 / 深 5.8:1，与 cyan 品牌色拉开色距）。
    static var cost: Color {
        ThemeStyle.current == .brutal
            ? dynamic(light: hexRGB("1D4ED8"), dark: hexRGB("6C9EF8"))
            : .blue
    }

    /// 墨色：brutal 的描边 / 硬阴影 / 强调字色（浅色 #141111、深色奶油 #FFFAEF）。
    /// 配色主题里 ink = 各派正文前景色（选中描边等场景用）。
    static var ink: Color {
        switch ThemeStyle.current {
        case .classic: return classicCardBorder
        case .brutal: return dynamic(light: hexRGB("141111"), dark: hexRGB("FFFAEF"))
        default: return themedColor(\.ink)
        }
    }

    /// 紫金渐变：色脊 / 徽标底统一从这里取（勿在各视图手写）。
    /// brutal 不用渐变：退化为墨色平色；配色主题保留 brand→gold 渐变（各派自有色）。
    static var purpleGoldGradient: LinearGradient {
        switch ThemeStyle.current {
        case .brutal:
            return LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(colors: [brand, gold], startPoint: .top, endPoint: .bottom)
        }
    }

    /// 品牌小方块渐变（Indigo Light → brand → Indigo Deep，左上→右下）。
    /// 24pt 级小方块用：紫金竖向渐变在这个尺寸会糊成橄榄色，故小方块只走紫色系，金留给描边环。
    /// 非 classic 风格退化为品牌平色。
    static var brandTileGradient: LinearGradient {
        switch ThemeStyle.current {
        case .classic:
            return LinearGradient(
                colors: [Color(hex: "8C8CF5"), brand, Color(hex: "4A45C9")],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        default:
            return LinearGradient(
                colors: [brand, brand],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// 图表柱渐变（#8C8CF5 → #5C5CE3，自上而下；近 30 天调用柱状图用）。
    /// 非 classic 风格退化为品牌平色。
    static var chartBarGradient: LinearGradient {
        switch ThemeStyle.current {
        case .classic:
            return LinearGradient(
                colors: [
                    Color(.sRGB, red: 0.55, green: 0.55, blue: 0.96, opacity: 1),
                    Color(.sRGB, red: 0.36, green: 0.36, blue: 0.89, opacity: 1),
                ],
                startPoint: .top, endPoint: .bottom)
        default:
            return LinearGradient(
                colors: [brand, brand],
                startPoint: .top, endPoint: .bottom)
        }
    }

    // MARK: - 语义状态色（收编全仓重复 switch）

    /// 启用绿
    static var enabledGreen: Color {
        switch ThemeStyle.current {
        case .classic:
            return Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35, opacity: 1)
        case .brutal:  // brutal 绿（浅色压深到 5.0:1 保小字可读，深色提亮）
            return dynamic(light: hexRGB("3F7A25"), dark: hexRGB("A9D877"))
        default: return themedColor(\.green)
        }
    }
    /// 停用灰：classic / 配色主题 = 冷灰；brutal = 同明度暖灰（冷灰压暖奶油底显脏）
    static var disabledGray: Color {
        ThemeStyle.current.isHardEdged
            ? Color(hex: "DBD5C6")
            : Color(.sRGB, red: 0.86, green: 0.86, blue: 0.88, opacity: 1)
    }
    /// 失败红
    static var failureRed: Color {
        switch ThemeStyle.current {
        case .classic:
            return Color(.sRGB, red: 0.82, green: 0.27, blue: 0.23, opacity: 1)
        case .brutal:  // 浅色 #F97264 只有 2.8:1，压深；深色保留原珊瑚红
            return dynamic(light: hexRGB("C92A2A"), dark: hexRGB("F97264"))
        default: return themedColor(\.red)
        }
    }
    /// 自动清理灰：classic / 配色主题 = 冷灰；brutal = 同明度暖灰
    static var autoCleanGray: Color {
        ThemeStyle.current.isHardEdged
            ? Color(hex: "A49E90")
            : Color(.sRGB, red: 0.64, green: 0.64, blue: 0.66, opacity: 1)
    }
    /// 草稿灰（计划状态）：classic / 配色主题 = 冷灰 #CFCFD6；brutal = 同明度暖灰
    static var draftGray: Color {
        ThemeStyle.current.isHardEdged ? Color(hex: "CFC8B8") : Color(hex: "CFCFD6")
    }

    /// 警示橙
    private static var warnColor: Color {
        switch ThemeStyle.current {
        case .classic: return .orange
        case .brutal:  // 浅色压深到 4.8:1（#D96F32 仅 3.2:1），深色 #F8A16F
            return dynamic(light: hexRGB("B45309"), dark: hexRGB("F8A16F"))
        default: return themedColor(\.warn)
        }
    }

    /// 任务结局：成功绿 / 出错红 / 中断灰
    static func outcomeColor(_ outcome: TaskOutcome) -> Color {
        if ThemeStyle.current.isThemed {
            switch outcome {
            case .success: return enabledGreen
            case .error: return failureRed
            case .interrupted: return autoCleanGray
            }
        }
        switch outcome {
        case .success: return .green
        case .error: return .red
        case .interrupted: return .gray
        }
    }

    /// 风险等级配色。以前 `.red`/`.orange` 在 AuditView 里硬编了三处、彼此还不一致。
    static func riskColor(_ level: RiskLevel) -> Color {
        switch level {
        case .high: return failureRed
        case .notice: return goldFg  // 徽标细字场景，取文字档
        }
    }

    /// 用量占比阈值：<60 绿 / <85 橙 / 其余红（限额、ctx% 共用）
    static func percentColor(_ percent: Double) -> Color {
        if ThemeStyle.current.isThemed {
            switch percent {
            case ..<60: return enabledGreen
            case ..<85: return warnColor
            default: return failureRed
            }
        }
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// 接入安装状态
    static func installColor(_ status: InstallStatus) -> Color {
        if ThemeStyle.current.isThemed {
            switch status {
            case .installed: return enabledGreen
            case .partial, .foreign: return warnColor
            case .none: return autoCleanGray
            }
        }
        switch status {
        case .installed: return .green
        case .partial, .foreign: return .orange
        case .none: return .gray
        }
    }

    /// 数据源健康状态
    static func healthColor(_ status: HealthRegistry.Entry.Status) -> Color {
        if ThemeStyle.current.isThemed {
            switch status {
            case .ok: return enabledGreen
            case .degraded: return warnColor
            case .stalled: return failureRed
            case .idle: return autoCleanGray
            }
        }
        switch status {
        case .ok: return .green
        case .degraded: return .orange
        case .stalled: return .red
        case .idle: return .gray
        }
    }

    // MARK: - 中性底色

    /// 卡片底：classic = 系统 controlBackground；brutal = 白卡（深色 #28241F 暖灰）
    static var surface: Color {
        switch ThemeStyle.current {
        case .classic: return Color(nsColor: .controlBackgroundColor)
        case .brutal: return dynamic(light: hexRGB("FFFFFF"), dark: hexRGB("28241F"))
        default: return themedColor(\.surface)
        }
    }

    /// 分组头 / 工具条 / 悬浮底
    static var surfaceSecondary: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.05)
        case .brutal: return dynamic(light: hexRGB("F5EEDD"), dark: hexRGB("241F1A"))
        default: return themedColor(\.surfaceSecondary)
        }
    }

    /// 更浅的容器底（表格、日志区）
    static var surfaceTertiary: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.03)
        case .brutal: return dynamic(light: hexRGB("EFE7D2"), dark: hexRGB("201C17"))
        default: return themedColor(\.surfaceTertiary)
        }
    }

    /// 分隔线 / 细描边
    static var hairline: Color {
        switch ThemeStyle.current {
        case .classic: return Color.primary.opacity(0.08)
        case .brutal:
            return dynamicAlpha(light: hexRGBA("141111", 0.3), dark: hexRGBA("FFFAEF", 0.3))
        default:
            // 配色主题：各派正文色 12%（与 classic 的 primary 8% 同思路，只换色源）
            return ink.opacity(0.12)
        }
    }

    /// 卡片 / 方块描边：classic = 浅灰边（参考稿简约风）；brutal = 墨（深色 = 奶油）
    static var cardBorder: Color {
        switch ThemeStyle.current {
        case .classic: return classicCardBorder
        case .brutal: return ink
        default: return themedColor(\.cardBorder)
        }
    }

    private static let classicCardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)  // #E2E2E8
    }))

    /// 品牌色轻染填充（选中态 / 徽标 / 高亮行）
    static func brandFill(_ opacity: Double = 0.10) -> Color {
        brand.opacity(opacity)
    }

    // MARK: - 主题差异 token（classic 与配色主题取原行为，brutal 取结构派值）

    /// 卡片描边宽度：classic / 配色主题 0.5 细边；brutal 2px 墨边
    static var cardBorderWidth: CGFloat {
        ThemeStyle.current.isHardEdged ? 2 : 0.5
    }

    /// 卡片级阴影（brutal = 零模糊 4/4 墨影；其余 = nil，由组件里的经典柔影接管）。
    /// SwiftUI `.shadow(radius: 0)` 即零模糊硬影。
    static var cardShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 0, 4, 4) : nil
    }

    /// 小控件阴影（胶囊 / 按钮级；brutal = 2/2）
    static var controlShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 0, 2, 2) : nil
    }

    /// 控件描边（选中胶囊 / logo 方块 / 迷你开关的轮廓）：仅 brutal = 墨 2；
    /// 其余 = nil（各组件回退原逻辑）
    static var controlOutline: (color: Color, width: CGFloat)? {
        ThemeStyle.current.isHardEdged ? (ink, 2) : nil
    }

    /// 迷你开关圆头色：classic / 配色主题 = 白；brutal = 奶油
    static var controlKnob: Color {
        ThemeStyle.current.isHardEdged ? Color(hex: "FFFAEF") : .white
    }

    /// 选中态品牌底上的文字 / 图标色：classic = 白；brutal = 墨（配 cyan 底）
    static var onBrand: Color {
        switch ThemeStyle.current {
        case .classic: return .white
        case .brutal: return ink
        default: return themedColor(\.onBrand)
        }
    }

    /// 主窗口底色：classic = 透明（沿用系统窗口底）；brutal = 奶油（深色 = 暖黑）
    static var windowBackground: Color {
        switch ThemeStyle.current {
        case .classic: return .clear
        case .brutal: return dynamic(light: hexRGB("FFFAEF"), dark: hexRGB("171410"))
        default: return themedColor(\.windowBackground)
        }
    }

    // MARK: - 上下文用量类目色（会话详情页「上下文用量」卡片：堆叠条段 + 图例点共用）

    /// 五类目配色：classic / 配色主题 = 参考图青绿/黄/紫/浅蓝/蓝紫（深浅各一组）；
    /// brutal = 平色荧光系 cyan/黄/紫/蓝/绿（深浅同值，平色不渐变）。
    static func contextCategoryColor(_ category: ContextBreakdown.Category) -> Color {
        if ThemeStyle.current.isHardEdged {
            switch category {
            case .systemPrompt: return Color(hex: "27CCF3")  // cyan
            case .tools: return Color(hex: "F5C518")         // 黄
            case .messages: return Color(hex: "B98CFF")      // 紫
            case .mcp: return Color(hex: "6C9EF8")           // 蓝
            case .skills: return Color(hex: "A9D877")        // 绿
            }
        }
        switch category {
        case .systemPrompt: return dynamic(light: hexRGB("2FA98C"), dark: hexRGB("5CCBAD"))
        case .tools: return dynamic(light: hexRGB("D9A62E"), dark: hexRGB("E8C25C"))
        case .messages: return dynamic(light: hexRGB("7C5CFC"), dark: hexRGB("9D8AFA"))
        case .mcp: return dynamic(light: hexRGB("5BA8D9"), dark: hexRGB("7FC2E8"))
        case .skills: return dynamic(light: hexRGB("6B6BD6"), dark: hexRGB("8F8FE8"))
        }
    }

    // MARK: - 角色 / 计划状态语义色（紫金稿）

    /// 子代理角色标识色（palette「角色 · Agents」；实现=品牌紫，其余取 palette 固定值）
    static func roleColor(_ role: AgentRole) -> Color {
        switch role {
        case .general: return Color(hex: "8A8A90")
        case .explore: return Color(hex: "2A8FD4")
        case .implement: return brand
        case .review: return Color(hex: "B08A1E")
        case .plan: return Color(hex: "7A5CF0")
        case .model: return Color(hex: "C2762A")
        case .doc: return Color(hex: "2CA24A")
        }
    }

    /// 计划状态色：完成绿 / 进行紫 / 草稿灰 / 文档金（徽标细字场景，强调色取文字档）
    static func planStatusColor(_ status: PlanMaterializer.PlanStatus) -> Color {
        switch status {
        case .complete: return enabledGreen
        case .inProgress: return brandFg
        case .draft: return draftGray
        case .document: return goldFg
        }
    }

    // MARK: - 间距（Codex 式宽松留白：模块间大间距，卡片内舒适内边距；各风格一致）

    enum spacing {
        /// 模块（卡片/分组）之间的间距
        static let module: CGFloat = 22
        /// 页面内容边距
        static let page: CGFloat = 16
        /// 卡片内边距
        static let card: CGFloat = 16
        /// 列表行垂直内边距
        static let row: CGFloat = 9
        /// 行内元素间距
        static let item: CGFloat = 6
    }

    // MARK: - 圆角（classic 简约阶梯 14/10/8/8；brutal 小而硬 7/5/3/7；配色主题随 classic）

    enum radius {
        /// 卡片 / 大容器
        static var card: CGFloat { ThemeStyle.current.isHardEdged ? 7 : 14 }
        /// 小型容器（统计瓦片、内嵌面板）
        static var container: CGFloat { ThemeStyle.current.isHardEdged ? 5 : 10 }
        /// 小方块（logo 块 / 图标块）与侧栏导航项
        static var tile: CGFloat { ThemeStyle.current.isHardEdged ? 3 : 8 }
        /// 侧栏导航项
        static var sidebar: CGFloat { ThemeStyle.current.isHardEdged ? 7 : 8 }
    }

    // MARK: - 字号（classic / 配色主题 = SF 系统字体；brutal = Space Grotesk / Space Mono，尺寸不变）

    enum font {
        /// 页标题 14/700
        static var pageTitle: Font { themed(14, .bold) }
        /// 卡片标题 13.5/650（技能名等宽场景用 monoSkillName）
        static var cardTitle: Font { themed(13.5, .semibold) }
        /// 技能名等宽（classic / 配色主题 = SF Mono；brutal = Space Mono）
        static func monoSkillName(_ size: CGFloat = 13.5, weight: Font.Weight = .semibold) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }
        /// 正文 12.5
        static var body: Font { themed(12.5) }
        /// 次要 11
        static var secondary: Font { themed(11) }
        /// 标注 9.5–10
        static var caption: Font { themed(9.5) }
        /// 大数字 18–23/700 等宽数字
        static func statNumber(_ size: CGFloat = 18) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: .bold)
                : .system(size: size, weight: .bold).monospacedDigit()
        }

        /// 视图内联 `.font(.system(size:weight:))` 的主题化替换：
        /// classic / 配色主题原样返回系统字体（逐像素不变）；brutal 映射 Space Grotesk。
        static func themed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.grotesk(size, weight: weight)
                : .system(size: size, weight: weight)
        }

        /// 内联等宽数字字体的主题化替换：classic / 配色主题 = system + monospacedDigit；
        /// brutal = Space Mono。
        static func themedMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current.isHardEdged
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight).monospacedDigit()
        }
    }

    // MARK: - 私有工具

    /// 配色主题取色：查 palette 表并深/浅双套化
    private static func themedColor(_ key: KeyPath<ThemePalette, (String, String)>) -> Color {
        guard let pair = palettes[ThemeStyle.current]?[keyPath: key] else { return .primary }
        return dynamic(light: hexRGB(pair.0), dark: hexRGB(pair.1))
    }

    /// hex → sRGB 分量
    private static func hexRGB(_ hex: String) -> (r: Double, g: Double, b: Double) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return (Double((value >> 16) & 0xFF) / 255,
                Double((value >> 8) & 0xFF) / 255,
                Double(value & 0xFF) / 255)
    }

    private static func hexRGBA(_ hex: String, _ alpha: Double) -> (r: Double, g: Double, b: Double, a: Double) {
        let rgb = hexRGB(hex)
        return (rgb.r, rgb.g, rgb.b, alpha)
    }

    /// 深/浅双套色
    private static func dynamic(
        light: (r: Double, g: Double, b: Double), dark: (r: Double, g: Double, b: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: 1)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: 1)
        }))
    }

    /// 带 alpha 的深/浅双套色
    private static func dynamicAlpha(
        light: (r: Double, g: Double, b: Double, a: Double),
        dark: (r: Double, g: Double, b: Double, a: Double)
    ) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: dark.r, green: dark.g, blue: dark.b, alpha: dark.a)
                : NSColor(srgbRed: light.r, green: light.g, blue: light.b, alpha: light.a)
        }))
    }
}

extension Color {
    /// 从 `#RRGGBB` / `RRGGBB` / `#RRGGBBAA` 十六进制创建（便于精确落 palette 色值）。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b, a: Double
        if cleaned.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        } else {
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        }
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
