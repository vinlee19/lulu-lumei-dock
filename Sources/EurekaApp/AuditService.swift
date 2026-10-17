import AppKit
import EurekaIngest
import EurekaKit
import EurekaStore
import EurekaSync
import Foundation

/// Security audit service: owns a dedicated SQLite connection + AuditPipeline + the
/// Codex/CodeBuddy/Qoder audit scanners. Claude and Trae operations arrive via EventPipeline's side
/// channel (ingestHook); the rest rely on periodic jsonl scans. store/pipeline/scanner are only
/// touched on the internal serial queue; @Published is only updated on the main thread.
final class AuditService: ObservableObject {
    /// The audit panel's current page (newest first) and total count
    @Published private(set) var events: [AuditEvent] = []
    @Published private(set) var total = 0
    @Published private(set) var riskTotal = 0
    @Published private(set) var lastError: String?
    @Published private(set) var exportMessage: String?
    /// Counts grouped by source / type (the filter chips and the overview card's distribution). ⚠️
    /// `SourceFilterBar`'s `count:` closure is **called per chip** during rendering, so it may only
    /// read these two dictionaries; it must never hit the database each time.
    @Published private(set) var sourceCounts: [AgentSource: Int] = [:]
    @Published private(set) var kindCounts: [ToolKind: Int] = [:]
    /// Audit archive ledger summary (shown in the Settings popover; nil when archiving is off)
    @Published private(set) var archiveStatus: ArchiveStatus?

    struct ArchiveStatus: Equatable {
        /// Days uploaded and matching local data
        var uploadedDays: Int
        /// Days with new local changes, waiting for the next backup upload
        var pendingDays: Int
        /// Most recent uploaded date (UTC, YYYY-MM-DD)
        var latestUploadedDay: String?
    }

    /// Called back (main thread) when a high-risk rule matches: AppDelegate turns it into an island
    /// card + system notification
    var onRiskAlert: ((RiskAlert) -> Void)?

    private let queue = DispatchQueue(label: "com.vinlee.eureka.audit", qos: .utility)
    private var timer: DispatchSourceTimer?

    // The members below are only accessed on queue
    private var store: EurekaStore?
    private var pipeline: AuditPipeline?
    private var codexScanner: CodexAuditScanner?
    private var codeBuddyScanner: CodeBuddyAuditScanner?
    private var qoderScanner: QoderAuditScanner?
    private var cursorScanner: CursorAuditScanner?
    private var grokScanner: GrokAuditScanner?
    private var qwenScanner: QwenAuditScanner?
    private var captureEnabled = true
    private var retentionDays = 90
    private var lastPruneAt = Date.distantPast

    private static let codexHealthName = "审计扫描 Codex"
    private static let codeBuddyHealthName = "审计扫描 CodeBuddy"
    private static let qoderHealthName = "审计扫描 Qoder"
    private static let cursorHealthName = "审计扫描 Cursor"
    private static let grokHealthName = "审计扫描 Grok"
    private static let qwenHealthName = "审计扫描 Qwen"

    func start() {
        HealthRegistry.shared.register(Self.codexHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.codeBuddyHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.qoderHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.cursorHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.grokHealthName, expectedInterval: 60)
        HealthRegistry.shared.register(Self.qwenHealthName, expectedInterval: 60)
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let store = try EurekaStore(path: EurekaStore.defaultURL())
                let pipeline = AuditPipeline(store: store)
                self.store = store
                self.pipeline = pipeline
                self.codexScanner = CodexAuditScanner(
                    sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(),
                    store: store, pipeline: pipeline)
                self.codeBuddyScanner = CodeBuddyAuditScanner(
                    projectsRoot: CodeBuddyPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.qoderScanner = QoderAuditScanner(
                    projectsRoot: QoderPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.cursorScanner = CursorAuditScanner(
                    dbPath: CursorPaths.globalStateDB(),
                    workspaceStorageRoot: CursorPaths.workspaceStorageRoot(),
                    store: store, pipeline: pipeline)
                self.grokScanner = GrokAuditScanner(
                    sessionsRoot: GrokPaths.sessionsRoot(),
                    store: store, pipeline: pipeline)
                self.qwenScanner = QwenAuditScanner(
                    projectsRoot: QwenPaths.projectsRoot(),
                    store: store, pipeline: pipeline)
                self.scanCodex()
                self.scanCodeBuddy()
                self.scanQoder()
                self.scanCursor()
                self.scanGrok()
                self.scanQwen()
                self.pruneIfDue()
            } catch {
                self.publish { $0.lastError = L10n.format("Failed to open audit database: %@", zhHans: "审计库打开失败: %@", String(describing: error)) }
            }
        }
        // 2s near-real-time scan of Codex/CodeBuddy/Qoder/Cursor/Grok/Qwen + pruning when due
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // leeway lets the system coalesce wakeups to save power
        timer.schedule(deadline: .now() + 2, repeating: 2, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.scanCodex()
            self?.scanCodeBuddy()
            self?.scanQoder()
            self?.scanCursor()
            self?.scanGrok()
            self?.scanQwen()
            self?.pruneIfDue()
        }
        timer.resume()
        self.timer = timer
    }

