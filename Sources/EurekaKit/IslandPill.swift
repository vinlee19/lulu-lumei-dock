import Foundation

/// 收缩胶囊的投影（设计稿 agent-dock-final 的「菜单栏窄条」）：
/// 左翼每个在场来源一枚图标，有运行中会话的亮并带青色圆点、只剩空闲会话的变暗，后跟运行中计数；
/// 右翼「有事才亮」的告警位，没有告警时显示最早任务的计时。纯逻辑，视图只做渲染。
public enum IslandPill {
    /// 左翼的一枚来源图标
    public struct SourceMark: Equatable, Sendable {
        public var source: AgentSource
        /// 该来源有运行/等待中的会话（图标亮 + 青色圆点）；false = 只有空闲会话（变暗）
        public var isActive: Bool

        public init(source: AgentSource, isActive: Bool) {
            self.source = source
            self.isActive = isActive
        }
    }

    /// 右翼告警。多个同时成立时按 case 顺序取最前面的一个
    public enum Alert: Equatable, Sendable {
        /// 有会话在等待授权 / 等待输入（授权优先）
        case waiting(WaitReason)
        /// 某个会话（含空闲）的上下文占用 ≥ `contextAlertPercent`，取最高的
        case context(percent: Double)
        /// 未读完成：数量 + 最严重的结果
        case unread(count: Int, worstOutcome: TaskOutcome)
    }

    /// 上下文占用到这个比例就亮右翼告警
    public static let contextAlertPercent: Double = 90

    /// 左翼来源：运行中与空闲会话的来源并集，按 `AgentSource.allCases` 固定顺序
    public static func sourceMarks(active: [AgentTask], idle: [AgentTask]) -> [SourceMark] {
        let activeSources = Set(active.map(\.source))
        let present = activeSources.union(idle.map(\.source))
        return AgentSource.allCases
            .filter { present.contains($0) }
            .map { SourceMark(source: $0, isActive: activeSources.contains($0)) }
    }

    public static func alert(
        active: [AgentTask], idle: [AgentTask], unread: IslandUnreadFinished
    ) -> Alert? {
        let reasons = active.compactMap { task -> WaitReason? in
            if case .waiting(let reason, _) = task.phase { return reason }
            return nil
        }
        if reasons.contains(.permission) { return .waiting(.permission) }
        if let reason = reasons.first { return .waiting(reason) }
        let highest = (active + idle).compactMap(\.contextUsedPercent).max()
        if let highest, highest >= contextAlertPercent { return .context(percent: highest) }
        if let worst = unread.worstOutcome { return .unread(count: unread.count, worstOutcome: worst) }
        return nil
    }
}
