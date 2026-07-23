import EurekaInstall
import EurekaKit
import SwiftUI

/// 全局设计令牌：品牌强调色、语义状态色、中性底色、间距。
/// UI 颜色/间距统一从这里取，避免同一语义在各视图各写一套。
/// 强调色取自 App 图标（靛紫 + 金），其余一律中性灰阶 + 系统状态色。
enum Theme {
    // MARK: - 品牌强调色

    /// 主强调色：靛紫（取自 App 图标），深色模式自动提亮
    static let brand = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.55, green: 0.55, blue: 0.96, alpha: 1)
            : NSColor(srgbRed: 0.36, green: 0.36, blue: 0.89, alpha: 1)
    }))

    /// 辅助强调色：金（取自 App 图标），用于亮点 / 提示类信息
    static let gold = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.89, green: 0.74, blue: 0.38, alpha: 1)
            : NSColor(srgbRed: 0.78, green: 0.62, blue: 0.15, alpha: 1)
    }))

    /// 金额恒蓝（沿用既有约定）
    static let cost = Color.blue

    /// 紫金渐变：色脊 / 徽标底统一从这里取（勿在各视图手写）
    static var purpleGoldGradient: LinearGradient {
        LinearGradient(colors: [brand, gold], startPoint: .top, endPoint: .bottom)
    }

    /// 图表柱渐变（#8C8CF5 → #5C5CE3，自上而下；近 30 天调用柱状图用）
    static var chartBarGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(.sRGB, red: 0.55, green: 0.55, blue: 0.96, opacity: 1),
                Color(.sRGB, red: 0.36, green: 0.36, blue: 0.89, opacity: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: - 语义状态色（收编全仓重复 switch）

    /// 启用绿
    static let enabledGreen = Color(.sRGB, red: 0.20, green: 0.78, blue: 0.35, opacity: 1)
    /// 停用灰
    static let disabledGray = Color(.sRGB, red: 0.86, green: 0.86, blue: 0.88, opacity: 1)
    /// 失败红
    static let failureRed = Color(.sRGB, red: 0.82, green: 0.27, blue: 0.23, opacity: 1)
    /// 自动清理灰
    static let autoCleanGray = Color(.sRGB, red: 0.64, green: 0.64, blue: 0.66, opacity: 1)

    /// 任务结局：成功绿 / 出错红 / 中断灰
    static func outcomeColor(_ outcome: TaskOutcome) -> Color {
        switch outcome {
        case .success: return .green
        case .error: return .red
        case .interrupted: return .gray
        }
    }

    /// 用量占比阈值：<60 绿 / <85 橙 / 其余红（限额、ctx% 共用）
    static func percentColor(_ percent: Double) -> Color {
        switch percent {
        case ..<60: return .green
        case ..<85: return .orange
        default: return .red
        }
    }

    /// 接入安装状态
    static func installColor(_ status: InstallStatus) -> Color {
        switch status {
        case .installed: return .green
        case .partial, .foreign: return .orange
        case .none: return .gray
        }
    }

    /// 数据源健康状态
    static func healthColor(_ status: HealthRegistry.Entry.Status) -> Color {
        switch status {
        case .ok: return .green
        case .degraded: return .orange
        case .stalled: return .red
        case .idle: return .gray
        }
    }

    // MARK: - 中性底色

    /// 卡片底（浅色 = 白，深色 = 深灰；与窗口背景形成 macOS 式层级）
    static let surface = Color(nsColor: .controlBackgroundColor)

    /// 分组头 / 工具条 / 悬浮底
    static let surfaceSecondary = Color.primary.opacity(0.05)

    /// 更浅的容器底（表格、日志区）
    static let surfaceTertiary = Color.primary.opacity(0.03)

    /// 分隔线 / 细描边
    static let hairline = Color.primary.opacity(0.08)

    /// 卡片 / 方块描边（参考稿简约风：可见的浅灰边，替代过浅的 hairline）
    static let cardBorder = Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.14)
            : NSColor(srgbRed: 0.89, green: 0.89, blue: 0.91, alpha: 1)  // #E2E2E8
    }))

    /// 品牌色轻染填充（选中态 / 徽标 / 高亮行）
    static func brandFill(_ opacity: Double = 0.10) -> Color {
        brand.opacity(opacity)
    }

    // MARK: - 间距（Codex 式宽松留白：模块间大间距，卡片内舒适内边距）

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

    // MARK: - 圆角（简约两级阶梯：卡片 12 / 容器 10 / 小方块与侧栏项 8）

    enum radius {
        /// 卡片 / 大容器
        static let card: CGFloat = 12
        /// 小型容器（统计瓦片、内嵌面板）
        static let container: CGFloat = 10
        /// 小方块（logo 块 / 图标块）与侧栏导航项
        static let tile: CGFloat = 8
        /// 侧栏导航项
        static let sidebar: CGFloat = 8
    }

    // MARK: - 字号（设计稿「紫金」规范，统一从这里取）

    enum font {
        /// 页标题 14/700
        static let pageTitle = Font.system(size: 14, weight: .bold)
        /// 卡片标题 13.5/650（技能名等宽场景用 monoSkillName）
        static let cardTitle = Font.system(size: 13.5, weight: .semibold)
        /// 技能名等宽（SF Mono）
        static func monoSkillName(_ size: CGFloat = 13.5, weight: Font.Weight = .semibold) -> Font {
            .system(size: size, weight: weight, design: .monospaced)
        }
        /// 正文 12.5
        static let body = Font.system(size: 12.5)
        /// 次要 11
        static let secondary = Font.system(size: 11)
        /// 标注 9.5–10
        static let caption = Font.system(size: 9.5)
        /// 大数字 18–23/700 等宽数字
        static func statNumber(_ size: CGFloat = 18) -> Font {
            .system(size: size, weight: .bold).monospacedDigit()
        }
    }
}
