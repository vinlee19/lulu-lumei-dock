import Foundation
import EurekaKit

/// SQLite 持久化入口。M5 实现：
/// - task_history（完成任务历史）
/// - usage_records（token 用量记账）
/// - scan_state（每文件 offset/inode + 跨文件去重键，8 天窗口剪枝）
public final class EurekaStore {
    public init() {}
}
