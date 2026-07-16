import EurekaStore
import Foundation

/// 一轮同步的结果汇总（UI 文案与 health 上报用）
public struct SyncReport: Equatable {
    public var uploaded = 0
    public var uploadedBytes: Int64 = 0
    public var failed = 0
    public var deferred = 0
    public var skippedOversize = 0
    public var firstError: String?
    /// 本轮成功上传的文件（名 + 字节）；上限 500 条（uploaded 计数仍为真实总数）
    public var uploadedFiles: [UploadedFile] = []

    public init() {}

    public struct UploadedFile: Equatable, Sendable {
        public var name: String
        public var size: Int64
    }

    static let maxRecordedFiles = 500
}

/// 同步进行中的实时进度（UI 进度条用）
public struct SyncProgress: Equatable {
    /// 本轮计划上传的文件总数
    public var totalFiles: Int
    /// 已处理（成功 + 失败）
    public var completedFiles: Int
    /// 本轮计划上传的字节总量
    public var totalBytes: Int64
    /// 已成功传输的字节
    public var transferredBytes: Int64
    /// 正在上传的文件名（对象键末段）；nil = 枚举/收尾阶段
    public var currentFile: String?

    public var fraction: Double {
        totalFiles > 0 ? Double(completedFiles) / Double(totalFiles) : 0
    }
}

/// 单轮同步编排：枚举 → diff → 串行上传 → 落状态。
/// 调用方（SyncService）保证串行执行与 skip-if-syncing 守卫。
public final class SyncEngine {
    public struct Limits {
        /// 单文件上限（超过跳过并计数）
        public var maxFileSize: Int64 = 256 << 20
        public var maxFilesPerCycle = 500
        /// 单轮字节预算：首轮大积压按每轮 100MB 渐进排空
        public var maxBytesPerCycle: Int64 = 100 << 20
        /// 连续传输层失败（URLError）达到该数 → 判定断网，中止余量
        public var abortAfterConsecutiveNetworkFailures = 3

        public init() {}

        /// 手动「立即同步」用的放宽配额
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
    /// 实时进度回调（在引擎执行线程上调用；UI 侧自行回主线程）
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

        // 1. 枚举本地文件
        let enumerated = SyncSourceCatalog.enumerate(
            roots: roots, prefix: keyPrefix, host: host, maxFileSize: limits.maxFileSize)
        var candidates = enumerated.candidates
        report.skippedOversize = enumerated.skippedOversize

        // 2. opencode 库：指纹并入候选（键 = db 路径；上传时临时 VACUUM 快照）
        if let fp = OpencodeSnapshot.fingerprint(dbPath: roots.opencodeDB) {
            candidates.append(SyncCandidate(
                localPath: roots.opencodeDB.path,
                remoteKey: SyncKeyMapper.key(
                    prefix: keyPrefix, host: host, category: "opencode",
                    relativePath: "opencode.db"),
                size: fp.size, mtime: fp.mtime, priority: 1))
        }

        // 3. diff
        let state = (try? repo.allEntries()) ?? [:]
        let plan = SyncPlanner.plan(
            candidates: candidates, state: state,
            maxFiles: limits.maxFilesPerCycle, maxBytes: limits.maxBytesPerCycle)
        report.deferred = plan.deferred

        // 4. 串行上传：成功即落库（断电不丢进度）；单文件失败继续；连续断网中止
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
                let etag = try client.putObject(key: candidate.remoteKey, data: data)
                try repo.upsert(SyncStateRepo.Entry(
                    path: candidate.localPath, remoteKey: candidate.remoteKey,
                    size: candidate.size, mtime: candidate.mtime,
                    etag: etag, uploadedAt: Date()))
                report.uploaded += 1
                report.uploadedBytes += Int64(data.count)
                if report.uploadedFiles.count < SyncReport.maxRecordedFiles {
                    let name = candidate.remoteKey.split(separator: "/").last.map(String.init)
                        ?? candidate.remoteKey
                    report.uploadedFiles.append(
                        SyncReport.UploadedFile(name: name, size: candidate.size))
                }
                consecutiveNetworkFailures = 0
            } catch let error as URLError {
                report.failed += 1
                if report.firstError == nil {
                    report.firstError = "网络错误：\(error.localizedDescription)"
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

        // 5. 清盘上已消失的状态行（远端不删）
        if !plan.vanishedPaths.isEmpty {
            try? repo.deletePaths(plan.vanishedPaths)
        }
        return report
    }

    /// 常规文件直接读；opencode 库先 VACUUM 快照再读（用后即删）。
    /// append-only 文件在枚举与读取之间长大 → 上传的字节 ≥ 记录的指纹，
    /// 下轮 stat 对比自然补传，方向安全。
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
