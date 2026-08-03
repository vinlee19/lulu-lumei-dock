import Foundation

/// 桌面吉祥物的状态(= 动画包要支持的状态套件)
public enum MascotState: String, Sendable, CaseIterable {
    /// 基础态(随当前快照推导,循环播放)
    case idle, working, waiting, sleeping, night
    /// 瞬时态(由事件叠加,播一会儿回落到基础态)
    case success, error, relax
    case poke, wake  // 二期互动态

    /// 缺图时的回退链(最终回到 idle)
    public var fallback: MascotState {
        switch self {
        case .idle: return .idle
        case .working, .waiting, .sleeping: return .idle
        case .night: return .sleeping
        case .success, .error, .relax: return .working
        case .poke, .wake: return .idle
        }
    }
}

/// 吉祥物序列的播放方式。基础态循环，完成/点击/唤醒等瞬时态可只播一次并停在末帧。
public enum MascotPlaybackMode: String, Sendable, Equatable {
    case loop
    case onceHoldLast

    /// 根据本地播放时长返回帧下标。纯函数供渲染层和单测共用。
    public func frameIndex(elapsed: TimeInterval, fps: Double, frameCount: Int) -> Int {
        guard frameCount > 1 else { return 0 }
        let safeElapsed = max(0, elapsed)
        let safeFPS = max(0.1, fps)
        let raw = Int(floor(safeElapsed * safeFPS))
        switch self {
        case .loop:
            return raw % frameCount
        case .onceHoldLast:
            return min(raw, frameCount - 1)
        }
    }
}

/// 精灵图的逻辑网格。图片尺寸由 App 层读取，这里只负责安全的格子边界。
public struct MascotSpriteGrid: Sendable, Equatable {
    public var columns: Int
    public var rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(1, columns)
        self.rows = max(1, rows)
    }

    public func contains(row: Int, column: Int) -> Bool {
        (0..<rows).contains(row) && (0..<columns).contains(column)
    }
}

/// 逐帧刷新只应在面板可见且系统清醒时运行。
public enum MascotAnimationPolicy {
    public static func shouldAnimate(isVisible: Bool, isAwake: Bool) -> Bool {
        isVisible && isAwake
    }
}

/// 基础态推导(纯函数,便于单测)。瞬时态(success/error/relax/poke/wake)由 ViewModel 按事件叠加。
public enum MascotBaseResolver {
    public struct Input {
        public var hasWaitingTask: Bool
        public var hasRunningTask: Bool
        /// 距最近活跃的秒数(有活跃任务时为 0)
        public var idleSeconds: TimeInterval
        public var sleepThreshold: TimeInterval
        public var now: Date

        public init(
            hasWaitingTask: Bool, hasRunningTask: Bool,
            idleSeconds: TimeInterval, sleepThreshold: TimeInterval = 60, now: Date
        ) {
            self.hasWaitingTask = hasWaitingTask
            self.hasRunningTask = hasRunningTask
            self.idleSeconds = idleSeconds
            self.sleepThreshold = sleepThreshold
            self.now = now
        }
    }

    /// 优先级:等你确认 > (深夜跑→困倦 / 否则专注) > 久空闲或深夜无任务→睡 > 平静
    public static func base(_ input: Input, calendar: Calendar = .current) -> MascotState {
        if input.hasWaitingTask { return .waiting }
        let hour = calendar.component(.hour, from: input.now)
        let deepNight = hour >= 23 || hour < 6
        if input.hasRunningTask {
            return deepNight ? .night : .working
        }
        // 无活跃任务
        if input.idleSeconds >= input.sleepThreshold || deepNight {
            return .sleeping
        }
        return .idle
    }
}
