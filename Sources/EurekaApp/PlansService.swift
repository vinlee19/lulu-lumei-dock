import AppKit
import EurekaIngest
import EurekaKit
import EurekaUsage
import Foundation

/// 「计划」浏览服务：物化 Codex/opencode 计划到暂存，索引各源计划 .md（Claude 直接文件），
/// 外加各项目仓库内的 plan 文档（docs/**/plans、plans/）。
/// 与 S3 同步共用同一批物化产物（`PlanMaterializer`）。只读浏览，不改写来源。
final class PlansService: ObservableObject {
    @Published private(set) var plans: [PlanMaterializer.PlanEntry] = []
    @Published private(set) var scanning = false
    /// 扫描中的阶段文案：Plans 最慢（首次要全量解析会话），必须交代当前在做什么；扫完置 nil
    @Published private(set) var scanPhase: String?
    /// 上次扫完的时间。nil = 从未扫过（refresh 的判据）
    @Published private(set) var lastScanAt: Date?
    /// 全集口径的总量（不受筛选/搜索影响）
    @Published private(set) var totalCount = 0
    @Published private(set) var totalBytes: UInt64 = 0

    /// 跨页直达：待聚焦计划的文件路径（PopoverRootView 写入，PlansView 消费后清空）
    @Published var focusPath: String?
    @Published var searchText = "" {
        didSet { rebuild() }
    }

    private let queue = DispatchQueue(label: "com.vinlee.eureka.plans", qos: .userInitiated)
    private let resolver = ProjectResolver()
    private var all: [PlanMaterializer.PlanEntry] = []

    /// 刷新（物化 + 索引）。force = false 只在「从未扫过」时扫（启动预热 + onAppear 兜底共用，
    /// 幂等）；force = true 无条件全量重扫，仅刷新按钮使用。
    func refresh(force: Bool = false) {
        guard force || lastScanAt == nil else { return }
        guard !scanning else { return }
        if force { ProjectScopeDiscovery.invalidateCache() }
        scanning = true
        scanPhase = "正在解析 Codex 会话…"
        queue.async { [weak self] in
            guard let self else { return }
            let staging = PlanMaterializer.defaultStagingRoot()
            PlanMaterializer.materializeCodex(
                sessionsRoot: CodexRolloutTailer.defaultSessionsRoot(), into: staging)
            self.publishPhase("正在解析其它 CLI 会话…")
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
            // cursor 无 plans 目录，计划是会话里的 todos → 合成（同 codex 的 update_plan）
            PlanMaterializer.materializeCursor(into: staging)
            self.publishPhase("正在索引计划…")
            // Hermes 计划：profile 级 ~/.hermes/plans + 各仓库内 <repo>/.hermes/plans
            // （`plan` 技能默认写项目内那一份），都是真 .md，无需物化
            let repoRoots = ProjectScopeDiscovery.repoRoots(resolver: self.resolver)
            var hermesPlansDirs = HermesPaths.allHomes().map {
                $0.appendingPathComponent("plans", isDirectory: true)
            }
            hermesPlansDirs += repoRoots.map { HermesPaths.projectPlansDir(repoRoot: $0.root) }
            // Trae 计划：<repo>/.trae/documents/plan_*.md，同样是真 .md，无需物化
            let traePlansDirs = repoRoots.map { TraePaths.projectDocumentsRoot(repoRoot: $0.root) }
            // ZCode 计划：<repo>/.zcode/plans/plan-sess_*.md，真 .md，会话 id 内嵌在文件名
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

    /// 扫描队列上回主线程更新阶段文案（阶段只是给人看的粗粒度提示）
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

    /// 全集里出现过的来源（来源 chips 按此渲染；项目文档记在其占位 source=.claude 上）
    /// 按计划数降序，贴合设计稿（数量最多的来源排在前）。
    var availableSources: [AgentSource] {
        var seen = Set<AgentSource>()
        let distinct = all.compactMap { seen.insert($0.source).inserted ? $0.source : nil }
        return distinct.sorted { count(for: $0) > count(for: $1) }
    }

    /// 某来源的计划数（全集口径，含以 .claude 占位的项目文档）
    func count(for source: AgentSource) -> Int {
        all.lazy.filter { $0.source == source }.count
    }

    /// 不同项目数（统计卡副标题「N 项目」）
    var distinctProjectCount: Int {
        Set(all.compactMap { $0.project }).count
    }

    /// 状态分布（统计卡分段条）：完成 / 进行中 / 草稿 / 文档
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

    // MARK: - 跨页联动（主线程）

    /// 知识面快照（全文索引用；搜索过滤前的全集）
    func knowledgeSnapshot() -> [PlanMaterializer.PlanEntry] { all }

    /// 某会话产出的计划（会话详情「本会话产出」用）
    func plans(forSession sessionId: String) -> [PlanMaterializer.PlanEntry] {
        all.filter { $0.sessionId == sessionId }
    }

    /// 按路径找条目（跨页直达消费用）
    func entry(atPath path: String) -> PlanMaterializer.PlanEntry? {
        all.first { $0.path == path }
    }

    func readContent(path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// 原子写入：写前留 .bak.eureka.<ts> 备份（仅 Claude 计划是真实文件可编辑；
    /// 其它源为物化副本，改了也会被下一轮扫描覆盖——调用方负责只对 claude 开放）
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

    /// 删除计划 → 废纸篓（Claude 计划与项目文档是真实文件；物化副本删了会被下一轮复原，不提供）
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
