import EurekaStore
import EurekaKit
import Foundation

/// Summary of one sync round (for UI copy and health reporting)
public struct SyncReport: Equatable {
    public var uploaded = 0
    public var uploadedBytes: Int64 = 0
    public var failed = 0
    public var deferred = 0
    public var skippedOversize = 0
    public var firstError: String?
    /// Files uploaded successfully this round (name + bytes); capped at 500 entries (the uploaded
    /// count is still the real total)
    public var uploadedFiles: [UploadedFile] = []

    public init() {}

    public struct UploadedFile: Equatable, Sendable {
        public var name: String
        public var size: Int64
        /// Source category (e.g. "claude/skills", "kimi/sessions", "custom/notes"); the first
        /// segment is the source
        public var category: String = ""
    }

    static let maxRecordedFiles = 500
}

/// Live progress while a sync runs (for the UI progress bar)
public struct SyncProgress: Equatable {
    /// Total number of files planned for upload this round
    public var totalFiles: Int
    /// Processed so far (succeeded + failed)
    public var completedFiles: Int
    /// Total bytes planned for upload this round
    public var totalBytes: Int64
    /// Bytes transferred successfully
    public var transferredBytes: Int64
    /// Name of the file being uploaded (last segment of the object key); nil = enumerating /
    /// wrapping up
    public var currentFile: String?

    public var fraction: Double {
        totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0
    }
}

/// Orchestrates one sync round: enumerate → diff → serial upload → persist state.
/// The caller (SyncService) guarantees serial execution and the skip-if-syncing guard.
public final class SyncEngine {
    public struct Limits {
        /// Per-file size cap (larger files are skipped and counted)
        public var maxFileSize: Int64 = 256 << 20
        public var maxFilesPerCycle = 500
        /// Per-round byte budget: a large first-run backlog drains gradually at 100MB per round
        public var maxBytesPerCycle: Int64 = 100 << 20
        /// This many consecutive transport-layer failures (URLError) → treat as offline and abort
        /// the rest
        public var abortAfterConsecutiveNetworkFailures = 3
        /// Extra retries after a file fails (0 = off; only URLError / 5xx are retried, never 4xx)
        public var maxRetries = 2
        /// Retry backoff base (seconds), growing exponentially: base × 2^attempts so far
        public var retryBackoffSeconds: TimeInterval = 3

        public init() {}

        /// Relaxed quotas for a manual "Sync now"
        public static var relaxed: Limits {
            var limits = Limits()
            limits.maxFilesPerCycle = 100_000
            limits.maxBytesPerCycle = 1 << 40
            return limits
        }
    }

    private let client: S3Client
    private let repo: SyncStateRepo
    private let roots: SyncRoots
    private let keyPrefix: String
    private let host: String
    private let limits: Limits
    /// Live progress callback (called on the engine's thread; the UI hops to the main thread
    /// itself)
    public var onProgress: ((SyncProgress) -> Void)?

    public init(
        client: S3Client, repo: SyncStateRepo, roots: SyncRoots,
        keyPrefix: String, host: String, limits: Limits = Limits()
    ) {
        self.client = client
        self.repo = repo
        self.roots = roots
        self.keyPrefix = keyPrefix
        self.host = host
        self.limits = limits
    }

