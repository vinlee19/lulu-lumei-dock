import EurekaIngest
import EurekaInstall
import EurekaKit
import SwiftUI

/// 界面风格：classic = 经典靛紫金（默认）/ raft = 硬朗新粗野风（参考 raft.build：
/// 奶油底、2px 墨色描边、零模糊硬阴影、Space Grotesk/Mono 字体、平色不用渐变）。
/// 用户偏好在 设置 → 通用 切换，存 AppSettings.themeStyle。
enum ThemeStyle: String {
    case classic
    case raft

    /// 当前风格。仅主线程读写（AppSettings didSet 与 SwiftUI body 求值都在主线程），
    /// 与本文件其余静态成员同等处理。切风格后由根视图 .id 强制整树重建、重新取值。
    static var current: ThemeStyle = .classic
}

/// 全局设计令牌：品牌强调色、语义状态色、中性底色、间距。
/// UI 颜色/间距统一从这里取，避免同一语义在各视图各写一套。
/// 多主题机制：token 按 ThemeStyle.current 派发；classic 分支保持「紫金」稿原值逐字不变。
enum Theme {
    // MARK: - 品牌强调色

    /// 主强调色：classic = 靛紫（取自 App 图标，深色模式自动提亮）；raft = brutal cyan
    static var brand: Color {
        ThemeStyle.current == .raft ? raftBrand : classicBrand
    }