    /// Claude PostToolUse side-channel events (EventPipeline queue callback -> hop onto the audit
    /// queue for serial processing) Side-channel entry for PostToolUse on the hook channels (Claude
    /// / Trae). Events carry their own source, so no distinction here.
    func ingestHook(_ event: AuditEvent, isStale: Bool) {
        queue.async { [weak self] in
            guard let self, self.captureEnabled, let pipeline = self.pipeline else { return }
            do {
                let result = try pipeline.ingest(event, isStale: isStale)
                if let alert = result.alert { self.emit(alert) }
            } catch {
                self.publish { $0.lastError = L10n.format("%@ audit write failed: %@", zhHans: "%@ 审计写入失败: %@", String(event.source.displayName), String(describing: error)) }
            }
        }
    }

    // MARK: - Settings bindings (called on the main thread, applied by hopping queues)

    func setCaptureEnabled(_ enabled: Bool) {
        queue.async { [weak self] in self?.captureEnabled = enabled }
    }

    func updateRetention(days: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.retentionDays = days
            self.lastPruneAt = .distantPast  // prune once right away under the new policy
            self.pruneIfDue()
        }
    }

    // MARK: - Panel data

    /// Paged load (page starts at 1)
    func load(query: AuditRepo.Query, page: Int, pageSize: Int = 100) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let total = try store.audit.count(query)
                let rows = try store.audit.recent(
                    query, limit: pageSize, offset: (max(1, page) - 1) * pageSize)
                let riskTotal = try store.audit.count(.init(riskOnly: true))
                // Each distribution count drops its own dimension: otherwise selecting a source
                // turns every other chip to 0, and the user can't see "how many there would be if I
                // switched".
                var sourceQuery = query
                sourceQuery.source = nil
                var kindQuery = query
                kindQuery.kind = nil
                let bySource = try store.audit.counts(by: .source, sourceQuery)
                let byKind = try store.audit.counts(by: .kind, kindQuery)
                let archive = AuditArchiveSettings.isActive
                    ? Self.archiveStatus(store: store) : nil
                self.publish {
                    $0.archiveStatus = archive
                    $0.events = rows
                    $0.total = total
                    $0.riskTotal = riskTotal
                    $0.lastError = nil
                    $0.sourceCounts = Dictionary(
                        uniqueKeysWithValues: bySource.compactMap { key, value in
                            AgentSource(rawValue: key).map { ($0, value) }
                        })
                    $0.kindCounts = Dictionary(
                        uniqueKeysWithValues: byKind.compactMap { key, value in
                            ToolKind(rawValue: key).map { ($0, value) }
                        })
                }
            } catch {
                self.publish { $0.lastError = L10n.format("Failed to read audit log: %@", zhHans: "读取审计流水失败: %@", String(describing: error)) }
            }
        }
    }

    /// Exports the current filtered results as CSV to ~/Downloads and reveals it in Finder
    /// (contains sensitive commands; the caller must warn)
    func exportCSV(query: AuditRepo.Query) {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            do {
                let rows = try store.audit.recent(query, limit: 100_000)
                let isoFormatter = ISO8601DateFormatter()
                var csv = "timestamp,source,session,kind,tool,detail,exit_code,is_error,risk_level,risk_rule\n"
                for row in rows {
                    csv += [
                        isoFormatter.string(from: row.timestamp),
                        row.source.rawValue, row.sessionId, row.kind.rawValue,
                        Self.csvField(row.tool), Self.csvField(row.detail),
                        row.exitCode.map(String.init) ?? "",
                        row.isError ? "1" : "0",
                        row.riskLevel?.label ?? "", row.riskRule ?? "",
                    ].joined(separator: ",") + "\n"
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss"
                let url = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Downloads/eureka-audit-\(formatter.string(from: Date())).csv")
                try Data(csv.utf8).write(to: url)
                self.publish { $0.exportMessage = L10n.format("Exported %@ (%@ records)", zhHans: "已导出 %@（%@ 条）", String(url.lastPathComponent), String(rows.count)) }
                DispatchQueue.main.async {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                self.publish { $0.exportMessage = L10n.format("Export failed: %@", zhHans: "导出失败: %@", String(describing: error)) }
            }
        }
    }

    /// Clears all audit data
    func clearAll() {
        queue.async { [weak self] in
            guard let self, let store = self.store else { return }
            try? store.audit.deleteAll()
            self.publish {
                $0.events = []
                $0.total = 0
                $0.riskTotal = 0
                $0.exportMessage = L10n.text("Audit data cleared", zhHans: "审计数据已清空")
            }
        }
    }

    // MARK: - Queue internals

    private func scanCodex() {
        guard captureEnabled, let scanner = codexScanner else { return }
        HealthRegistry.shared.beat(Self.codexHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.codexHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.codexHealthName, note: "\(error)")
        }
    }

    private func scanCodeBuddy() {
        guard captureEnabled, let scanner = codeBuddyScanner else { return }
        HealthRegistry.shared.beat(Self.codeBuddyHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.codeBuddyHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.codeBuddyHealthName, note: "\(error)")
        }
    }

    private func scanQoder() {
        guard captureEnabled, let scanner = qoderScanner else { return }
        HealthRegistry.shared.beat(Self.qoderHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.qoderHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.qoderHealthName, note: "\(error)")
        }
    }

    private func scanCursor() {
        guard captureEnabled, let scanner = cursorScanner else { return }
        HealthRegistry.shared.beat(Self.cursorHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.cursorHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.cursorHealthName, note: "\(error)")
        }
    }

    private func scanGrok() {
        guard captureEnabled, let scanner = grokScanner else { return }
        HealthRegistry.shared.beat(Self.grokHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.grokHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.grokHealthName, note: "\(error)")
        }
    }

    private func scanQwen() {
        guard captureEnabled, let scanner = qwenScanner else { return }
        HealthRegistry.shared.beat(Self.qwenHealthName)
        do {
            let new = try scanner.scanOnce { [weak self] alert in self?.emit(alert) }
            if new > 0 { HealthRegistry.shared.event(Self.qwenHealthName) }
        } catch {
            HealthRegistry.shared.failure(Self.qwenHealthName, note: "\(error)")
        }
    }

    private static func archiveStatus(store: EurekaStore) -> ArchiveStatus? {
        guard let days = try? store.audit.dayFingerprints(),
              let ledger = try? store.auditArchive.all()
        else { return nil }
        let uploaded = Dictionary(uniqueKeysWithValues: ledger.compactMap { entry in
            entry.uploadedFingerprint.map { (entry.day, $0) }
        })
        let current = days.filter { uploaded[$0.day] == $0.fingerprint }
        return ArchiveStatus(
            uploadedDays: current.count,
            pendingDays: days.count - current.count,
            latestUploadedDay: ledger.filter { $0.uploadedAt != nil }.map(\.day).max())
    }

    /// Prunes once an hour: by the day window + a fallback cap of 200k rows
    private func pruneIfDue() {
        guard let store, Date().timeIntervalSince(lastPruneAt) > 3600 else { return }
        lastPruneAt = Date()
        // With archiving on: only delete whole days that are already uploaded (on upload failure,
        // keep past retention rather than lose unarchived records)
        if AuditArchiveSettings.isActive {
            AuditArchive.prune(store: store, cutoff: AuditArchiveSettings.retentionCutoff, maxRows: 200_000)
            return
        }
        if retentionDays > 0 {
            try? store.audit.prune(
                olderThan: Date().addingTimeInterval(-Double(retentionDays) * 86400))
        }
        try? store.audit.prune(keepingLast: 200_000)
    }

    private func emit(_ alert: RiskAlert) {
        DispatchQueue.main.async { [weak self] in self?.onRiskAlert?(alert) }
    }

    private func publish(_ apply: @escaping (AuditService) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            apply(self)
        }
    }

    private static func csvField(_ value: String) -> String {
        // Wrap in quotes and escape inner quotes when the value contains a comma / quote / newline
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
