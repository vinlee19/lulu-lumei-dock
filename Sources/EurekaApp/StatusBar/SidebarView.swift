import EurekaKit
import SwiftUI

/// 主窗口左侧导航栏（macOS 系统设置式：品牌头 + 分组条目 + 品牌色选中胶囊 + 底部品牌区）。
///
/// 从 `PopoverRootView` 里抽出来的独立视图，两个原因：
///  1. 它能被离屏渲染器单独快照（`--render-shell`），改尺寸/间距不用再靠肉眼在真机上比；
///  2. `PopoverRootView` 有 14 个注入依赖，而侧栏只需要「当前选中 + 限额徽标 + 版本号」。
///
/// 品牌标只在**底部**出现一次。以前顶部 18pt、底部 13pt 各一个，同一个 165pt 宽的列里
/// 两个品牌方块既重复、底部那个还比旁边导航图标的 20pt 槽更小。
struct SidebarView: View {
    let selected: PopoverRootView.Tab
    /// 限额徽标（无数据时 nil）
    let limitsBadge: (text: String, color: Color)?
    let appVersion: String
    let onSelect: (PopoverRootView.Tab) -> Void
    /// 点击底部品牌区（跳「设置 → 关于」）；渲染器可不传
    var onOpenAbout: (() -> Void)?

    /// 侧栏固定宽度。行内可用宽 = 165 − 8×2（外层）− 8×2（按钮内）= 133pt，
    /// 这是任何图标/文案放大的硬上限。
    static let width: CGFloat = 165

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            Divider().padding(.vertical, 4).padding(.horizontal, 2)
            // 条目区必须能滚。`MainWindowController` 用的是 `hosting.sizingOptions = []`
            // ——内容超出窗口是**裁剪**而不是撑窗，且 `window.minSize` 540 是含标题栏的
            // frame 高（内容区只有 ~512）。实测 12 个条目 + 5 个组标签 + 品牌脚注在 512
            // 下只剩十几 pt 余量，再加一组或系统放大字号就会把脚注切掉。
            // 包一层 ScrollView 后，无论多少组都不可能裁；有余量时内容自然顶到上边。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(PopoverRootView.Tab.sidebarGroups.enumerated()), id: \.offset) {
                        _, group in
                        // 分组标签（小写灰强调，替代单纯分隔线）
                        // 间距按最小窗高倒推：11 个条目 + 5 个组标签要在 ~512pt 内容高里
                        // 尽量都露出来（露不全也不会裁 —— 外层 ScrollView 兜着）
                        Text(group.label)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 3)
                            .padding(.bottom, 1)
                        ForEach(group.tabs, id: \.self) { tab in
                            SidebarNavButton(
                                title: tab.rawValue, icon: tab.icon, tileColor: tab.tileColor,
                                badge: tab == .limits ? limitsBadge?.text : nil,
                                badgeColor: (tab == .limits ? limitsBadge?.color : nil)
                                    ?? .secondary,
                                isSelected: selected == tab
                            ) {
                                onSelect(tab)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            brandFooter
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .frame(width: Self.width)
        .background(Theme.surfaceSecondary)
    }

    /// 顶部只留字样（品牌方块已集中到底部，不再一列两个）
    private var header: some View {
        HStack(spacing: 7) {
            Text("lulu-lumei-dock")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    /// 左下角品牌区：放大的 logo + 名称 + 版本，整块可点 → 设置 → 关于
    private var brandFooter: some View {
        Button {
            onOpenAbout?()
        } label: {
            HStack(spacing: 8) {
                LuluLogoTile(size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("lulu-lumei-dock")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("v\(appVersion)")
                        .font(Theme.font.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius.sidebar))
        }
        .buttonStyle(.plain)
        .help("关于 lulu-lumei-dock")
        .padding(.bottom, 4)
    }
}
