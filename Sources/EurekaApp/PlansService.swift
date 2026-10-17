import AppKit
import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

/// Plans browsing service: materializes Codex/opencode plans into staging, indexes each source's
/// plan .md (Claude's are files directly), plus plan docs inside each project repo (docs/**/plans,
/// plans/). Shares the same materialized output (`PlanMaterializer`) with S3 sync. Read-only
/// browsing; never rewrites the sources.
final class PlansService: ObservableObject {
    @Published private(set) var plans: [PlanMaterializer.PlanEntry] = []
    @Published private(set) var scanning = false
    /// Phase text while scanning: Plans is the slowest (the first run parses every session), so it
    /// must say what it's doing; set to nil when done
    @Published private(set) var scanPhase: String?
    /// When the last scan finished. nil = never scanned (refresh's criterion)
    @Published private(set) var lastScanAt: Date?
    /// Totals over the full set (unaffected by filters/search)
    @Published private(set) var totalCount = 0
    @Published private(set) var totalBytes: UInt64 = 0

    /// Cross-page jump: file path of the plan to focus (written by PopoverRootView, cleared after
    /// PlansView consumes it)
    @Published var focusPath: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.plans", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var all: [PlanMaterializer.PlanEntry] = []

    /// Refresh (materialize + index). force = false scans only when "never scanned" (shared by
    /// launch prewarm + the onAppear fallback, idempotent); force = true unconditionally rescans
    /// everything, used only by the refresh button.
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        scanPhase = L10n.text("Parsing Codex sessions…", zhHans: "正在解析 Codex 会话…")
        queue.async { [weak self] in
            guard let self else { return }
            let staging = PlanMaterializer.defaultStagingRoot()
            PlanMaterializer.materializeCodex(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), into: staging)
            self.publishPhase(L10n.text("Parsing other CLI sessions…", zhHans: "正在解析其它 CLI 会话…"))
            PlanMaterializer.materializeOpencode(dbPath: OpencodePaths.db(), into: staging)
            PlanMaterializer.materializeGrok(
                sessionsRoot: GrokPaths.sessionsRoot(), into: staging)
            PlanMaterializer.materializeKimi(
                sessionsRoot: KimiPaths.sessionsRoot(), into: staging)
            PlanMaterializer.materializeGemini(
                tmpRoot: GeminiPaths.tmpRoot(),
                projectsFile: GeminiPaths.projectsFile(), into: staging)
            PlanMaterializer.materializeQwen(
                projectsRoot: QwenPaths.projectsRoot(), into: staging)
            PlanMaterializer.materializeQoder(
                plansRoot: QoderPaths.plansRoot(), into: staging)
            // cursor has no plans directory; plans are the session's todos -> synthesized (same as
            // codex's update_plan)
            PlanMaterializer.materializeCursor(into: staging)
            self.publishPhase(L10n.text("Indexing plans…", zhHans: "正在索引计划…"))
            // Hermes plans: profile-level ~/.hermes/plans + each repo's <repo>/.hermes/plans (the
            // `plan` skill writes the in-project one by default); both are real .md, no
            // materialization needed
            let repoRoots = ProjectScopeDiscovery.repoRoots(resolver: self.resolver)
            var hermesPlansDirs = HermesPaths.allHomes().map {
                $0.appendingPathComponent("plans", isDirectory: true)
            }
            hermesPlansDirs += repoRoots.map { HermesPaths.projectPlansDir(repoRoot: $0.root) }
            // Trae plans: <repo>/.trae/documents/plan_*.md, also real .md, no materialization
            // needed
            let traePlansDirs = repoRoots.map { TraePaths.projectDocumentsRoot(repoRoot: $0.root) }
            // ZCode plans: <repo>/.zcode/plans/plan-sess_*.md, real .md, with the session id
            // embedded in the file name
            let zcodePlansDirs = repoRoots.map { ZcodePaths.projectPlansDir(repoRoot: $0.root) }
            var entries = PlanMaterializer.index(
                claudePlansDir: PlanMaterializer.defaultClaudePlansDir(), stagingRoot: staging,
                hermesPlansDirs: hermesPlansDirs, traePlansDirs: traePlansDirs,
                zcodePlansDirs: zcodePlansDirs)
            entries += PlanMaterializer.indexProjectPlans(roots: repoRoots)
            DispatchQueue.main.async {
                self.all = entries
                self.totalCount = entries.count
                self.totalBytes = entries.reduce(0) { $0 + $1.sizeBytes }
                self.scanning = false
                self.scanPhase = nil
                self.lastScanAt = Date()
                self.rebuild()
            }
        }
    }

    /// Hops from the scan queue back to the main thread to update the phase text (phases are only a
    /// coarse hint for humans)
    private func publishPhase(_ phase: String) {
        DispatchQueue.main.async { self.scanPhase = phase }
    }

    private func rebuild() {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { plans = all; return }
        plans = all.filter {
            "\($0.title) \($0.path) \($0.project ?? "") \($0.summary ?? "")"
                .lowercased().contains(query)
        }
    }

    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Sources present in the full set (source chips render from this; project docs are filed under
    /// their placeholder source=.claude) Sorted by plan count descending, matching the design mock
    /// (the source with the most comes first).
    var availableSources: [AgentSource] {
        var seen = Set<AgentSource>()
        let distinct = all.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
        return distinct.sorted { count(for: $0) > count(for: $1) }
    }

    /// Plan count for a source (over the full set, including project docs under the .claude
    /// placeholder)
    func count(for source: AgentSource) -> Int {
        all.lazy.filter { $0.source == source }.count
    }

    /// Number of distinct projects (the stat card subtitle "N projects")
    var distinctProjectCount: Int {
        Set(all.compactMap { $0.project }).count
    }

    /// Status distribution (the stat card's segmented bar): done / in progress / draft / doc
    var statusCounts: (complete: Int, inProgress: Int, draft: Int, document: Int) {
        var complete = 0, inProgress = 0, draft = 0, document = 0
        for plan in all {
            switch plan.status {
            case .complete: complete += 1
            case .inProgress: inProgress += 1
            case .draft: draft += 1
            case .document: document += 1
            }
        }
        return (complete, inProgress, draft, document)
    }

    // MARK: - Cross-page linkage (main thread)

    /// Knowledge-surface snapshot (for the full-text index; the full set before search filtering)
    func knowledgeSnapshot() -> [PlanMaterializer.PlanEntry] { all }

    /// Plans produced by a session (for the session detail's "produced in this session")
    func plans(forSession sessionId: String) -> [PlanMaterializer.PlanEntry] {
        all.filter { $0.sessionId == sessionId }
    }

    /// Finds an entry by path (for cross-page jump consumption)
    func entry(atPath path: String) -> PlanMaterializer.PlanEntry? {
        all.first { $0.path == path }
    }

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Atomic write: leaves a .bak.eureka.<ts> backup first (only Claude plans are real, editable
    /// files; other sources are materialized copies, and edits would be overwritten by the next
    /// scan; the caller must only allow it for claude)
    func save(path: String, content: String, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            var ok = false
            let fm = FileManager.default
            do {
                if fm.fileExists(atPath: path) {
                    let backup = path + ".bak.eureka.\(Int(Date().timeIntervalSince1970))"
                    try? fm.removeItem(atPath: backup)
                    try? fm.copyItem(atPath: path, toPath: backup)
                }
                try content.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
                ok = true
            } catch {
                ok = false
            }
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    /// Deletes a plan -> Trash (Claude plans and project docs are real files; a deleted
    /// materialized copy would come back next scan, so not offered)
    func delete(_ entry: PlanMaterializer.PlanEntry, completion: ((Bool) -> Void)? = nil) {
        guard entry.source == .claude || entry.kind == .projectDocument else {
            completion?(false)
            return
        }
        queue.async { [weak self] in
            let ok = (try? FileManager.default.trashItem(
                at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)) != nil
            DispatchQueue.main.async { completion?(ok); self?.refresh(force: true) }
        }
    }

    func reveal(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInEditor(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
