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

    // MARK: - 语义状态色（收编全仓重复 switch）

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

    // MARK: - 圆角（Codex 式大圆角）

    enum radius {
        /// 卡片 / 大容器
        static let card: CGFloat = 14
        /// 小型容器（图标底、内嵌面板）
        static let container: CGFloat = 10
    }
}
