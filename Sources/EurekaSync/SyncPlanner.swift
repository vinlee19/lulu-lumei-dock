import EurekaStore
import Foundation

/// Upload plan for one sync round
public struct SyncPlan: Equatable {
    /// To upload, sorted by priority → mtime descending and truncated to the limits
    public var uploads: [SyncCandidate]
    /// Number deferred to the next round because of the limits
    public var deferred: Int
    /// Paths recorded in sync_state but gone from disk → clear the state rows (remote copies are
    /// not deleted; upload-only)
    public var vanishedPaths: [String]

    public init(uploads: [SyncCandidate], deferred: Int, vanishedPaths: [String]) {
        self.uploads = uploads
        self.deferred = deferred
        self.vanishedPaths = vanishedPaths
    }
}

/// Pure-function diff: candidate list × sync_state → upload plan.
/// Change detection looks only at size + mtime: transcripts are all append-only, so this is
/// reliable enough;
/// the content SHA256 is computed once anyway when signing the upload (x-amz-content-sha256).
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
                continue  // unchanged
            }
            changed.append(candidate)
        }

        // Small but valuable memory/skills upload first; within a tier, newer sessions are
        // protected first
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
