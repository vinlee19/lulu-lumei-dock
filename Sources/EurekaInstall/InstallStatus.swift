import Foundation

/// 某一目标配置（Claude settings.json / Codex config.toml）的安装状态
public enum InstallStatus: String, Sendable {
    /// 已完整安装 Eureka 条目
    case installed
    /// 部分安装（如只装了部分 hook 事件）
    case partial
    /// 存在他人的冲突配置（如已有非 Eureka 的 notify），拒绝自动覆盖
    case foreign
    /// 未安装
    case none
}
