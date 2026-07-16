import EurekaStore
import Foundation

/// 一轮同步的上传计划
public struct SyncPlan: Equatable {
    /// 待上传，已按 priority → mtime 降序排列并截断到限量
    public var uploads: [SyncCandidate]
    /// 因限量被推迟到下轮的数量
    public var deferred: Int
    /// sync_state 有记录、磁盘已消失的路径 → 清状态行（远端不删，上传-only）
    public var vanishedPaths: [String]

    public init(uploads: [SyncCandidate], deferred: Int, vanishedPaths: [String]) {
        self.uploads = uploads
        self.deferred = deferred
        self.vanishedPaths = vanishedPaths
    }
}

/// 纯函数 diff：候选清单 × sync_state → 上传计划。
/// 变更判定只看 size + mtime —— transcripts 均 append-only，足够可靠；
/// 内容 SHA256 反正在上传签名（x-amz-content-sha256）时会算一次。
public enum SyncPlanner {
    public static func plan(
        candidates: [SyncCandidate], state: [String: SyncStateRepo.Entry],
        maxFiles: Int, maxBytes: Int64
    ) -> SyncPlan {
        var changed: [SyncCandidate] = []
        var seenPaths = Set<String>()
        for candidate in candidates {
            seenPaths.insert(candidate.localPath)
            if let entry = state[candidate.localPath],
               entry.size == candidate.size,
               abs(entry.mtime - candidate.mtime) <= 0.001 {
                continue  // 未变
            }
            changed.append(candidate)
        }

        // 小而贵的 memory/skills 先传；同级内新会话先受保护
        changed.sort {
            $0.priority == $1.priority ? $0.mtime > $1.mtime : $0.priority < $1.priority
        }

        var uploads: [SyncCandidate] = []
        var totalBytes: Int64 = 0
        for candidate in changed {
            if uploads.count >= maxFiles { break }
            if !uploads.isEmpty && totalBytes + candidate.size > maxBytes { break }
            uploads.append(candidate)
            totalBytes += candidate.size
        }

        let vanished = state.keys.filter { !seenPaths.contains($0) }.sorted()
        return SyncPlan(
            uploads: uploads,
            deferred: changed.count - uploads.count,
            vanishedPaths: vanished)
    }
}
