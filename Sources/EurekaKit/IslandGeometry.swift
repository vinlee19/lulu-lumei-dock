import CoreGraphics
import Foundation

/// 灵动岛窗口几何：纯函数，便于单测。
/// 输入屏幕 frame 与刘海信息，输出 panel 应放置的 frame。M3 实现。
public enum IslandGeometry {
    /// 岛的两种内容尺寸
    public struct Layout: Equatable, Sendable {
        public var compactSize: CGSize
        public var expandedSize: CGSize

        public init(compactSize: CGSize, expandedSize: CGSize) {
            self.compactSize = compactSize
            self.expandedSize = expandedSize
        }

        public static let standard = Layout(
            compactSize: CGSize(width: 220, height: 36),
            expandedSize: CGSize(width: 380, height: 120)
        )
    }
}