    private static let classicBrand = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.55, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.89, alpha: 1)
    }))

    /// raft 主强调：brutal cyan #27CCF3（深浅色同值，奶油/暗底上都成立）
    private static let raftBrand = Color(hex: "27CCF3")

    /// 辅助强调色：classic = 金（取自 App 图标）；raft = brutal pink #FE7DA8
    static var gold: Color {
        ThemeStyle.current == .raft ? Color(hex: "FE7DA8") : classicGold
    }

    private static let classicGold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.89, green: 0.74, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.62, blue: 0.15, alpha: 1)
    }))

    /// 金额恒蓝（沿用既有约定，两种风格一致）
    static let cost = Color.blue

    /// 墨色：raft 的描边 / 硬阴影 / 强调字色。浅色 = #141111；深色 = 奶油 #FFFAEF
    ///（raft 深色主题以奶油作线条与阴影色，与其官网 .dark 一致）。
    static let ink = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1, green: 0.980, blue: 0.937, alpha: 1)      // #FFFAEF
            : NSColor(srgbRed: 0.078, green: 0.067, blue: 0.067, alpha: 1)  // #141111
    }))

    /// raft 奶油底：浅色 = #FFFAEF；深色 = 暖黑 #171410
    private static let raftCream = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.090, green: 0.078, blue: 0.063, alpha: 1)  // #171410
            : NSColor(srgbRed: 1, green: 0.980, blue: 0.937, alpha: 1)      // #FFFAEF
    }))

    /// 紫金渐变：色脊 / 徽标底统一从这里取（勿在各视图手写）。
    /// raft 不用渐变：退化为墨色平色（同色两端）。
    static var purpleGoldGradient: LinearGradient {
        if ThemeStyle.current == .raft {
            return LinearGradient(colors: [ink, ink], startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(colors: [brand, gold], startPoint: .top, endPoint: .bottom)
    }

    /// 品牌小方块渐变（Indigo Light → brand → Indigo Deep，左上→右下）。
    /// 24pt 级小方块用：紫金竖向渐变在这个尺寸会糊成橄榄色，故小方块只走紫色系，金留给描边环。
    /// raft 退化为 cyan 平色。
    static var brandTileGradient: LinearGradient {
        if ThemeStyle.current == .raft {
            return LinearGradient(
                colors: [raftBrand, raftBrand],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        return LinearGradient(
            colors: [Color(hex: "8C8CF5"), brand, Color(hex: "4A45C9")],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// 图表柱渐变（#8C8CF5 → #5C5CE3，自上而下；近 30 天调用柱状图用）。
    /// raft 退化为 cyan 平色。
    static var chartBarGradient: LinearGradient {
        if ThemeStyle.current == .raft {
            return LinearGradient(
                colors: [raftBrand, raftBrand],
                startPoint: .top, endPoint: .bottom)
        }
        return LinearGradient(
            colors: [
                Color(.sRGB, red: 0.55, green: 0.55, blue: 0.96, opacity: 1),
                Color(.sRGB, red: 0.36, green: 0.36, blue: 0.89, opacity: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 语义状态色（收编全仓重复 switch）

    /// 启用绿：classic = 原配方绿；raft = brutal lime（深色提亮）
    static var enabledGreen: Color {
        if ThemeStyle.current == .raft {
            return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.663, green: 0.847, blue: 0.467, alpha: 1)  // #A9D877
                    : NSColor(srgbRed: 0.306, green: 0.541, blue: 0.180, alpha: 1)  // #4E8A2E
            }))
        }
        return Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35, opacity: 1)
    }
    /// 停用灰（中性灰阶，两种风格一致）
    static let disabledGray = Color(.sRGB, red: 0.86, green: 0.86, blue: 0.88, opacity: 1)
    /// 失败红：classic = 原配方红；raft = brutal red #F97264
    static var failureRed: Color {
        ThemeStyle.current == .raft
            ? Color(hex: "F97264")
            : Color(.sRGB, red: 0.82, green: 0.27, blue: 0.23, opacity: 1)
    }
    /// 自动清理灰（中性灰阶，两种风格一致）
    static let autoCleanGray = Color(.sRGB, red: 0.64, green: 0.64, blue: 0.66, opacity: 1)
    /// 草稿灰（计划状态；palette #CFCFD6，两种风格一致）
    static let draftGray = Color(hex: "CFCFD6")

    /// raft 警示橙：浅色 #D96F32（奶油底上可读），深色 #F8A16F
    private static var raftOrange: Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.973, green: 0.631, blue: 0.435, alpha: 1)  // #F8A16F
                : NSColor(srgbRed: 0.851, green: 0.435, blue: 0.196, alpha: 1)  // #D96F32
        }))
    }

    /// 任务结局：成功绿 / 出错红 / 中断灰
    static func outcomeColor(_ outcome: TaskOutcome) -> Color {
        if ThemeStyle.current == .raft {
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
        case .notice: return gold
        }
    }

    /// 用量占比阈值：<60 绿 / <85 橙 / 其余红（限额、ctx% 共用）
    static func percentColor(_ percent: Double) -> Color {
        if ThemeStyle.current == .raft {
            switch percent {
            case ..<60: return enabledGreen
            case ..<85: return raftOrange
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
        if ThemeStyle.current == .raft {
            switch status {
            case .installed: return enabledGreen
            case .partial, .foreign: return raftOrange
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
        if ThemeStyle.current == .raft {
            switch status {
            case .ok: return enabledGreen
            case .degraded: return raftOrange
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

    /// 卡片底：classic = 系统 controlBackground；raft = 白卡（深色 = #28241F 暖灰）
    static var surface: Color {
        if ThemeStyle.current == .raft {
            return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.157, green: 0.141, blue: 0.122, alpha: 1)  // #28241F
                    : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)              // #FFFFFF
            }))
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    /// 分组头 / 工具条 / 悬浮底：classic = primary 5%；raft = 深一号奶油 #F5EEDD
    static var surfaceSecondary: Color {
        if ThemeStyle.current == .raft {
            return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.141, green: 0.122, blue: 0.102, alpha: 1)  // #241F1A
                    : NSColor(srgbRed: 0.961, green: 0.933, blue: 0.867, alpha: 1)  // #F5EEDD
            }))
        }
        return Color.primary.opacity(0.05)
    }

    /// 更浅的容器底（表格、日志区）：classic = primary 3%；raft = #EFE7D2
    static var surfaceTertiary: Color {
        if ThemeStyle.current == .raft {
            return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0.125, green: 0.110, blue: 0.090, alpha: 1)  // #201C17
                    : NSColor(srgbRed: 0.937, green: 0.906, blue: 0.824, alpha: 1)  // #EFE7D2
            }))
        }
        return Color.primary.opacity(0.03)
    }

    /// 分隔线 / 细描边：classic = primary 8%；raft = 墨 30%（深色 = 奶油 30%）
    static var hairline: Color {
        if ThemeStyle.current == .raft {
            return Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 1, green: 0.980, blue: 0.937, alpha: 0.3)
                    : NSColor(srgbRed: 0.078, green: 0.067, blue: 0.067, alpha: 0.3)
            }))
        }
        return Color.primary.opacity(0.08)
    }

    /// 卡片 / 方块描边：classic = 浅灰边（参考稿简约风）；raft = 2px 墨色实边（深色 = 奶油）
    static var cardBorder: Color {
        ThemeStyle.current == .raft ? ink : classicCardBorder
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

    // MARK: - 主题差异 token（classic 取原行为，raft 取新粗野值）

    /// 卡片描边宽度：classic 0.5 细边；raft 2px 墨边
    static var cardBorderWidth: CGFloat {
        ThemeStyle.current == .raft ? 2 : 0.5
    }

    /// 卡片硬阴影（raft = 零模糊 4/4 墨影；classic = nil 不投影）。
    /// SwiftUI `.shadow(radius: 0)` 即零模糊偏移阴影，正是 brutalist 硬影。
    static var cardShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current == .raft ? (ink, 0, 4, 4) : nil
    }

    /// 小控件硬阴影（胶囊 / 按钮级；raft = 2/2）
    static var controlShadow: (color: Color, radius: CGFloat, x: CGFloat, y: CGFloat)? {
        ThemeStyle.current == .raft ? (ink, 0, 2, 2) : nil
    }

    /// 选中态品牌底上的文字 / 图标色：classic = 白；raft = 墨（配 cyan 底）
    static var onBrand: Color {
        ThemeStyle.current == .raft ? ink : .white
    }

    /// 主窗口底色：classic = 透明（沿用系统窗口底）；raft = 奶油（深色 = 暖黑）
    static var windowBackground: Color {
        ThemeStyle.current == .raft ? raftCream : .clear
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

    /// 计划状态色：完成绿 / 进行紫 / 草稿灰 / 文档金
    static func planStatusColor(_ status: PlanMaterializer.PlanStatus) -> Color {
        switch status {
        case .complete: return enabledGreen
        case .inProgress: return brand
        case .draft: return draftGray
        case .document: return gold
        }
    }

    // MARK: - 间距（Codex 式宽松留白：模块间大间距，卡片内舒适内边距；两种风格一致）

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

    // MARK: - 圆角（classic 简约阶梯 14/10/8/8；raft 小而硬 7/5/3/7）

    enum radius {
        /// 卡片 / 大容器
        static var card: CGFloat { ThemeStyle.current == .raft ? 7 : 14 }
        /// 小型容器（统计瓦片、内嵌面板）
        static var container: CGFloat { ThemeStyle.current == .raft ? 5 : 10 }
        /// 小方块（logo 块 / 图标块）与侧栏导航项
        static var tile: CGFloat { ThemeStyle.current == .raft ? 3 : 8 }
        /// 侧栏导航项
        static var sidebar: CGFloat { ThemeStyle.current == .raft ? 7 : 8 }
    }

    // MARK: - 字号（classic = SF 系统字体；raft = Space Grotesk / Space Mono，尺寸不变）

    enum font {
        /// 页标题 14/700
        static var pageTitle: Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(14, weight: .bold)
                : .system(size: 14, weight: .bold)
        }
        /// 卡片标题 13.5/650（技能名等宽场景用 monoSkillName）
        static var cardTitle: Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(13.5, weight: .semibold)
                : .system(size: 13.5, weight: .semibold)
        }
        /// 技能名等宽（classic = SF Mono；raft = Space Mono）
        static func monoSkillName(_ size: CGFloat = 13.5, weight: Font.Weight = .semibold) -> Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight, design: .monospaced)
        }
        /// 正文 12.5
        static var body: Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(12.5)
                : .system(size: 12.5)
        }
        /// 次要 11
        static var secondary: Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(11)
                : .system(size: 11)
        }
        /// 标注 9.5–10
        static var caption: Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(9.5)
                : .system(size: 9.5)
        }
        /// 大数字 18–23/700 等宽数字
        static func statNumber(_ size: CGFloat = 18) -> Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.mono(size, weight: .bold)
                : .system(size: size, weight: .bold).monospacedDigit()
        }

        /// 视图内联 `.font(.system(size:weight:))` 的主题化替换：
        /// classic 原样返回系统字体（逐像素不变）；raft 映射 Space Grotesk，尺寸字重不变。
        static func themed(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.grotesk(size, weight: weight)
                : .system(size: size, weight: weight)
        }

        /// 内联等宽数字字体的主题化替换：classic = system + monospacedDigit；raft = Space Mono。
        static func themedMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            ThemeStyle.current == .raft
                ? ThemeFonts.mono(size, weight: weight)
                : .system(size: size, weight: weight).monospacedDigit()
        }
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