    public func runCycle() -> SyncReport {
        var report = SyncReport()

        // 1. Enumerate local files
        let enumerated = SyncSourceCatalog.enumerate(
            roots: roots, prefix: keyPrefix, host: host, maxFileSize: limits.maxFileSize)
        var candidates = enumerated.candidates
        report.skippedOversize = enumerated.skippedOversize

        // 2. opencode database: fold its fingerprint into the candidates (key = db path; a
        //    temporary
        // VACUUM snapshot is taken at upload time)
        if let fp = OpencodeSnapshot.fingerprint(dbPath: roots.opencodeDB) {
            candidates.append(SyncCandidate(
                localPath: roots.opencodeDB.path,
                remoteKey: SyncKeyMapper.key(
                    prefix: keyPrefix, host: host, category: "opencode",
                    relativePath: "opencode.db"),
                size: fp.size, mtime: fp.mtime, priority: 1, category: "opencode"))
        }

        // 3. diff
        let state = (try? repo.allEntries()) ?? [:]
        let plan = SyncPlanner.plan(
            candidates: candidates, state: state,
            maxFiles: limits.maxFilesPerCycle, maxBytes: limits.maxBytesPerCycle)
        report.deferred = plan.deferred

        // 4. Serial upload: persist each success immediately (no lost progress on power loss); keep
        // going past single-file failures; abort on consecutive network failures
        var progress = SyncProgress(
            totalFiles: plan.uploads.count, completedFiles: 0,
            totalBytes: plan.uploads.reduce(0) { $0 + $1.size },
            transferredBytes: 0, currentFile: nil)
        onProgress?(progress)
        var consecutiveNetworkFailures = 0
        for candidate in plan.uploads {
            progress.currentFile = candidate.remoteKey
                .split(separator: "/").last.map(String.init)
            onProgress?(progress)
            defer {
                progress.completedFiles = report.uploaded + report.failed
                progress.transferredBytes = report.uploadedBytes
                onProgress?(progress)
            }
            do {
                let data = try readData(for: candidate)
                let etag = try putWithRetry(key: candidate.remoteKey, data: data)
                try repo.upsert(SyncStateRepo.Entry(
                    path: candidate.localPath, remoteKey: candidate.remoteKey,
                    size: candidate.size, mtime: candidate.mtime,
                    etag: etag, uploadedAt: Date(), category: candidate.category))
                report.uploaded += 1
                report.uploadedBytes += Int64(data.count)
                if report.uploadedFiles.count < SyncReport.maxRecordedFiles {
                    let name = candidate.remoteKey.split(separator: "/").last.map(String.init)
                        ?? candidate.remoteKey
                    report.uploadedFiles.append(SyncReport.UploadedFile(
                        name: name, size: candidate.size, category: candidate.category))
                }
                consecutiveNetworkFailures = 0
            } catch let error as URLError {
                report.failed += 1
                if report.firstError == nil {
                    report.firstError = L10n.format("Network error: %@", zhHans: "网络错误：%@", String(error.localizedDescription))
                }
                consecutiveNetworkFailures += 1
                if consecutiveNetworkFailures >= limits.abortAfterConsecutiveNetworkFailures {
                    report.deferred += plan.uploads.count - report.uploaded - report.failed
                    break
                }
            } catch {
                report.failed += 1
                if report.firstError == nil {
                    report.firstError = "\(error)"
                }
                consecutiveNetworkFailures = 0
            }
        }

        // 5. Purge state rows for files that vanished from disk (remote copies are not deleted)
        if !plan.vanishedPaths.isEmpty {
            try? repo.deletePaths(plan.vanishedPaths)
        }
        return report
    }

    /// putObject + configurable retry: only transport errors (URLError) and server 5xx are retried
    /// (4xx = permission/key errors, retrying is pointless, so throw right away). Exponential
    /// backoff base × 2^attempts so far;
    /// the engine already runs on a background serial queue, so a blocking sleep is acceptable.
    private func putWithRetry(key: String, data: Data) throws -> String? {
        var attempt = 0
        while true {
            do {
                return try client.putObject(key: key, data: data)
            } catch {
                let retryable = error is URLError
                    || (error as? S3Error).map { $0.status >= 500 } ?? false
                guard retryable, attempt < limits.maxRetries else { throw error }
                Thread.sleep(
                    forTimeInterval: limits.retryBackoffSeconds * pow(2, Double(attempt)))
                attempt += 1
            }
        }
    }

    /// Regular files are read directly; the opencode database is VACUUM-snapshotted first, then
    /// read (and deleted after use). An append-only file that grows between enumeration and read →
    /// uploaded bytes ≥ the recorded fingerprint, and next round's stat comparison naturally
    /// re-uploads it; the error is in the safe direction.
    private func readData(for candidate: SyncCandidate) throws -> Data {
        if candidate.localPath == roots.opencodeDB.path {
            let snapshot = try OpencodeSnapshot.snapshot(
                dbPath: roots.opencodeDB,
                to: FileManager.default.temporaryDirectory
                    .appendingPathComponent("eureka-sync", isDirectory: true))
            defer { try? FileManager.default.removeItem(at: snapshot) }
            return try Data(contentsOf: snapshot)
        }
        return try Data(contentsOf: URL(fileURLWithPath: candidate.localPath))
    }
}
