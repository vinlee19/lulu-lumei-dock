import EurekaInstall
import EurekaKit
import SwiftUI

/// 全局调色板：页签/领域主题色、语义状态色、卡片底色。
/// UI 颜色统一从这里取，避免同一语义在各视图各写一套（改版前全仓有 6 处重复的状态色 switch）。
/// 基调取自 App 图标（靛紫/金/青）与 AgentSource.brandColor（Claude 橙 / Codex 青 / opencode 靛）。
enum Theme {
    // MARK: - 领域主题色（每个页签一个）

    static let history = Color.orange
    static let sessions = Color.blue
    static let skills = Color.purple
    static let memory = Color.pink
    static let plans = Color.mint
    static let agents = Color.teal
    static let usage = Color.green
    static let limits = Color.indigo
    static let backup = Color.cyan
    static let audit = Color.red
    static let settings = Color.gray
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

    // MARK: - 卡片底色

    /// 领域色轻染卡片（替代通用的 Color.primary.opacity(0.045)）
    static func cardFill(_ accent: Color) -> Color {
        accent.opacity(0.07)
    }

    /// 中性卡片（无领域归属时用）
    static let neutralCard = Color.primary.opacity(0.045)
}
